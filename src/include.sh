#!/usr/bin/env bash
#
# Herdr worktree.created handler. Symlinks or copies declared leaf entries from
# a repository's main checkout into a newly created worktree.

set -uo pipefail

PLUGIN_NAME="worktree-include"
CONFIG_NAME=".herdr-worktree-include"
INCLUDE_FILE=".worktreeinclude"
TEMP_DIR=

warn() {
  printf '%s: %s\n' "$PLUGIN_NAME" "$1" >&2
}

if [[ ${BASH_VERSINFO[0]:-0} -lt 5 ]]; then
  warn "Bash 5 or newer is required, found ${BASH_VERSION:-unknown}, skipping"
  exit 0
fi

# ShellCheck cannot see that the EXIT trap invokes this function.
# shellcheck disable=SC2317,SC2329
cleanup() {
  [[ -z ${TEMP_DIR:-} ]] || rm -rf "$TEMP_DIR"
}

trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

resolve_worktree() {
  local path=$1 common top

  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n $common && -n $top ]] || return 1
  printf '%s\0%s\0' "${common%/*}" "$top"
}

read_config() {
  local config=$1 mode=symlink mode_seen=0 invalid=0
  local line number=0 key value

  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=$(trim "$line")
    [[ -n $line && $line != \#* ]] || continue

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
        elif [[ $value == symlink || $value == copy ]]; then
          mode=$value
          mode_seen=1
        else
          warn "$CONFIG_NAME:$number: mode must be symlink or copy"
          invalid=1
        fi
        ;;
      *)
        warn "$CONFIG_NAME:$number: unsupported key: $key"
        invalid=1
        ;;
    esac
  done <"$config"

  if ((invalid)); then
    warn "invalid configuration, skipping"
    return 1
  fi
  printf '%s' "$mode"
}

normalize_declaration() {
  local path=$1 component

  [[ -n $path && $path != *[[:space:]]* ]] || return 1
  [[ $path != '!'* && $path != */ && $path != *['*?[]']* && $path != *\\* ]] || return 1
  [[ $path != //* ]] || return 1
  path=${path#/}
  [[ -n $path && $path != /* ]] || return 1

  local IFS=/
  local -a components=()
  read -r -a components <<<"$path"
  for component in "${components[@]}"; do
    [[ -n $component && $component != . && $component != .. && $component != .git ]] || return 1
  done

  printf '%s' "$path"
}

# Returns 0 for an unsafe parent, 1 for a safe chain, and 2 when a parent is
# missing. The final path component is deliberately not inspected here.
inspect_parent_chain() {
  local root=$1 path=$2 parent
  parent=${path%/*}
  [[ $parent != "$path" ]] || return 1

  local IFS=/ component current=$root
  local -a components=()
  read -r -a components <<<"$parent"
  for component in "${components[@]}"; do
    current=$current/$component
    if [[ -L $current || ( -e $current && ! -d $current ) ]]; then
      return 0
    fi
    [[ -d $current ]] || return 2
  done
  return 1
}

read_declarations() {
  local source=$1 include_file=$2 output_file=$3
  local line number=0 path status key ignore_case=$4
  local -A seen=()

  : >"$output_file"
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    [[ -n $line && $line != \#* ]] || continue

    if ! path=$(normalize_declaration "$line"); then
      warn "$INCLUDE_FILE:$number: unsupported pattern, ignoring"
      continue
    fi
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    [[ -z ${seen[$key]+set} ]] || continue
    seen[$key]=1

    inspect_parent_chain "$source" "$path"
    status=$?
    if ((status == 0)); then
      warn "source has a symlink or non-directory parent: $path"
      continue
    elif ((status == 1)) && [[ -e $source/$path && ! -L $source/$path && ! -f $source/$path ]]; then
      warn "not a regular file or symlink: $path"
      continue
    fi
    # Missing paths remain candidates so Git can resolve case differences when
    # core.ignoreCase is enabled. Git quietly omits genuinely missing paths.
    printf '%s\0' "$path" >>"$output_file"
  done <"$include_file"
}

select_ignored_untracked() {
  local source=$1 declarations_file=$2 output_file=$3 ignore_case=$4
  local path key
  local -a declarations=() pathspecs=()
  local -A matched=() ambiguous=()

  mapfile -d '' -t declarations <"$declarations_file"
  ((${#declarations[@]})) || {
    : >"$output_file"
    return 0
  }

  for path in "${declarations[@]}"; do
    if [[ $ignore_case == true ]]; then
      pathspecs+=(":(top,icase,literal)$path")
    else
      pathspecs+=(":(top,literal)$path")
    fi
  done

  local matches_file=$TEMP_DIR/ignored-untracked
  if ! GIT_LITERAL_PATHSPECS=0 GIT_GLOB_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 \
    GIT_ICASE_PATHSPECS=0 git -C "$source" ls-files --others --ignored \
      --exclude-standard -z -- "${pathspecs[@]}" >"$matches_file"; then
    warn "could not inspect ignored files, skipping"
    return 1
  fi

  while IFS= read -r -d '' path; do
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    if [[ -n ${matched[$key]+set} && ${matched[$key]} != "$path" ]]; then
      ambiguous[$key]=1
    else
      matched[$key]=$path
    fi
  done <"$matches_file"

  : >"$output_file"
  for path in "${declarations[@]}"; do
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    [[ -n ${matched[$key]+set} ]] || continue
    if [[ -n ${ambiguous[$key]+set} ]]; then
      warn "ambiguous case-insensitive path: $path"
      continue
    fi
    printf '%s\0' "${matched[$key]}" >>"$output_file"
  done
}

validate_source_leaves() {
  local source=$1 candidates_file=$2 output_file=$3 path status

  : >"$output_file"
  while IFS= read -r -d '' path; do
    inspect_parent_chain "$source" "$path"
    status=$?
    if ((status == 0)); then
      warn "source has a symlink or non-directory parent: $path"
    elif ((status == 2)); then
      continue
    elif [[ -L $source/$path || -f $source/$path ]]; then
      printf '%s\0' "$path" >>"$output_file"
    elif [[ -e $source/$path ]]; then
      warn "not a regular file or symlink: $path"
    fi
  done <"$candidates_file"
}

snapshot_index() {
  local repository=$1 snapshot_name=$2
  local tracked_name descendants_name ignore_case_name
  tracked_name=${snapshot_name}_tracked
  descendants_name=${snapshot_name}_descendants
  ignore_case_name=${snapshot_name}_ignore_case
  local -n tracked_ref=$tracked_name descendants_ref=$descendants_name ignore_case_ref=$ignore_case_name
  local path key prefix snapshot_file=$TEMP_DIR/$snapshot_name

  tracked_ref=()
  descendants_ref=()
  ignore_case_ref=$(git -C "$repository" config --bool core.ignoreCase 2>/dev/null) || ignore_case_ref=false
  if ! git -C "$repository" ls-files --cached -z >"$snapshot_file"; then
    warn "could not inspect tracked paths, skipping"
    return 1
  fi

  while IFS= read -r -d '' path; do
    key=$path
    [[ $ignore_case_ref == true ]] && key=${key,,}
    # shellcheck disable=SC2004 # tracked_ref is an associative-array nameref.
    tracked_ref[$key]=1
    prefix=$key
    while [[ $prefix == */* ]]; do
      prefix=${prefix%/*}
      # shellcheck disable=SC2004 # descendants_ref is an associative-array nameref.
      descendants_ref[$prefix]=1
    done
  done <"$snapshot_file"
}

has_snapshot_conflict() {
  local entry=$1 snapshot_name=$2 key prefix
  key=$entry
  local tracked_name descendants_name ignore_case_name
  tracked_name=${snapshot_name}_tracked
  descendants_name=${snapshot_name}_descendants
  ignore_case_name=${snapshot_name}_ignore_case
  # shellcheck disable=SC2178 # The references point to associative arrays.
  local -n tracked_ref=$tracked_name descendants_ref=$descendants_name ignore_case_ref=$ignore_case_name

  [[ $ignore_case_ref == true ]] && key=${key,,}
  [[ -n ${tracked_ref[$key]+set} || -n ${descendants_ref[$key]+set} ]] && return 0

  prefix=$key
  while [[ $prefix == */* ]]; do
    prefix=${prefix%/*}
    [[ -n ${tracked_ref[$prefix]+set} ]] && return 0
  done
  return 1
}

has_tracked_conflict() {
  local entry=$1
  has_snapshot_conflict "$entry" source_index || has_snapshot_conflict "$entry" destination_index
}

select_conflict_free() {
  local candidates_file=$1 output_file=$2 path
  : >"$output_file"
  while IFS= read -r -d '' path; do
    if has_tracked_conflict "$path"; then
      warn "tracked path conflict: $path"
    else
      printf '%s\0' "$path" >>"$output_file"
    fi
  done <"$candidates_file"
}

select_safe_destinations() {
  local worktree=$1 candidates_file=$2 output_file=$3 path

  : >"$output_file"
  while IFS= read -r -d '' path; do
    if [[ -e $worktree/$path || -L $worktree/$path ]]; then
      warn "destination exists: $worktree/$path"
    elif inspect_parent_chain "$worktree" "$path"; then
      warn "destination has a symlink or non-directory parent: $worktree/$path"
    else
      printf '%s\0' "$path" >>"$output_file"
    fi
  done <"$candidates_file"
}

install_entry() {
  local mode=$1 source=$2 worktree=$3 entry=$4 status
  local source_path=$source/$entry destination=$worktree/$entry

  if has_tracked_conflict "$entry"; then
    warn "tracked path conflict: $entry"
    return 1
  fi
  inspect_parent_chain "$source" "$entry"
  status=$?
  if ((status == 0)); then
    warn "source has a symlink or non-directory parent: $entry"
    return 1
  elif ((status == 2)) || [[ ! -L $source_path && ! -f $source_path ]]; then
    warn "source is no longer a regular file or symlink: $source_path"
    return 1
  fi
  if [[ -e $destination || -L $destination ]]; then
    warn "destination exists: $destination"
    return 1
  fi
  if inspect_parent_chain "$worktree" "$entry"; then
    warn "destination has a symlink or non-directory parent: $destination"
    return 1
  fi
  if ! mkdir -p "${destination%/*}"; then
    warn "could not create destination parent: ${destination%/*}"
    return 1
  fi

  if [[ $mode == symlink ]]; then
    if ! ln -s "$source_path" "$destination"; then
      warn "could not create symlink: $destination"
      return 1
    fi
    printf 'linked: %s -> %s\n' "$destination" "$source_path"
  else
    if ! cp -P "$source_path" "$destination"; then
      warn "copy failed: partial destination may remain: $destination"
      return 1
    fi
    printf 'copied: %s -> %s\n' "$source_path" "$destination"
  fi
}

main() {
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found, skipping"
    return 0
  fi

  local event_path
  event_path=$(jq -r '.data.worktree.path // .worktree.path // empty' \
    <<<"${HERDR_PLUGIN_EVENT_JSON:-}" 2>/dev/null)
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
  [[ $source != "$worktree" ]] || return 0

  local mode=symlink config=$source/$CONFIG_NAME include_file=$source/$INCLUDE_FILE
  if [[ -e $config || -L $config ]]; then
    if [[ ! -f $config || ! -r $config ]]; then
      warn "$CONFIG_NAME is not a readable file, skipping"
      return 0
    fi
    mode=$(read_config "$config") || return 0
  fi

  [[ -e $include_file || -L $include_file ]] || return 0
  if [[ ! -f $include_file || ! -r $include_file ]]; then
    warn "$INCLUDE_FILE is not a readable file, skipping"
    return 0
  fi

  TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/herdr-worktree-include.XXXXXX" 2>/dev/null)
  if [[ -z $TEMP_DIR ]]; then
    warn "could not create a temporary directory, skipping"
    return 0
  fi
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local source_ignore_case=false
  source_ignore_case=$(git -C "$source" config --bool core.ignoreCase 2>/dev/null) || source_ignore_case=false

  local declarations_file=$TEMP_DIR/declarations matched_file=$TEMP_DIR/matched
  local leaves_file=$TEMP_DIR/leaves conflict_free_file=$TEMP_DIR/conflict-free
  local entries_file=$TEMP_DIR/entries
  read_declarations "$source" "$include_file" "$declarations_file" "$source_ignore_case"
  select_ignored_untracked "$source" "$declarations_file" "$matched_file" \
    "$source_ignore_case" || return 0
  validate_source_leaves "$source" "$matched_file" "$leaves_file"

  # These sets are passed by name to the conflict checks.
  # shellcheck disable=SC2034
  local -A source_index_tracked=() source_index_descendants=()
  # shellcheck disable=SC2034
  local -A destination_index_tracked=() destination_index_descendants=()
  # shellcheck disable=SC2034
  local source_index_ignore_case=false destination_index_ignore_case=false
  snapshot_index "$source" source_index || return 0
  snapshot_index "$worktree" destination_index || return 0
  select_conflict_free "$leaves_file" "$conflict_free_file"
  select_safe_destinations "$worktree" "$conflict_free_file" "$entries_file"

  local -a entries=()
  mapfile -d '' -t entries <"$entries_file"
  ((${#entries[@]})) || return 0

  local entry created=0 skipped=0
  for entry in "${entries[@]}"; do
    if install_entry "$mode" "$source" "$worktree" "$entry"; then
      created=$((created + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  printf '%s: %s %d, skipped %d\n' "$PLUGIN_NAME" "$mode" "$created" "$skipped"
}

main "$@"
exit 0
