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

START_TIME=${EPOCHREALTIME:-0}
DIAGNOSTIC_PLAN_TIER=whole-tree
declare -A COMMAND_COUNTS=()
declare -A METRICS=()
declare -A PHASE_TIMES=()
DIAGNOSTICS_WRITTEN=0

count_command() {
  local role=$1
  COMMAND_COUNTS[$role]=$(( ${COMMAND_COUNTS[$role]:-0} + 1 ))
}

record_phase() {
  local phase=$1 start=$2
  [[ -n ${HERDR_WORKTREE_INCLUDE_DIAGNOSTICS:-} ]] || return 0
  PHASE_TIMES[$phase]=$(elapsed_since "$start")
}

# ShellCheck cannot see that the EXIT trap invokes this chain.
# shellcheck disable=SC2329
elapsed_since() {
  local start=$1
  awk -v start="$start" -v end="${EPOCHREALTIME:-0}" 'BEGIN { printf "%.6f", end - start }'
}

# shellcheck disable=SC2329
write_diagnostics() {
  local destination=${HERDR_WORKTREE_INCLUDE_DIAGNOSTICS:-}
  [[ -n $destination && $DIAGNOSTICS_WRITTEN == 0 ]] || return 0
  DIAGNOSTICS_WRITTEN=1

  local roots_file=${TEMP_DIR:-${TMPDIR:-/tmp}}/diagnostic-roots
  : >"$roots_file" || return 0
  if [[ -f ${TEMP_DIR:-}/plan-roots ]]; then
    cp "$TEMP_DIR/plan-roots" "$roots_file" || return 0
  fi

  local roots_json
  roots_json=$(jq -Rs 'split("\u0000") | map(select(length > 0))' "$roots_file") || return 0
  jq -n \
    --arg tier "$DIAGNOSTIC_PLAN_TIER" \
    --argjson roots "$roots_json" \
    --arg total_seconds "$(elapsed_since "$START_TIME")" \
    --argjson discovery_leaves "${COMMAND_COUNTS[discovery_leaves]:-0}" \
    --argjson discovery_directories "${COMMAND_COUNTS[discovery_directories]:-0}" \
    --argjson direct_directory_probes "${COMMAND_COUNTS[direct_directory_probes]:-0}" \
    --argjson standard_ignores "${COMMAND_COUNTS[standard_ignores]:-0}" \
    --argjson source_index_snapshots "${COMMAND_COUNTS[source_index_snapshots]:-0}" \
    --argjson destination_index_snapshots "${COMMAND_COUNTS[destination_index_snapshots]:-0}" \
    --argjson special_find "${COMMAND_COUNTS[special_find]:-0}" \
    --argjson special_match "${COMMAND_COUNTS[special_match]:-0}" \
    --argjson repository_validations "${COMMAND_COUNTS[repository_validations]:-0}" \
    --argjson candidates "${METRICS[candidates]:-0}" \
    --argjson accepted_directories "${METRICS[accepted_directories]:-0}" \
    --argjson leaves "${METRICS[leaves]:-0}" \
    --argjson inspected_entries "${METRICS[inspected_entries]:-0}" \
    --arg planning_seconds "${PHASE_TIMES[planning]:-0}" \
    --arg discovery_seconds "${PHASE_TIMES[discovery]:-0}" \
    --arg classification_seconds "${PHASE_TIMES[classification]:-0}" \
    --arg standard_ignores_seconds "${PHASE_TIMES[standard_ignores]:-0}" \
    --arg index_snapshots_seconds "${PHASE_TIMES[index_snapshots]:-0}" \
    --arg safety_seconds "${PHASE_TIMES[safety]:-0}" \
    --arg recheck_seconds "${PHASE_TIMES[recheck]:-0}" \
    --arg installation_seconds "${PHASE_TIMES[installation]:-0}" \
    '{
      plan: {tier: $tier, roots: $roots},
      commands: {
        discovery_leaves: $discovery_leaves,
        discovery_directories: $discovery_directories,
        direct_directory_probes: $direct_directory_probes,
        standard_ignores: $standard_ignores,
        source_index_snapshots: $source_index_snapshots,
        destination_index_snapshots: $destination_index_snapshots,
        special_find: $special_find,
        special_match: $special_match,
        repository_validations: $repository_validations
      },
      counts: {
        candidates: $candidates,
        accepted_directories: $accepted_directories,
        leaves: $leaves,
        scoped_roots: ($roots | length),
        inspected_entries: $inspected_entries
      },
      timing: {
        total_seconds: ($total_seconds | tonumber),
        planning_seconds: ($planning_seconds | tonumber),
        discovery_seconds: ($discovery_seconds | tonumber),
        classification_seconds: ($classification_seconds | tonumber),
        standard_ignores_seconds: ($standard_ignores_seconds | tonumber),
        index_snapshots_seconds: ($index_snapshots_seconds | tonumber),
        safety_seconds: ($safety_seconds | tonumber),
        recheck_seconds: ($recheck_seconds | tonumber),
        installation_seconds: ($installation_seconds | tonumber)
      }
    }' >"$destination" 2>/dev/null || true
}

