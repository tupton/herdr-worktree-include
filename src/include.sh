#!/usr/bin/env bash

PLUGIN_NAME="worktree-include"
CONFIG_NAME=".herdr-worktree-include"
DEFAULT_INCLUDE_FILE=".worktreeinclude"

warn() {
  printf '%s: %s\n' "$PLUGIN_NAME" "$*" >&2
}

trim() {
  TRIMMED=$1
  TRIMMED=${TRIMMED#"${TRIMMED%%[![:space:]]*}"}
  TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
}

# Set NORMALIZED_PATH to a repository-relative path without empty or dot
# components. Parent traversal and Git administrative paths are rejected.
normalize_path() {
  input_path=$1
  NORMALIZED_PATH=

  case "$input_path" in
    ""|/*)
      return 1
      ;;
  esac

  remaining=$input_path
  while :; do
    case "$remaining" in
      */*)
        component=${remaining%%/*}
        remaining=${remaining#*/}
        ;;
      *)
        component=$remaining
        remaining=
        ;;
    esac

    case "$component" in
      ""|.)
        ;;
      ..)
        return 1
        ;;
      *)
        if [ -z "$NORMALIZED_PATH" ]; then
          NORMALIZED_PATH=$component
        else
          NORMALIZED_PATH=$NORMALIZED_PATH/$component
        fi
        ;;
    esac

    [ -z "$remaining" ] && break
  done

  case "$NORMALIZED_PATH" in
    ""|.git|.git/*)
      return 1
      ;;
  esac

  return 0
}

array_contains() {
  needle=$1
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

has_tracked_conflict() {
  candidate=$1

  while IFS= read -r -d '' tracked_path; do
    case "$tracked_path" in
      "$candidate"|"$candidate"/*)
        return 0
        ;;
    esac
    case "$candidate" in
      "$tracked_path"/*)
        return 0
        ;;
    esac
  done < "$TRACKED_PATHS_FILE"

  return 1
}

has_unsafe_destination_parent() {
  relative_path=$1
  parent_path=${relative_path%/*}
  [ "$parent_path" = "$relative_path" ] && return 1

  current_path=$WORKTREE
  remaining_parent=$parent_path
  while [ -n "$remaining_parent" ]; do
    case "$remaining_parent" in
      */*)
        component=${remaining_parent%%/*}
        remaining_parent=${remaining_parent#*/}
        ;;
      *)
        component=$remaining_parent
        remaining_parent=
        ;;
    esac

    current_path=$current_path/$component
    if [ -L "$current_path" ] || { [ -e "$current_path" ] && [ ! -d "$current_path" ]; }; then
      return 0
    fi
  done

  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found, skipping"
  exit 0
fi

WORKTREE=$(jq -r '.data.worktree.path // .worktree.path // empty' <<<"${HERDR_PLUGIN_EVENT_JSON:-}")
if [ -z "$WORKTREE" ] || [ ! -d "$WORKTREE" ]; then
  warn "no valid worktree path in event, skipping"
  exit 0
fi

COMMON=$(git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
TOP=$(git -C "$WORKTREE" rev-parse --show-toplevel 2>/dev/null)
if [ -z "$COMMON" ] || [ -z "$TOP" ]; then
  warn "not a Git worktree: $WORKTREE"
  exit 0
fi

SOURCE=$(dirname "$COMMON")
WORKTREE=$TOP
if [ "$SOURCE" = "$WORKTREE" ]; then
  exit 0
fi

MODE=symlink
MODE_SEEN=0
INCLUDE_FILES=()
CONFIG=$SOURCE/$CONFIG_NAME

if [ -e "$CONFIG" ] || [ -L "$CONFIG" ]; then
  if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ]; then
    warn "$CONFIG_NAME is not a readable file, skipping"
    exit 0
  fi

  config_invalid=0
  line_number=0
  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line_number=$((line_number + 1))
    trim "$raw_line"
    line=$TRIMMED

    case "$line" in
      ""|\#*)
        continue
        ;;
      *=*)
        key=${line%%=*}
        value=${line#*=}
        trim "$key"
        key=$TRIMMED
        trim "$value"
        value=$TRIMMED
        ;;
      *)
        warn "$CONFIG_NAME:$line_number: expected key=value"
        config_invalid=1
        continue
        ;;
    esac

    case "$key" in
      mode)
        if [ "$MODE_SEEN" -eq 1 ]; then
          warn "$CONFIG_NAME:$line_number: mode may only be set once"
          config_invalid=1
          continue
        fi
        case "$value" in
          symlink|copy)
            MODE=$value
            MODE_SEEN=1
            ;;
          *)
            warn "$CONFIG_NAME:$line_number: mode must be symlink or copy"
            config_invalid=1
            ;;
        esac
        ;;
      include_file)
        if ! normalize_path "$value"; then
          warn "$CONFIG_NAME:$line_number: invalid include file path: $value"
          config_invalid=1
          continue
        fi
        if ! array_contains "$NORMALIZED_PATH" "${INCLUDE_FILES[@]}"; then
          INCLUDE_FILES+=("$NORMALIZED_PATH")
        fi
        ;;
      *)
        warn "$CONFIG_NAME:$line_number: unsupported key: $key"
        config_invalid=1
        ;;
    esac
  done < "$CONFIG"

  if [ "$config_invalid" -ne 0 ]; then
    warn "invalid configuration, skipping"
    exit 0
  fi
