#!/usr/bin/env bash
#
# Herdr worktree.created handler. Symlinks or copies declared leaf entries from
# a repository's main checkout into a newly created worktree.

_worktree_include_warn() {
  printf 'worktree-include: %s\n' "$1" >&2
}

_worktree_include_cleanup() {
  [[ -z ${1:-} ]] || rm -rf "$1"
}

_worktree_include_trim() {
  local text=$1
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

_worktree_include_resolve_worktree() {
  local path=$1 common top

  common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  top=$(git -C "$path" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ -n $common && -n $top ]] || return 1
  printf '%s\0%s\0' "${common%/*}" "$top"
}

_worktree_include_read_config() {
  local config=$1 mode=symlink mode_seen=0 invalid=0
  local line number=0 key value

  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    line=$(_worktree_include_trim "$line")
    [[ -n $line && $line != \#* ]] || continue

    if [[ $line != *=* ]]; then
      _worktree_include_warn ".herdr-worktree-include:$number: expected key=value"
      invalid=1
      continue
    fi

    key=$(_worktree_include_trim "${line%%=*}")
    value=$(_worktree_include_trim "${line#*=}")
    case $key in
      mode)
        if ((mode_seen)); then
          _worktree_include_warn ".herdr-worktree-include:$number: mode may only be set once"
          invalid=1
        elif [[ $value == symlink || $value == copy ]]; then
          mode=$value
          mode_seen=1
        else
          _worktree_include_warn ".herdr-worktree-include:$number: mode must be symlink or copy"
          invalid=1
        fi
        ;;
      *)
        _worktree_include_warn ".herdr-worktree-include:$number: unsupported key: $key"
        invalid=1
        ;;
    esac
  done <"$config"

  if ((invalid)); then
    _worktree_include_warn "invalid configuration, skipping"
    return 1
  fi
  printf '%s' "$mode"
}