# shellcheck disable=SC2329
cleanup_temp() {
  write_diagnostics
  [[ -z ${TEMP_DIR:-} ]] || rm -rf "$TEMP_DIR"
}

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
      .. | .git) return 1 ;;
      *) kept+=("$component") ;;
    esac
  done

  local normalized="${kept[*]}"
  case $normalized in
    '' | .git | .git/*) return 1 ;;
  esac

  printf '%s' "$normalized"
}

# Classifies one positive Git-ignore pattern. It prints a NUL-delimited tier
# and root. Uncertain syntax is deliberately unscopable.
classify_include_pattern() {
  local pattern=$1
  local length=${#pattern} index=0 character escaped=0
  local decoded='' prefix='' component='' rooted=0 meta=0 bracket_open=0

  [[ -n $pattern ]] || return 1
  if [[ ${pattern:0:1} == / ]]; then
    rooted=1
    index=1
  fi

  if [[ ${pattern: -1} == / ]]; then
    length=$((length - 1))
  fi

  if [[ ${pattern: -1} == ' ' ]]; then
    local trailing_backslashes=${pattern% }
    trailing_backslashes=${trailing_backslashes##*[^\\]}
    (( ${#trailing_backslashes} % 2 == 1 )) || return 1
  fi

  while ((index < length)); do
    character=${pattern:index:1}
    if ((escaped)); then
      case $character in
        \\ | \* | \? | \[ | \] | ' ' | \! | \#) ;;
        *) return 1 ;;
      esac
      decoded+=$character
      component+=$character
      escaped=0
      index=$((index + 1))
      continue
    fi
    case $character in
      \\)
        escaped=1
        ;;
      /)
        [[ -n $component ]] || return 1
        rooted=1
        decoded+=/
        if ((meta == 0)); then
          prefix=${prefix:+$prefix/}$component
        fi
        component=
        ;;
      \* | \?)
        meta=1
        decoded+=$character
        component+=$character
        ;;
      \[)
        meta=1
        bracket_open=1
        decoded+=$character
        component+=$character
        ;;
      \])
        ((bracket_open)) || return 1
        bracket_open=0
        decoded+=$character
        component+=$character
        ;;
      *)
        decoded+=$character
        component+=$character
        ;;
    esac
    index=$((index + 1))
  done

  ((escaped == 0 && bracket_open == 0)) || return 1
  [[ -n $component ]] || return 1
  if ((meta == 0)); then
    [[ $rooted == 1 ]] || return 1
    normalize_path "$decoded" >/dev/null || return 1
    printf 'literal\0%s\0' "$decoded"
    return 0
  fi

  [[ $rooted == 1 && -n $prefix ]] || return 1
  normalize_path "$prefix" >/dev/null || return 1
  printf 'prefix\0%s\0' "$prefix"
}

plan_selection() {
  local source=$1 tier_name=$2 roots_name=$3 literals_name=$4
  shift 4
  # The outputs are assigned through names supplied by the caller.
  # shellcheck disable=SC2034
  local -n tier_ref=$tier_name roots_ref=$roots_name literals_ref=$literals_name

  tier_ref='rooted-literal'
  roots_ref=()
  literals_ref=()

  local ignore_case=false file line positive tier root
  local -A seen=()
  ignore_case=$(git -C "$source" config --bool core.ignoreCase 2>/dev/null) || ignore_case=false

  for file in "$@"; do
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -n $line ]] || continue
      if [[ $line == *$'\r' ]]; then
        tier_ref=whole-tree
        roots_ref=()
        literals_ref=()
        return 0
      fi
      case $line in
        \#*) continue ;;
        !*) continue ;;
      esac
      positive=$line
      if [[ $positive == \\#* || $positive == \\!* ]]; then
        positive=${positive:1}
      fi

      local -a fields=()
      mapfile -d '' -t fields < <(classify_include_pattern "$positive")
      if ((${#fields[@]} != 2)); then
        tier_ref=whole-tree
        roots_ref=()
        literals_ref=()
        return 0
      fi
      tier=${fields[0]}
      root=${fields[1]}
      if [[ $tier == prefix ]]; then
        tier_ref='rooted-prefix'
      else
        literals_ref+=("$root")
      fi
      [[ -n ${seen[$root]+set} ]] || {
        seen[$root]=1
        roots_ref+=("$root")
      }
    done <"$file"
  done

  if [[ $ignore_case == true && ${#roots_ref[@]} -gt 0 ]]; then
    tier_ref=whole-tree
    roots_ref=()
    literals_ref=()
    return 0
  fi

  # Remove roots already covered by a shallower directory root.
  local -a minimized=()
  local candidate existing covered
  for candidate in "${roots_ref[@]}"; do
    covered=0
    for existing in "${roots_ref[@]}"; do
      [[ $candidate != "$existing" && $candidate == "$existing"/* ]] && covered=1 && break
    done
    ((covered)) || minimized+=("$candidate")
  done
  roots_ref=("${minimized[@]}")

  if [[ -n ${HERDR_WORKTREE_INCLUDE_DIAGNOSTICS:-} && \
    ${HERDR_WORKTREE_INCLUDE_FORCE_WHOLE_TREE:-0} == 1 ]]; then
    # shellcheck disable=SC2034 # tier_ref is a nameref output.
    tier_ref=whole-tree
    roots_ref=()
    literals_ref=()
  fi
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

snapshot_index() {
  local repository=$1 role=$2 snapshot_name=$3
  local tracked_name=${snapshot_name}_tracked descendants_name=${snapshot_name}_descendants
  local ignore_case_name=${snapshot_name}_ignore_case
  local -n tracked_ref=$tracked_name descendants_ref=$descendants_name ignore_case_ref=$ignore_case_name
  local snapshot_file=$TEMP_DIR/index-snapshot-$role path key prefix

  tracked_ref=()
  descendants_ref=()
  ignore_case_ref=$(git -C "$repository" config --bool core.ignoreCase 2>/dev/null) || ignore_case_ref=false

  count_command "${role}_index_snapshots"
  if ! git -C "$repository" ls-files -z >"$snapshot_file"; then
    warn "could not inspect tracked paths, skipping"
    return 1
  fi

  while IFS= read -r -d '' path; do
    key=$path
    [[ $ignore_case_ref == true ]] && key=${key,,}
    tracked_ref["$key"]=1

    prefix=$key
    while [[ $prefix == */* ]]; do
      prefix=${prefix%/*}
      descendants_ref["$prefix"]=1
    done
  done <"$snapshot_file"
}

has_snapshot_conflict() {
  local entry=$1 snapshot_name=$2
  local tracked_reference_name=${snapshot_name}_tracked
  local descendants_reference_name=${snapshot_name}_descendants
  local ignore_case_reference_name=${snapshot_name}_ignore_case
  # shellcheck disable=SC2178
  local -n tracked_ref=$tracked_reference_name descendants_ref=$descendants_reference_name
  local -n ignore_case_ref=$ignore_case_reference_name
  local key=$entry prefix
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
  local entry=$1 source_snapshot=$2 destination_snapshot=$3
  has_snapshot_conflict "$entry" "$source_snapshot" || \
    has_snapshot_conflict "$entry" "$destination_snapshot"
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

  local include_file include_path snapshot count=0

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
    if ! cp "$include_path" "$snapshot"; then
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

  count_command direct_directory_probes
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

is_plausible_repository_root() {
  local directory=$1
  [[ -e $directory/.git || -L $directory/.git ]] || \
    [[ -f $directory/HEAD && -d $directory/objects && -d $directory/refs ]]
}

inspect_directory_tree() {
  local root=$1
  local -a pending=("$root") children=()
  local directory child head=0

  while ((head < ${#pending[@]})); do
    directory=${pending[head]}
    head=$((head + 1))
    METRICS[inspected_entries]=$(( ${METRICS[inspected_entries]:-0} + 1 ))

    if is_plausible_repository_root "$directory"; then
      count_command repository_validations
      if is_repository_root "$directory"; then
        return 0
      fi
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

# Trims a leading "./" and trailing "/" from each NUL-delimited entry.
read_null_set() {
  local file=$1 array_name=$2
  local -n set_ref=$array_name
  local path

  while IFS= read -r -d '' path; do
    path=${path#./}
    path=${path%/}
    # shellcheck disable=SC2034,SC2004 # set_ref is a nameref array target.
    [[ -n $path ]] && set_ref[$path]=1
  done <"$file"
}

directory_tree_is_safe() {
  local source=$1 directory=$2 status

  inspect_directory_tree "$source/$directory"
  status=$?
  if ((status == 0)); then
    warn "selected directory contains a nested Git repository: $directory"
    return 1
  elif ((status == 2)); then
    warn "could not inspect selected directory: $directory"
    return 1
  elif ((status == 3)); then
    warn "selected directory contains an unsupported source type: $directory"
    return 1
  fi

  return 0
}

# Special files (fifos, sockets, devices) don't show up in a normal tree
# walk, so they're matched separately against a synthetic index.
discover_candidates() {
  local source=$1 selection_index=$2 leaves_file=$3 collapsed_file=$4 plan_tier=$5
  local roots_name=$6 literals_name=$7
  shift 7
  local -n plan_roots_ref=$roots_name plan_literals_ref=$literals_name

  local -a pathspecs=() directory_pathspecs=()
  local root
  if [[ $plan_tier != whole-tree ]]; then
    for root in "${plan_roots_ref[@]}"; do
      pathspecs+=(":(top,literal)$root")
      if [[ -d $source/$root && ! -L $source/$root ]]; then
        directory_pathspecs+=(":(top,literal)$root")
      fi
    done
  fi

  count_command discovery_leaves
  if ! GIT_INDEX_FILE=$selection_index git -C "$source" read-tree --empty || \
    ! GIT_INDEX_FILE=$selection_index git -C "$source" ls-files --others --ignored -z \
    "$@" -- "${pathspecs[@]}" >"$leaves_file"; then
    warn "could not evaluate include patterns, skipping"
    return 1
  fi

  : >"$collapsed_file"
  if [[ $plan_tier != rooted-literal || ${#directory_pathspecs[@]} -gt 0 ]]; then
    count_command discovery_directories
    local -a collapsed_pathspecs=("${pathspecs[@]}")
    if [[ $plan_tier == rooted-literal ]]; then
      collapsed_pathspecs=("${directory_pathspecs[@]}")
    fi
    if ! GIT_INDEX_FILE=$selection_index git -C "$source" ls-files --others --ignored --directory -z \
      "$@" -- "${collapsed_pathspecs[@]}" >"$collapsed_file"; then
      warn "could not evaluate include directories, skipping"
      return 1
    fi
  fi

  local special_paths_file=$TEMP_DIR/special-paths
  local special_index_input=$TEMP_DIR/special-index-input
  local special_index=$TEMP_DIR/special-index

  : >"$special_paths_file"
  if [[ $plan_tier == rooted-literal ]]; then
    for root in "${plan_roots_ref[@]}"; do
      if [[ -e $source/$root || -L $source/$root ]]; then
        if [[ ! -f $source/$root && ! -d $source/$root && ! -L $source/$root ]]; then
          printf '%s\0' "$source/$root" >>"$special_paths_file"
        elif [[ -d $source/$root && ! -L $source/$root ]]; then
          count_command special_find
          find "$source/$root" -name .git -prune -o \
            ! -type f ! -type d ! -type l -print0 >>"$special_paths_file" 2>/dev/null || true
        fi
      fi
    done
  elif [[ $plan_tier == rooted-prefix ]]; then
    for root in "${plan_literals_ref[@]}"; do
      if [[ -e $source/$root || -L $source/$root ]] && \
        [[ ! -f $source/$root && ! -d $source/$root && ! -L $source/$root ]]; then
        printf '%s\0' "$source/$root" >>"$special_paths_file"
      fi
    done
    for root in "${plan_roots_ref[@]}"; do
      [[ -d $source/$root && ! -L $source/$root ]] || continue
      count_command special_find
      find "$source/$root" -name .git -prune -o \
        ! -type f ! -type d ! -type l -print0 >>"$special_paths_file" 2>/dev/null || true
    done
  else
    count_command special_find
    find "$source" -name .git -prune -o \
      ! -type f ! -type d ! -type l -print0 >"$special_paths_file" 2>/dev/null || true
  fi

  [[ -s $special_paths_file ]] || return 0

  local empty_blob
  count_command special_match
  empty_blob=$(git -C "$source" hash-object -t blob --stdin </dev/null) || {
    warn "could not prepare source type matching, skipping"
    return 1
  }

  local path
  local -A seen_special=()
  : >"$special_index_input"
  while IFS= read -r -d '' path; do
    path=${path#"$source"/}
    [[ -z ${seen_special[$path]+set} ]] || continue
    seen_special[$path]=1
    printf '100644 %s\t%s\0' "$empty_blob" "$path" >>"$special_index_input"
  done <"$special_paths_file"

  if [[ -s $special_index_input ]]; then
    if ! GIT_INDEX_FILE=$special_index git -C "$source" read-tree --empty || \
      ! GIT_INDEX_FILE=$special_index git -C "$source" update-index -z --index-info \
        <"$special_index_input" || \
      ! GIT_INDEX_FILE=$special_index git -C "$source" ls-files --cached --ignored -z \
        "$@" >>"$leaves_file"; then
      warn "could not evaluate include patterns for special files, skipping"
      return 1
    fi
  fi
}

collect_directory_candidates() {
  local source=$1 leaves_file=$2 collapsed_file=$3 candidates_file=$4 plan_tier=$5

  local -A leaves=() seen=()
  read_null_set "$leaves_file" leaves

  local path directory ancestor
  local -a ancestors=()

  : >"$candidates_file"
  while IFS= read -r -d '' path; do
    [[ $path == */ ]] || continue
    directory=${path%/}
    if [[ -z ${seen[$directory]+set} ]]; then
      seen[$directory]=1
      printf '%s\0' "$directory" >>"$candidates_file"
    fi
  done <"$collapsed_file"

  # Exact file targets cannot make their ancestors atomic. For a literal plan,
  # the collapsed traversal already contains every explicit directory target.
  [[ $plan_tier == rooted-literal ]] && return 0

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
      if [[ -z ${seen[$ancestor]+set} ]]; then
        seen[$ancestor]=1
        printf '%s\0' "$ancestor" >>"$candidates_file"
      fi
    done
  done
}

