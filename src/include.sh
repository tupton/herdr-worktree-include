#!/usr/bin/env bash
#
# Herdr worktree.created handler. Symlinks or copies selected paths from a
# repository's main checkout into a newly created worktree.
#
# Every failure in the script is non-fatal by design so worktree creation
# can continue unblocked.

set -uo pipefail

PLUGIN_NAME="worktree-include"
CONFIG_NAME=".herdr-worktree-include"
DEFAULT_INCLUDE_FILE=".worktreeinclude"
TEMP_DIR=

warn() {
  printf '%s: %s\n' "$PLUGIN_NAME" "$1" >&2
}

# Bash 5 or newer is required for mapfile, associative arrays, and safe empty
# array expansion under `set -u`.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ]; then
  warn "Bash 5 or newer is required, found ${BASH_VERSION:-unknown}, skipping"
  exit 0
fi

trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

normalize_path() {
  local input=$1
  [[ -z $input || $input == /* ]] && return 1

  local IFS=/
  local -a parts=() kept=()
  local component

  read -r -a parts <<<"$input"
  for component in "${parts[@]}"; do
    case $component in
      '' | .) ;;
      ..) return 1 ;;
      *) kept+=("$component") ;;
    esac
  done

  local normalized="${kept[*]}"
  case $normalized in
    '' | .git | .git/*) return 1 ;;
  esac

  printf '%s' "$normalized"
}

meaningful_lines() {
  local file=$1
  local raw line number=0

  while IFS= read -r raw || [[ -n $raw ]]; do
    number=$((number + 1))
    line=$(trim "$raw")
    case $line in
      '' | \#*) continue ;;
    esac
    printf '%s:%s\0' "$number" "$line"
  done <"$file"
}

has_tracked_conflict() {
  local repository=$1 tracked_file=$2 entry=$3
  local tracked prefix=$entry ignore_case=false pathspec_prefix=':(top,literal)'

  ignore_case=$(git -C "$repository" config --bool core.ignoreCase 2>/dev/null) || ignore_case=false
  [[ $ignore_case == true ]] && pathspec_prefix=':(top,icase,literal)'

  if git -C "$repository" ls-files --error-unmatch -- \
    "$pathspec_prefix$entry" >/dev/null 2>&1; then
    return 0
  fi

  while [[ $prefix == */* ]]; do
    prefix=${prefix%/*}
    if git -C "$repository" ls-files --error-unmatch -- \
      "$pathspec_prefix$prefix" >/dev/null 2>&1; then
      return 0
    fi
  done

  while IFS= read -r -d '' tracked; do
    if [[ $ignore_case == true ]]; then
      [[ ${tracked,,} == "${entry,,}/"* ]] && return 0
    else
      [[ $tracked == "$entry/"* ]] && return 0
    fi
  done <"$tracked_file"

  return 1
}

has_unsafe_destination_parent() {
  local worktree=$1 relative_path=$2
  local parent=${relative_path%/*}
  [[ $parent == "$relative_path" ]] && return 1

  local IFS=/
  local -a parts=()
  local component current=$worktree

  read -r -a parts <<<"$parent"
  for component in "${parts[@]}"; do
    current=$current/$component
    if [[ -L $current ]] || { [[ -e $current ]] && [[ ! -d $current ]]; }; then
      return 0
    fi
  done

  return 1
}

resolve_worktree() {
  local path=$1 common top

  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n $common && -n $top ]] || return 1

  # The main checkout is the directory holding the common Git dir.
  printf '%s\0%s\0' "${common%/*}" "$top"
}

read_config() {
  local config=$1
  local mode=symlink mode_seen=0 invalid=0
  local -a include_files=()
  local record number line key value normalized

  if [[ ! -f $config || ! -r $config ]]; then
    warn "$CONFIG_NAME is not a readable file, skipping"
    return 1
  fi

  while IFS= read -r -d '' record; do
    number=${record%%:*}
    line=${record#*:}

    if [[ $line != *=* ]]; then
      warn "$CONFIG_NAME:$number: expected key=value"
      invalid=1
      continue
    fi

    key=$(trim "${line%%=*}")
    value=$(trim "${line#*=}")

    case $key in
      mode)
        if ((mode_seen)); then
          warn "$CONFIG_NAME:$number: mode may only be set once"
          invalid=1
          continue
        fi
        case $value in
          symlink | copy)
            mode=$value
            mode_seen=1
            ;;
          *)
            warn "$CONFIG_NAME:$number: mode must be symlink or copy"
            invalid=1
            ;;
        esac
        ;;
      include_file)
        if ! normalized=$(normalize_path "$value"); then
          warn "$CONFIG_NAME:$number: invalid include file path: $value"
          invalid=1
          continue
        fi
        include_files+=("$normalized")
        ;;
      *)
        warn "$CONFIG_NAME:$number: unsupported key: $key"
        invalid=1
        ;;
    esac
  done < <(meaningful_lines "$config")

  if ((invalid)); then
    warn "invalid configuration, skipping"
    return 1
  fi

  printf '%s\0' "$mode" "${include_files[@]}"
}

collect_include_files() {
  local source=$1 snapshot_directory=$2
  shift 2

  local include_file include_path snapshot snapshot_cp count=0
  snapshot_cp=$(command -p -v cp) || return 1

  for include_file in "$@"; do
    include_path=$source/$include_file

    if [[ ! -e $include_path && ! -L $include_path ]]; then
      continue
    fi
    if [[ ! -f $include_path || ! -r $include_path ]]; then
      warn "include path is not a readable file: $include_path"
      return 1
    fi
    snapshot=$snapshot_directory/$count
    if ! "$snapshot_cp" "$include_path" "$snapshot"; then
      warn "could not read include file: $include_path"
      return 1
    fi
    printf '%s\0' "$snapshot"
    count=$((count + 1))
  done
}

escape_gitignore_path() {
  local path=$1
  path=${path//\\/\\\\}
  path=${path//\*/\\*}
  path=${path//\?/\\?}
  path=${path//\[/\\[}
  path=${path//\]/\\]}
  path=${path// /\\ }
  printf '%s' "$path"
}

is_direct_directory_match() {
  local source=$1 index_file=$2 output_file=$3 directory=$4
  shift 4

  local escaped parent=$directory
  local -a traversal_args=()

  while [[ $parent == */* ]]; do
    parent=${parent%/*}
    escaped=$(escape_gitignore_path "$parent")
    traversal_args=(--exclude="!/$escaped/" "${traversal_args[@]}")
  done
  escaped=$(escape_gitignore_path "$directory")

  if ! GIT_INDEX_FILE=$index_file git -C "$source" ls-files --others --ignored --directory -z \
    "$@" "${traversal_args[@]}" --exclude="!/$escaped/**" -- \
    ":(top,literal)$directory" >"$output_file"; then
    return 2
  fi

  local path
  while IFS= read -r -d '' path; do
    [[ $path == "$directory/" ]] && return 0
  done <"$output_file"

  return 1
}

is_repository_root() {
  local directory=$1 inside prefix bare

  inside=$(git -C "$directory" rev-parse --is-inside-work-tree 2>/dev/null) || inside=false
  if [[ $inside == true ]]; then
    prefix=$(git -C "$directory" rev-parse --show-prefix 2>/dev/null) || return 1
    [[ -z $prefix ]] && return 0
  fi

  bare=$(git -C "$directory" rev-parse --is-bare-repository 2>/dev/null) || return 1
  [[ $bare == true ]]
}

inspect_directory_tree() {
  local root=$1
  local -a pending=("$root") children=()
  local directory child

  while ((${#pending[@]})); do
    directory=${pending[0]}
    pending=("${pending[@]:1}")

    if is_repository_root "$directory"; then
      return 0
    fi
    if [[ ! -r $directory || ! -x $directory ]]; then
      return 2
    fi

    children=("$directory"/* "$directory"/.[!.]* "$directory"/..?*)
    for child in "${children[@]}"; do
      [[ -e $child || -L $child ]] || continue
      if [[ -d $child && ! -L $child ]]; then
        pending+=("$child")
      elif [[ ! -f $child && ! -L $child ]]; then
        return 3
      fi
    done
  done

  return 1
}

is_below_entry() {
  local path=$1
  shift

  local entry
  for entry in "$@"; do
    case $path in
      "$entry" | "$entry"/*) return 0 ;;
    esac
  done

  return 1
}

select_entries() {
  local source=$1 worktree=$2 source_tracked_file=$3 worktree_tracked_file=$4 output_file=$5
  shift 5

  local -a include_args=()
  local include_file
  for include_file in "$@"; do
    include_args+=(--exclude-from="$include_file")
  done
  ((${#include_args[@]})) || return 0

  local leaves_file=$TEMP_DIR/include-leaves
  local collapsed_file=$TEMP_DIR/include-collapsed
  local selection_index=$TEMP_DIR/selection-index
  local special_paths_file=$TEMP_DIR/special-paths
  local special_index_input=$TEMP_DIR/special-index-input
  local special_index=$TEMP_DIR/special-index
  local probe_file=$TEMP_DIR/include-probe
  local ignore_input_file=$TEMP_DIR/ignore-input
  local ignored_file=$TEMP_DIR/ignored

  if ! GIT_INDEX_FILE=$selection_index git -C "$source" read-tree --empty || \
    ! GIT_INDEX_FILE=$selection_index git -C "$source" ls-files --others --ignored -z \
    "${include_args[@]}" -- >"$leaves_file"; then
    warn "could not evaluate include patterns, skipping"
    return 1
  fi
  if ! GIT_INDEX_FILE=$selection_index git -C "$source" ls-files --others --ignored --directory -z \
    "${include_args[@]}" -- >"$collapsed_file"; then
    warn "could not evaluate include directories, skipping"
    return 1
  fi

  find "$source" -name .git -prune -o \
    ! -type f ! -type d ! -type l -print0 >"$special_paths_file" 2>/dev/null || true

  local empty_blob
  empty_blob=$(git -C "$source" hash-object -t blob --stdin </dev/null) || {
    warn "could not prepare source type matching, skipping"
    return 1
  }
  : >"$special_index_input"
  while IFS= read -r -d '' path; do
    path=${path#"$source"/}
    printf '100644 %s\t%s\0' "$empty_blob" "$path" >>"$special_index_input"
  done <"$special_paths_file"
  if [[ -s $special_index_input ]]; then
    if ! GIT_INDEX_FILE=$special_index git -C "$source" read-tree --empty || \
      ! GIT_INDEX_FILE=$special_index git -C "$source" update-index -z --index-info \
        <"$special_index_input" || \
      ! GIT_INDEX_FILE=$special_index git -C "$source" ls-files --cached --ignored -z \
        "${include_args[@]}" >>"$leaves_file"; then
      warn "could not evaluate include patterns for special files, skipping"
      return 1
    fi
  fi

  local -A leaves=() directory_candidates=() direct_directories=() ignore_candidates=() ignored=()
  local path directory ancestor status
  local -a ancestors=()

  while IFS= read -r -d '' path; do
    path=${path%/}
    [[ -n $path ]] && leaves[$path]=1
  done <"$leaves_file"

  local directory_candidates_file=$TEMP_DIR/directory-candidates
  : >"$directory_candidates_file"
  while IFS= read -r -d '' path; do
    [[ $path == */ ]] || continue
    directory=${path%/}
    if [[ -z ${directory_candidates[$directory]+set} ]]; then
      directory_candidates[$directory]=1
      printf '%s\0' "$directory" >>"$directory_candidates_file"
    fi
  done <"$collapsed_file"

  for path in "${!leaves[@]}"; do
    directory=${path%/*}
    [[ $directory != "$path" ]] || continue
    ancestors=()
    while [[ -n $directory ]]; do
      ancestors=("$directory" "${ancestors[@]}")
      [[ $directory == */* ]] || break
      directory=${directory%/*}
    done
    for ancestor in "${ancestors[@]}"; do
      [[ -d $source/$ancestor && ! -L $source/$ancestor ]] || continue
      if [[ -z ${directory_candidates[$ancestor]+set} ]]; then
        directory_candidates[$ancestor]=1
        printf '%s\0' "$ancestor" >>"$directory_candidates_file"
      fi
    done
  done

  while IFS= read -r -d '' directory; do
    if is_direct_directory_match "$source" "$selection_index" "$probe_file" "$directory" \
      "${include_args[@]}"; then
      direct_directories[$directory]=1
    else
      status=$?
      if ((status == 2)); then
        warn "could not evaluate include directory: $directory"
        return 1
      fi
    fi
  done <"$directory_candidates_file"

  for path in "${!leaves[@]}" "${!direct_directories[@]}"; do
    [[ -n $path ]] && ignore_candidates[$path]=1
  done

  : >"$ignore_input_file"
  for path in "${!ignore_candidates[@]}"; do
    printf './%s\0' "$path" >>"$ignore_input_file"
  done

  if git -C "$source" check-ignore --stdin -z <"$ignore_input_file" >"$ignored_file"; then
    :
  else
    status=$?
    if ((status != 1)); then
      warn "could not inspect standard Git ignores, skipping"
      return 1
    fi
  fi

  : >"$ignore_input_file"
  for path in "${!direct_directories[@]}"; do
    printf './%s\0' "$path" >>"$ignore_input_file"
  done
  if git -C "$source" check-ignore --no-index --stdin -z \
    <"$ignore_input_file" >>"$ignored_file"; then
    :
  else
    status=$?
    if ((status != 1)); then
      warn "could not inspect standard Git ignores, skipping"
      return 1
    fi
  fi

  while IFS= read -r -d '' path; do
    path=${path#./}
    path=${path%/}
    [[ -n $path ]] && ignored[$path]=1
  done <"$ignored_file"

  local -a accepted_directories=() rejected_directories=()
  local inspection_status
  : >"$output_file"

  while IFS= read -r -d '' directory; do
    [[ -n ${direct_directories[$directory]+set} ]] || continue
    if is_below_entry "$directory" "${accepted_directories[@]}" || \
      is_below_entry "$directory" "${rejected_directories[@]}"; then
      continue
    fi

    if has_tracked_conflict "$source" "$source_tracked_file" "$directory" || \
      has_tracked_conflict "$worktree" "$worktree_tracked_file" "$directory"; then
      warn "tracked path conflict: $directory"
      rejected_directories+=("$directory")
      continue
    fi

    if inspect_directory_tree "$source/$directory"; then
      warn "selected directory contains a nested Git repository: $directory"
      rejected_directories+=("$directory")
      continue
    else
      inspection_status=$?
      if ((inspection_status == 2)); then
        warn "could not inspect selected directory: $directory"
        rejected_directories+=("$directory")
        continue
      elif ((inspection_status == 3)); then
        warn "selected directory contains an unsupported source type: $directory"
        rejected_directories+=("$directory")
        continue
      fi
    fi

    [[ -n ${ignored[$directory]+set} ]] || continue
    accepted_directories+=("$directory")
    printf '%s\0' "$directory" >>"$output_file"
  done <"$directory_candidates_file"

  while IFS= read -r -d '' path; do
    path=${path%/}
    [[ -n $path ]] || continue
    [[ -n ${ignored[$path]+set} ]] || continue
    if is_below_entry "$path" "${accepted_directories[@]}" || \
      is_below_entry "$path" "${rejected_directories[@]}"; then
      continue
    fi

    if has_tracked_conflict "$source" "$source_tracked_file" "$path" || \
      has_tracked_conflict "$worktree" "$worktree_tracked_file" "$path"; then
      warn "tracked path conflict: $path"
      continue
    fi

    if [[ -d $source/$path && ! -L $source/$path ]] && is_repository_root "$source/$path"; then
      warn "selected path is a nested Git repository: $path"
      continue
    fi

    if [[ -d $source/$path && ! -L $source/$path ]]; then
      if inspect_directory_tree "$source/$path"; then
        warn "selected directory contains a nested Git repository: $path"
        continue
      else
        inspection_status=$?
        if ((inspection_status == 2)); then
          warn "could not inspect selected directory: $path"
          continue
        elif ((inspection_status == 3)); then
          warn "selected directory contains an unsupported source type: $path"
          continue
        fi
      fi
    fi

    printf '%s\0' "$path" >>"$output_file"
  done <"$leaves_file"
}

install_entry() {
  local mode=$1 source=$2 worktree=$3 tracked_file=$4 entry=$5
  local source_path=$source/$entry
  local destination=$worktree/$entry

  if has_tracked_conflict "$worktree" "$tracked_file" "$entry"; then
    warn "tracked path conflict: $entry"
    return 1
  fi
  if [[ ! -e $source_path && ! -L $source_path ]]; then
    warn "source does not exist: $source_path"
    return 1
  fi
  if [[ ! -f $source_path && ! -d $source_path && ! -L $source_path ]]; then
    warn "unsupported source type: $source_path"
    return 1
  fi
  if [[ -e $destination || -L $destination ]]; then
    warn "destination exists: $destination"
    return 1
  fi
  if has_unsafe_destination_parent "$worktree" "$entry"; then
    warn "destination has a symlink or non-directory parent: $destination"
    return 1
  fi
  if ! mkdir -p "${destination%/*}"; then
    warn "could not create destination parent: ${destination%/*}"
    return 1
  fi

  case $mode in
    symlink)
      if ! ln -s "$source_path" "$destination"; then
        warn "could not create symlink: $destination"
        return 1
      fi
      printf 'linked: %s -> %s\n' "$destination" "$source_path"
      ;;
    copy)
      if ! cp -RP "$source_path" "$destination"; then
        warn "copy failed: partial destination may remain: $destination"
        return 1
      fi
      printf 'copied: %s -> %s\n' "$source_path" "$destination"
      ;;
  esac

  return 0
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found, skipping"
    return 0
  fi

  local event_path
  event_path=$(jq -r '.data.worktree.path // .worktree.path // empty' <<<"${HERDR_PLUGIN_EVENT_JSON:-}" 2>/dev/null)
  if [[ -z $event_path || ! -d $event_path ]]; then
    warn "no valid worktree path in event, skipping"
    return 0
  fi

  local -a resolved=()
  mapfile -d '' -t resolved < <(resolve_worktree "$event_path")
  if ((${#resolved[@]} != 2)); then
    warn "not a Git worktree: $event_path"
    return 0
  fi

  local source=${resolved[0]} worktree=${resolved[1]}
  # Not a linked worktree, so there is nothing to copy from.
  [[ $source == "$worktree" ]] && return 0

  local mode=symlink
  local -a include_files=()
  local config=$source/$CONFIG_NAME

  if [[ -e $config || -L $config ]]; then
    local -a config_fields=()
    mapfile -d '' -t config_fields < <(read_config "$config")
    # read_config always emits at least the mode, so an empty read is a failure.
    ((${#config_fields[@]})) || return 0
    mode=${config_fields[0]}
    include_files=("${config_fields[@]:1}")
  fi

  ((${#include_files[@]})) || include_files=("$DEFAULT_INCLUDE_FILE")

  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-worktree-include.XXXXXX" 2>/dev/null)
  if [[ -z $TEMP_DIR ]]; then
    warn "could not create a temporary directory, skipping"
    return 0
  fi
  trap 'rm -rf "$TEMP_DIR"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local include_paths_file=$TEMP_DIR/include-paths
  local include_snapshot_directory=$TEMP_DIR/include-files
  if ! mkdir "$include_snapshot_directory" || \
    ! collect_include_files "$source" "$include_snapshot_directory" \
      "${include_files[@]}" >"$include_paths_file"; then
    return 0
  fi

  local -a include_paths=()
  mapfile -d '' -t include_paths <"$include_paths_file"
  ((${#include_paths[@]})) || return 0

  local source_tracked_file=$TEMP_DIR/source-tracked
  local worktree_tracked_file=$TEMP_DIR/worktree-tracked
  local entries_file=$TEMP_DIR/entries

  if ! git -C "$source" ls-files -z >"$source_tracked_file" 2>/dev/null || \
    ! git -C "$worktree" ls-files -z >"$worktree_tracked_file" 2>/dev/null; then
    warn "could not inspect tracked paths, skipping"
    return 0
  fi

  if ! select_entries "$source" "$worktree" "$source_tracked_file" "$worktree_tracked_file" \
    "$entries_file" "${include_paths[@]}"; then
    return 0
  fi

  local -a entries=()
  mapfile -d '' -t entries <"$entries_file"
  ((${#entries[@]})) || return 0

  local entry created=0 skipped=0
  for entry in "${entries[@]}"; do
    if install_entry "$mode" "$source" "$worktree" "$worktree_tracked_file" "$entry"; then
      created=$((created + 1))
    else
      skipped=$((skipped + 1))
    fi
  done

  printf '%s: %s %d, skipped %d\n' "$PLUGIN_NAME" "$mode" "$created" "$skipped"
  return 0
}

main "$@"
exit 0