fi

if [ "${#INCLUDE_FILES[@]}" -eq 0 ]; then
  INCLUDE_FILES+=("$DEFAULT_INCLUDE_FILE")
fi

INCLUDE_PATH=
for include_file in "${INCLUDE_FILES[@]}"; do
  candidate_path=$SOURCE/$include_file
  if [ -e "$candidate_path" ] || [ -L "$candidate_path" ]; then
    INCLUDE_PATH=$candidate_path
    break
  fi
done

if [ -z "$INCLUDE_PATH" ]; then
  exit 0
fi
if [ ! -f "$INCLUDE_PATH" ] || [ ! -r "$INCLUDE_PATH" ]; then
  warn "include path is not a readable file: $INCLUDE_PATH"
  exit 0
fi

ENTRIES=()
include_line_number=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  include_line_number=$((include_line_number + 1))
  trim "$raw_line"
  line=$TRIMMED

  case "$line" in
    ""|\#*)
      continue
      ;;
  esac

  if ! normalize_path "$line"; then
    warn "$INCLUDE_PATH:$include_line_number: invalid path: $line"
    continue
  fi
  if ! array_contains "$NORMALIZED_PATH" "${ENTRIES[@]}"; then
    ENTRIES+=("$NORMALIZED_PATH")
  fi
done < "$INCLUDE_PATH"

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  exit 0
fi

TRACKED_PATHS_FILE=$(mktemp "${TMPDIR:-/tmp}/herdr-worktree-include.XXXXXX" 2>/dev/null)
if [ -z "$TRACKED_PATHS_FILE" ]; then
  warn "could not create a temporary file, skipping"
  exit 0
fi
trap 'rm -f "$TRACKED_PATHS_FILE"' EXIT HUP INT TERM

if ! git -C "$WORKTREE" ls-files -z > "$TRACKED_PATHS_FILE"; then
  warn "could not inspect tracked paths, skipping"
  exit 0
fi

created=0
skipped=0

for entry in "${ENTRIES[@]}"; do
  source_path=$SOURCE/$entry
  destination_path=$WORKTREE/$entry

  if has_tracked_conflict "$entry"; then
    warn "tracked path conflict: $entry"
    skipped=$((skipped + 1))
    continue
  fi

  if [ ! -e "$source_path" ] && [ ! -L "$source_path" ]; then
    warn "source does not exist: $source_path"
    skipped=$((skipped + 1))
    continue
  fi

  if [ -e "$destination_path" ] || [ -L "$destination_path" ]; then
    warn "destination exists: $destination_path"
    skipped=$((skipped + 1))
    continue
  fi

  if has_unsafe_destination_parent "$entry"; then
    warn "destination has a symlink or non-directory parent: $destination_path"
    skipped=$((skipped + 1))
    continue
  fi

  destination_parent=${destination_path%/*}
  if ! mkdir -p "$destination_parent"; then
    warn "could not create destination parent: $destination_parent"
    skipped=$((skipped + 1))
    continue
  fi

  case "$MODE" in
    symlink)
      if ln -s "$source_path" "$destination_path"; then
        printf 'linked: %s -> %s\n' "$destination_path" "$source_path"
        created=$((created + 1))
      else
        warn "could not create symlink: $destination_path"
        skipped=$((skipped + 1))
      fi
      ;;
    copy)
      if cp -RP "$source_path" "$destination_path"; then
        printf 'copied: %s -> %s\n' "$source_path" "$destination_path"
        created=$((created + 1))
      else
        warn "copy failed: partial destination may remain: $destination_path"
        skipped=$((skipped + 1))
      fi
      ;;
  esac
done

printf '%s: %s %d, skipped %d\n' "$PLUGIN_NAME" "$MODE" "$created" "$skipped"
exit 0