classify_direct_directories() {
  local source=$1 selection_index=$2 probe_file=$3 candidates_file=$4 direct_directories_file=$5
  shift 5

  local directory status
  : >"$direct_directories_file"
  while IFS= read -r -d '' directory; do
    if is_direct_directory_match "$source" "$selection_index" "$probe_file" "$directory" "$@"; then
      printf '%s\0' "$directory" >>"$direct_directories_file"
    else
      status=$?
      if ((status == 2)); then
        warn "could not evaluate include directory: $directory"
        return 1
      fi
    fi
  done <"$candidates_file"
}

check_standard_ignores() {
  local source=$1 leaves_file=$2 direct_directories_file=$3 ignored_file=$4

  local ignore_input_file=$TEMP_DIR/ignore-input
  local path status
  local -A seen=()

  : >"$ignore_input_file"
  while IFS= read -r -d '' path; do
    path=${path%/}
    [[ -n $path && -z ${seen[$path]+set} ]] || continue
    seen[$path]=1
    printf './%s\0' "$path" >>"$ignore_input_file"
  done <"$leaves_file"
  while IFS= read -r -d '' path; do
    path=${path%/}
    [[ -n $path && -z ${seen[$path]+set} ]] || continue
    seen[$path]=1
    printf './%s\0' "$path" >>"$ignore_input_file"
  done <"$direct_directories_file"

  METRICS[candidates]=${#seen[@]}

  : >"$ignored_file"
  count_command standard_ignores
  git -C "$source" check-ignore --no-index --stdin -z \
    <"$ignore_input_file" >>"$ignored_file"
  status=$?
  if ((status != 0 && status != 1)); then
    warn "could not inspect standard Git ignores, skipping"
    return 1
  fi
}

# candidates_file is shallowest-first, so accepted/rejected directories are
# recorded here for the leaf pass to skip their descendants.
accept_direct_directories() {
  local source=$1 worktree=$2
  local candidates_file=$3 direct_directories_file=$4 ignored_file=$5 output_file=$6
  local accepted_file=$7 rejected_file=$8
  local source_snapshot=$9 destination_snapshot=${10}

  local -A direct=() ignored=()
  read_null_set "$direct_directories_file" direct
  read_null_set "$ignored_file" ignored

  local -a accepted=() rejected=()
  local directory

  : >"$accepted_file"
  : >"$rejected_file"

  while IFS= read -r -d '' directory; do
    [[ -n ${direct[$directory]+set} ]] || continue
    if is_below_entry "$directory" "${accepted[@]}" || \
      is_below_entry "$directory" "${rejected[@]}"; then
      continue
    fi

    if has_tracked_conflict "$directory" "$source_snapshot" "$destination_snapshot"; then
      warn "tracked path conflict: $directory"
      rejected+=("$directory")
      printf '%s\0' "$directory" >>"$rejected_file"
      continue
    fi

    if ! directory_tree_is_safe "$source" "$directory"; then
      rejected+=("$directory")
      printf '%s\0' "$directory" >>"$rejected_file"
      continue
    fi

    [[ -n ${ignored[$directory]+set} ]] || continue
    accepted+=("$directory")
    METRICS[accepted_directories]=$(( ${METRICS[accepted_directories]:-0} + 1 ))
    printf '%s\0' "$directory" >>"$accepted_file"
    printf '%s\0' "$directory" >>"$output_file"
  done <"$candidates_file"
}

accept_leaf_entries() {
  local source=$1 worktree=$2
  local leaves_file=$3 ignored_file=$4 accepted_directories_file=$5
  local rejected_directories_file=$6 output_file=$7
  local source_snapshot=$8 destination_snapshot=$9

  local -A ignored=()
  read_null_set "$ignored_file" ignored

  local -a accepted=() rejected=()
  mapfile -d '' -t accepted <"$accepted_directories_file"
  mapfile -d '' -t rejected <"$rejected_directories_file"

  local path
  while IFS= read -r -d '' path; do
    path=${path%/}
    [[ -n $path ]] || continue
    [[ -n ${ignored[$path]+set} ]] || continue
    if is_below_entry "$path" "${accepted[@]}" || \
      is_below_entry "$path" "${rejected[@]}"; then
      continue
    fi

    if has_tracked_conflict "$path" "$source_snapshot" "$destination_snapshot"; then
      warn "tracked path conflict: $path"
      continue
    fi

    if [[ -d $source/$path && ! -L $source/$path ]] && ! directory_tree_is_safe "$source" "$path"; then
      continue
    fi

    printf '%s\0' "$path" >>"$output_file"
    METRICS[leaves]=$(( ${METRICS[leaves]:-0} + 1 ))
  done <"$leaves_file"
}

select_entries() {
  local source=$1 worktree=$2 output_file=$3
  shift 3
  local phase_start

  local -a include_args=()
  local include_file
  for include_file in "$@"; do
    include_args+=(--exclude-from="$include_file")
  done
  ((${#include_args[@]})) || return 0

  phase_start=${EPOCHREALTIME:-0}
  local plan_tier
  # plan_literals is passed by name to discovery for mixed plans.
  # shellcheck disable=SC2034
  local -a plan_roots=() plan_literals=()
  plan_selection "$source" plan_tier plan_roots plan_literals "$@"
  DIAGNOSTIC_PLAN_TIER=$plan_tier
  printf '%s\0' "${plan_roots[@]}" >"$TEMP_DIR/plan-roots"
  record_phase planning "$phase_start"

  local selection_index=$TEMP_DIR/selection-index
  local probe_file=$TEMP_DIR/include-probe
  local leaves_file=$TEMP_DIR/include-leaves
  local collapsed_file=$TEMP_DIR/include-collapsed
  local candidates_file=$TEMP_DIR/directory-candidates
  local direct_directories_file=$TEMP_DIR/direct-directories
  local ignored_file=$TEMP_DIR/ignored
  local accepted_directories_file=$TEMP_DIR/accepted-directories
  local rejected_directories_file=$TEMP_DIR/rejected-directories

  if [[ $plan_tier != whole-tree && ${#plan_roots[@]} -eq 0 ]]; then
    : >"$output_file"
    return 0
  fi

  phase_start=${EPOCHREALTIME:-0}
  discover_candidates "$source" "$selection_index" "$leaves_file" "$collapsed_file" \
    "$plan_tier" plan_roots plan_literals \
    "${include_args[@]}" || return 1
  record_phase discovery "$phase_start"

  phase_start=${EPOCHREALTIME:-0}
  collect_directory_candidates "$source" "$leaves_file" "$collapsed_file" "$candidates_file" \
    "$plan_tier"

  classify_direct_directories "$source" "$selection_index" "$probe_file" "$candidates_file" \
    "$direct_directories_file" "${include_args[@]}" || return 1
  record_phase classification "$phase_start"

  phase_start=${EPOCHREALTIME:-0}
  check_standard_ignores "$source" "$leaves_file" "$direct_directories_file" "$ignored_file" || \
    return 1
  record_phase standard_ignores "$phase_start"

  phase_start=${EPOCHREALTIME:-0}
  # These local sets are passed by name to the acceptance phase.
  # shellcheck disable=SC2034
  local -A initial_source_tracked=() initial_source_descendants=()
  # shellcheck disable=SC2034
  local -A initial_destination_tracked=() initial_destination_descendants=()
  # shellcheck disable=SC2034
  local initial_source_ignore_case=false initial_destination_ignore_case=false
  snapshot_index "$source" source initial_source || return 1
  snapshot_index "$worktree" destination initial_destination || return 1
  record_phase index_snapshots "$phase_start"

  : >"$output_file"
  phase_start=${EPOCHREALTIME:-0}
  accept_direct_directories "$source" "$worktree" \
    "$candidates_file" "$direct_directories_file" "$ignored_file" "$output_file" \
    "$accepted_directories_file" "$rejected_directories_file" \
    initial_source initial_destination

  accept_leaf_entries "$source" "$worktree" \
    "$leaves_file" "$ignored_file" "$accepted_directories_file" "$rejected_directories_file" \
    "$output_file" initial_source initial_destination
  record_phase safety "$phase_start"
}

install_entry() {
  local mode=$1 source=$2 worktree=$3 entry=$4
  local source_snapshot=$5 destination_snapshot=$6
  local source_path=$source/$entry
  local destination=$worktree/$entry

  if has_tracked_conflict "$entry" "$source_snapshot" "$destination_snapshot"; then
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
  trap cleanup_temp EXIT
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

  local entries_file=$TEMP_DIR/entries

  if ! select_entries "$source" "$worktree" "$entries_file" "${include_paths[@]}"; then
    return 0
  fi

  local -a entries=()
  mapfile -d '' -t entries <"$entries_file"
  ((${#entries[@]})) || return 0

  local phase_start=${EPOCHREALTIME:-0}
  # These local sets are passed by name to the installation phase.
  # shellcheck disable=SC2034
  local -A fresh_source_tracked=() fresh_source_descendants=()
  # shellcheck disable=SC2034
  local -A fresh_destination_tracked=() fresh_destination_descendants=()
  # shellcheck disable=SC2034
  local fresh_source_ignore_case=false fresh_destination_ignore_case=false
  snapshot_index "$source" source fresh_source || return 0
  snapshot_index "$worktree" destination fresh_destination || return 0
  record_phase recheck "$phase_start"

  local entry created=0 skipped=0
  phase_start=${EPOCHREALTIME:-0}
  for entry in "${entries[@]}"; do
    if install_entry "$mode" "$source" "$worktree" "$entry" fresh_source fresh_destination; then
      created=$((created + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  record_phase installation "$phase_start"

  printf '%s: %s %d, skipped %d\n' "$PLUGIN_NAME" "$mode" "$created" "$skipped"
  return 0
}

main "$@"
exit 0
