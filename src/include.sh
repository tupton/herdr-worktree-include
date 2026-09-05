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
TRACKED_PATHS_FILE=

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
  local tracked_file=$1 entry=$2
  local tracked

  while IFS= read -r -d '' tracked; do
    case $tracked in
      "$entry" | "$entry"/*) return 0 ;;
    esac
    case $entry in
      "$tracked"/*) return 0 ;;
    esac
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
  local -A seen=()
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
        if [[ -z ${seen[$normalized]+set} ]]; then
          seen[$normalized]=1
          include_files+=("$normalized")
        fi
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

collect_entries() {
  local source=$1
  shift

  local -A seen=()
  local include_file include_path record number line normalized

  for include_file in "$@"; do
    include_path=$source/$include_file

    if [[ ! -e $include_path && ! -L $include_path ]]; then
      continue
    fi
    if [[ ! -f $include_path || ! -r $include_path ]]; then
      warn "include path is not a readable file: $include_path"
      continue
    fi

    while IFS= read -r -d '' record; do
      number=${record%%:*}
      line=${record#*:}

      if ! normalized=$(normalize_path "$line"); then
        warn "$include_path:$number: invalid path: $line"
        continue
      fi
      if [[ -z ${seen[$normalized]+set} ]]; then
        seen[$normalized]=1
        printf '%s\0' "$normalized"
      fi
    done < <(meaningful_lines "$include_path")
  done
}

install_entry() {
  local mode=$1 source=$2 worktree=$3 tracked_file=$4 entry=$5
  local source_path=$source/$entry
  local destination=$worktree/$entry

  if has_tracked_conflict "$tracked_file" "$entry"; then
    warn "tracked path conflict: $entry"
    return 1
  fi
  if [[ ! -e $source_path && ! -L $source_path ]]; then
    warn "source does not exist: $source_path"
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

  local -a entries=()
  mapfile -d '' -t entries < <(collect_entries "$source" "${include_files[@]}")
  ((${#entries[@]})) || return 0

  TRACKED_PATHS_FILE=$(mktemp "${TMPDIR:-/tmp}/herdr-worktree-include.XXXXXX" 2>/dev/null)
  if [[ -z $TRACKED_PATHS_FILE ]]; then
    warn "could not create a temporary file, skipping"
    return 0
  fi
  trap 'rm -f "$TRACKED_PATHS_FILE"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  if ! git -C "$worktree" ls-files -z >"$TRACKED_PATHS_FILE" 2>/dev/null; then
    warn "could not inspect tracked paths, skipping"
    return 0
  fi

  local entry created=0 skipped=0
  for entry in "${entries[@]}"; do
    if install_entry "$mode" "$source" "$worktree" "$TRACKED_PATHS_FILE" "$entry"; then
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