_worktree_include_normalize_declaration() {
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
_worktree_include_inspect_parent_chain() {
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

_worktree_include_read_declarations() {
  local source=$1 include_file=$2 ignore_case=$3 output_name=$4
  local line number=0 path status key
  local -A seen=()
  # shellcheck disable=SC2178 # The reference points to an indexed array.
  local -n output_ref=$output_name

  output_ref=()
  while IFS= read -r line || [[ -n $line ]]; do
    number=$((number + 1))
    [[ -n $line && $line != \#* ]] || continue

    if ! path=$(_worktree_include_normalize_declaration "$line"); then
      _worktree_include_warn ".worktreeinclude:$number: unsupported pattern, ignoring"
      continue
    fi
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    [[ -z ${seen[$key]+set} ]] || continue
    seen[$key]=1

    _worktree_include_inspect_parent_chain "$source" "$path"
    status=$?
    if ((status == 0)); then
      _worktree_include_warn "source has a symlink or non-directory parent: $path"
      continue
    elif ((status == 1)) && [[ -e $source/$path && ! -L $source/$path && ! -f $source/$path ]]; then
      _worktree_include_warn "not a regular file or symlink: $path"
      continue
    fi
    # Missing paths remain candidates so Git can resolve case differences when
    # core.ignoreCase is enabled. Git quietly omits genuinely missing paths.
    output_ref+=("$path")
  done <"$include_file"
}

_worktree_include_select_ignored_untracked() {
  local source=$1 ignore_case=$2 temp_dir=$3 declarations_name=$4 output_name=$5
  local path key
  local -a pathspecs=()
  local -A resolved_paths=() ambiguous_paths=()
  local -n declarations_ref=$declarations_name
  # shellcheck disable=SC2178 # The reference points to an indexed array.
  local -n output_ref=$output_name

  output_ref=()
  ((${#declarations_ref[@]})) || return 0

  for path in "${declarations_ref[@]}"; do
    if [[ $ignore_case == true ]]; then
      pathspecs+=(":(top,icase,literal)$path")
    else
      pathspecs+=(":(top,literal)$path")
    fi
  done

  local matches_file=$temp_dir/ignored-untracked
  if ! GIT_LITERAL_PATHSPECS=0 GIT_GLOB_PATHSPECS=0 GIT_NOGLOB_PATHSPECS=0 \
    GIT_ICASE_PATHSPECS=0 git -C "$source" ls-files --others --ignored \
      --exclude-standard -z -- "${pathspecs[@]}" >"$matches_file"; then
    _worktree_include_warn "could not inspect ignored files, skipping"
    return 1
  fi

  while IFS= read -r -d '' path; do
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    if [[ -n ${resolved_paths[$key]+set} && ${resolved_paths[$key]} != "$path" ]]; then
      ambiguous_paths[$key]=1
    else
      resolved_paths[$key]=$path
    fi
  done <"$matches_file"

  for path in "${declarations_ref[@]}"; do
    key=$path
    [[ $ignore_case == true ]] && key=${key,,}
    [[ -n ${resolved_paths[$key]+set} ]] || continue
    if [[ -n ${ambiguous_paths[$key]+set} ]]; then
      _worktree_include_warn "ambiguous case-insensitive path: $path"
      continue
    fi
    output_ref+=("${resolved_paths[$key]}")
  done
}

_worktree_include_validate_source_leaves() {
  local source=$1 candidates_name=$2 output_name=$3 path status
  local -n candidates_ref=$candidates_name
  # shellcheck disable=SC2178 # The reference points to an indexed array.
  local -n output_ref=$output_name

  output_ref=()
  for path in "${candidates_ref[@]}"; do
    _worktree_include_inspect_parent_chain "$source" "$path"
    status=$?
    if ((status == 0)); then
      _worktree_include_warn "source has a symlink or non-directory parent: $path"
    elif ((status == 2)); then
      continue
    elif [[ -L $source/$path || -f $source/$path ]]; then
      output_ref+=("$path")
    elif [[ -e $source/$path ]]; then
      _worktree_include_warn "not a regular file or symlink: $path"
    fi
  done
}

_worktree_include_snapshot_index() {
  local repository=$1 snapshot_file=$2 tracked_name=$3 descendants_name=$4 ignore_case_name=$5
  local path key prefix
  # shellcheck disable=SC2178 # The references point to caller-owned values.
  local -n tracked_ref=$tracked_name descendants_ref=$descendants_name ignore_case_ref=$ignore_case_name

  tracked_ref=()
  descendants_ref=()
  ignore_case_ref=$(git -C "$repository" config --bool core.ignoreCase 2>/dev/null) || ignore_case_ref=false
  if ! git -C "$repository" ls-files --cached -z >"$snapshot_file"; then
    _worktree_include_warn "could not inspect tracked paths, skipping"
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

# Returns 0 for an exact conflict, 1 for no conflict, and 2 for a conflict
# above or below the entry.
_worktree_include_snapshot_conflict_kind() {
  local entry=$1 tracked_name=$2 descendants_name=$3 ignore_case=$4 key prefix
  key=$entry
  # shellcheck disable=SC2178 # The references point to associative arrays.
  local -n tracked_ref=$tracked_name descendants_ref=$descendants_name

  [[ $ignore_case == true ]] && key=${key,,}
  [[ -z ${tracked_ref[$key]+set} ]] || return 0
  [[ -z ${descendants_ref[$key]+set} ]] || return 2

  prefix=$key
  while [[ $prefix == */* ]]; do
    prefix=${prefix%/*}
    [[ -z ${tracked_ref[$prefix]+set} ]] || return 2
  done
  return 1
}

# Prints the entries that are conflict-free in both checkout indexes. This
# module owns the snapshot representation and tracked-path conflict policy.
_worktree_include_filter_tracked_conflicts() {
  local source=$1 worktree=$2 temp_dir=$3 path conflict
  shift 3
  # shellcheck disable=SC2034 # The arrays are passed by name to private helpers.
  local -A source_tracked=() source_descendants=()
  # shellcheck disable=SC2034 # The arrays are passed by name to private helpers.
  local -A destination_tracked=() destination_descendants=()
  local source_ignore_case=false destination_ignore_case=false

  (($#)) || return 0
  _worktree_include_snapshot_index "$source" "$temp_dir/source-index" \
    source_tracked source_descendants source_ignore_case || return 1
  _worktree_include_snapshot_index "$worktree" "$temp_dir/destination-index" \
    destination_tracked destination_descendants destination_ignore_case || return 1

  for path in "$@"; do
    _worktree_include_snapshot_conflict_kind "$path" source_tracked \
      source_descendants "$source_ignore_case"
    conflict=$?
    if ((conflict == 0)); then
      continue
    elif ((conflict == 2)); then
      _worktree_include_warn "tracked path conflict: $path"
      continue
    fi

    _worktree_include_snapshot_conflict_kind "$path" destination_tracked \
      destination_descendants "$destination_ignore_case"
    conflict=$?
    if ((conflict != 1)); then
      _worktree_include_warn "tracked path conflict: $path"
      continue
    fi
    printf '%s\n' "$path"
  done
}

_worktree_include_select_eligible_leaf_entries_impl() {
  local source=$1 worktree=$2 include_file=$3
  local source_ignore_case=false temp_dir='' cleanup_command
  # shellcheck disable=SC2034 # The arrays are passed by name to private helpers.
  local -a declarations=() matched=() leaves=()

  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/herdr-worktree-include.XXXXXX" 2>/dev/null)
  if [[ -z $temp_dir ]]; then
    _worktree_include_warn "could not create a temporary directory, skipping"
    return 1
  fi
  printf -v cleanup_command '_worktree_include_cleanup %q' "$temp_dir"
  # shellcheck disable=SC2064 # Capture the local path before the EXIT trap runs.
  trap "$cleanup_command" EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  source_ignore_case=$(git -C "$source" config --bool core.ignoreCase 2>/dev/null) || source_ignore_case=false
  if ! _worktree_include_read_declarations "$source" "$include_file" \
    "$source_ignore_case" declarations; then
    _worktree_include_warn "could not read .worktreeinclude, skipping"
    return 1
  fi
  _worktree_include_select_ignored_untracked "$source" "$source_ignore_case" \
    "$temp_dir" declarations matched || return 1
  _worktree_include_validate_source_leaves "$source" matched leaves
  ((${#leaves[@]})) || return 0

  _worktree_include_filter_tracked_conflicts \
    "$source" "$worktree" "$temp_dir" "${leaves[@]}"
}

_worktree_include_select_eligible_leaf_entries() {
  local _worktree_include_source=${1:-}
  local _worktree_include_worktree=${2:-}
  local _worktree_include_output_name=${3:-}

  if [[ ${BASH_VERSINFO[0]:-0} -lt 5 ]]; then
    _worktree_include_warn "Bash 5 or newer is required, found ${BASH_VERSION:-unknown}, skipping"
    return 1
  fi
  if (($# != 3)) || [[ -z $_worktree_include_source || -z $_worktree_include_worktree || \
    ! $_worktree_include_output_name =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ || \
    $_worktree_include_output_name == _worktree_include_* ]]; then
    _worktree_include_warn "Eligible leaf entry selection requires source, worktree, and output array"
    return 1
  fi

  local -n _worktree_include_result_ref=$_worktree_include_output_name
  local _worktree_include_declaration
  _worktree_include_declaration=$(declare -p "$_worktree_include_output_name" 2>/dev/null) || true
  if [[ $_worktree_include_declaration != "declare -a "* ]]; then
    _worktree_include_warn "Eligible leaf entry selection output must be an indexed array"
    return 1
  fi

  local _worktree_include_file=$_worktree_include_source/.worktreeinclude
  local _worktree_include_serialized=
  local -a _worktree_include_complete_result=()
  _worktree_include_result_ref=()

  [[ -e $_worktree_include_file || -L $_worktree_include_file ]] || return 0
  if [[ ! -f $_worktree_include_file || ! -r $_worktree_include_file ]]; then
    _worktree_include_warn ".worktreeinclude is not a readable file, skipping"
    return 1
  fi

  if ! _worktree_include_serialized=$(
    _worktree_include_select_eligible_leaf_entries_impl \
      "$_worktree_include_source" "$_worktree_include_worktree" \
      "$_worktree_include_file"
  ); then
    return 1
  fi
  if [[ -n $_worktree_include_serialized ]]; then
    mapfile -t _worktree_include_complete_result <<<"$_worktree_include_serialized"
  fi

  # shellcheck disable=SC2034 # The variable is an indexed-array nameref.
  _worktree_include_result_ref=("${_worktree_include_complete_result[@]}")
}

_worktree_include_install_entry() {
  local mode=$1 source=$2 worktree=$3 entry=$4 status
  local source_path=$source/$entry destination=$worktree/$entry

  _worktree_include_inspect_parent_chain "$source" "$entry"
  status=$?
  if ((status == 0)); then
    _worktree_include_warn "source has a symlink or non-directory parent: $entry"
    return 1
  elif ((status == 2)) || [[ ! -L $source_path && ! -f $source_path ]]; then
    _worktree_include_warn "source is no longer a regular file or symlink: $source_path"
    return 1
  fi
  if [[ -e $destination || -L $destination ]]; then
    _worktree_include_warn "destination exists: $destination"
    return 1
  fi
  if _worktree_include_inspect_parent_chain "$worktree" "$entry"; then
    _worktree_include_warn "destination has a symlink or non-directory parent: $destination"
    return 1
  fi
  if ! mkdir -p "${destination%/*}"; then
    _worktree_include_warn "could not create destination parent: ${destination%/*}"
    return 1
  fi

  if [[ $mode == symlink ]]; then
    if ! ln -s "$source_path" "$destination"; then
      _worktree_include_warn "could not create symlink: $destination"
      return 1
    fi
    printf 'linked: %s -> %s\n' "$destination" "$source_path"
  else
    if ! cp -P "$source_path" "$destination"; then
      _worktree_include_warn "copy failed: partial destination may remain: $destination"
      return 1
    fi
    printf 'copied: %s -> %s\n' "$source_path" "$destination"
  fi
}

_worktree_include_main() {
  if [[ ${BASH_VERSINFO[0]:-0} -lt 5 ]]; then
    _worktree_include_warn "Bash 5 or newer is required, found ${BASH_VERSION:-unknown}, skipping"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    _worktree_include_warn "jq not found, skipping"
    return 0
  fi

  local event_path
  event_path=$(jq -r '.data.worktree.path // .worktree.path // empty' \
    <<<"${HERDR_PLUGIN_EVENT_JSON:-}" 2>/dev/null)
  if [[ -z $event_path || ! -d $event_path ]]; then
    _worktree_include_warn "no valid worktree path in event, skipping"
    return 0
  fi

  local -a resolved=()
  mapfile -d '' -t resolved < <(_worktree_include_resolve_worktree "$event_path")
  if ((${#resolved[@]} != 2)); then
    _worktree_include_warn "not a Git worktree: $event_path"
    return 0
  fi

  local source=${resolved[0]} worktree=${resolved[1]}
  [[ $source != "$worktree" ]] || return 0

  local mode=symlink config=$source/.herdr-worktree-include
  if [[ -e $config || -L $config ]]; then
    if [[ ! -f $config || ! -r $config ]]; then
      _worktree_include_warn ".herdr-worktree-include is not a readable file, skipping"
      return 0
    fi
    mode=$(_worktree_include_read_config "$config") || return 0
  fi

  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  local -a eligible_entries=() installable_entries=()
  if ! _worktree_include_select_eligible_leaf_entries "$source" "$worktree" \
    eligible_entries; then
    return 0
  fi
  ((${#eligible_entries[@]})) || return 0

  local entry
  for entry in "${eligible_entries[@]}"; do
    if [[ -e $worktree/$entry || -L $worktree/$entry ]]; then
      _worktree_include_warn "destination exists: $worktree/$entry"
    elif _worktree_include_inspect_parent_chain "$worktree" "$entry"; then
      _worktree_include_warn "destination has a symlink or non-directory parent: $worktree/$entry"
    else
      installable_entries+=("$entry")
    fi
  done
  ((${#installable_entries[@]})) || return 0

  local created=0 skipped=0
  for entry in "${installable_entries[@]}"; do
    if _worktree_include_install_entry "$mode" "$source" "$worktree" "$entry"; then
      created=$((created + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  printf 'worktree-include: %s %d, skipped %d\n' "$mode" "$created" "$skipped"
}

if ! (return 0 2>/dev/null); then
  set -uo pipefail
  _worktree_include_main "$@"
  exit 0
fi
