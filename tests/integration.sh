#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$ROOT/src/include.sh
# Herdr invokes the plugin as `bash src/include.sh`, so PATH lookup is the
# default. CI overrides this to pin an explicit interpreter.
PLUGIN_BASH=${PLUGIN_BASH:-bash}
TEST_ROOT=
passed=0
failed=0

cleanup() {
  if [ -n "$TEST_ROOT" ]; then
    rm -rf "$TEST_ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '  FAIL: %s\n' "$*" >&2
  return 1
}

assert_file() {
  [ -f "$1" ] || fail "expected file: $1"
}

assert_directory() {
  [ -d "$1" ] || fail "expected directory: $1"
}

assert_symlink() {
  [ -L "$1" ] || fail "expected symlink: $1"
}

assert_missing() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "expected missing path: $1"
  fi
}

assert_content() {
  actual=$(<"$1")
  [ "$actual" = "$2" ] || fail "expected '$2' in $1, got '$actual'"
}

assert_link_target() {
  actual=$(readlink "$1")
  [ "$actual" = "$2" ] || fail "expected $1 to target $2, got $actual"
}

assert_output_contains() {
  case "$OUTPUT" in
    *"$1"*)
      return 0
      ;;
    *)
      fail "expected output to contain: $1"
      ;;
  esac
}

setup_repo() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worktree-include-test.XXXXXX") || return 1
  REPO=$TEST_ROOT/repo
  WORKTREE=$TEST_ROOT/worktree

  mkdir "$REPO" || return 1
  git -C "$REPO" init -q || return 1
  git -C "$REPO" config user.email test@example.com || return 1
  git -C "$REPO" config user.name "Worktree Include Tests" || return 1
  DEFAULT_BRANCH=$(git -C "$REPO" symbolic-ref --short HEAD) || return 1
  printf 'tracked\n' > "$REPO/README"
  git -C "$REPO" add README || return 1
  git -C "$REPO" commit -qm "Initial commit" || return 1
  git -C "$REPO" worktree add -q "$WORKTREE" -b test-worktree || return 1

  REPO=$(git -C "$REPO" rev-parse --show-toplevel) || return 1
  WORKTREE=$(git -C "$WORKTREE" rev-parse --show-toplevel) || return 1
  EVENT_JSON=$(jq -cn --arg path "$WORKTREE" '{data:{worktree:{path:$path}}}') || return 1
}

teardown_repo() {
  rm -rf "$TEST_ROOT"
  TEST_ROOT=
}

run_plugin() {
  OUTPUT=$(HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  STATUS=$?
  return 0
}

run_test() {
  name=$1
  shift
  printf 'TEST %s\n' "$name"

  if setup_repo && "$@"; then
    passed=$((passed + 1))
    printf '  PASS\n'
  else
    failed=$((failed + 1))
    printf '  FAIL\n' >&2
  fi

  teardown_repo
}

test_default_symlink() {
  printf '.env\n' > "$REPO/.worktreeinclude"
  printf 'secret\n' > "$REPO/.env"

  run_plugin

  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_symlink "$WORKTREE/.env" || return 1
  assert_link_target "$WORKTREE/.env" "$REPO/.env"
}

test_combined_include_files() {
  printf 'include_file=.missing\ninclude_file=.not-a-file\ninclude_file=.first\ninclude_file=.second\n' > "$REPO/.herdr-worktree-include"
  mkdir "$REPO/.not-a-file"
  printf 'first.env\nshared.env\n' > "$REPO/.first"
  printf 'second.env\nshared.env\n' > "$REPO/.second"
  printf 'first\n' > "$REPO/first.env"
  printf 'second\n' > "$REPO/second.env"
  printf 'shared\n' > "$REPO/shared.env"

  run_plugin

  assert_symlink "$WORKTREE/first.env" || return 1
  assert_symlink "$WORKTREE/second.env" || return 1
  assert_symlink "$WORKTREE/shared.env" || return 1
  assert_output_contains "include path is not a readable file: $REPO/.not-a-file" || return 1
  assert_output_contains "symlink 3, skipped 0"
}

test_copy_files_directories_and_symlinks() {
  printf 'mode=copy\n' > "$REPO/.herdr-worktree-include"
  printf 'plain.txt\ncache\nsource-link\nbroken-link\n' > "$REPO/.worktreeinclude"
  printf 'plain\n' > "$REPO/plain.txt"
  mkdir "$REPO/cache"
  printf 'cached\n' > "$REPO/cache/value"
  ln -s plain.txt "$REPO/source-link"
  ln -s nowhere "$REPO/broken-link"

  run_plugin

  assert_file "$WORKTREE/plain.txt" || return 1
  assert_content "$WORKTREE/plain.txt" plain || return 1
  assert_directory "$WORKTREE/cache" || return 1
  assert_content "$WORKTREE/cache/value" cached || return 1
  assert_symlink "$WORKTREE/source-link" || return 1
  assert_link_target "$WORKTREE/source-link" plain.txt || return 1
  assert_symlink "$WORKTREE/broken-link" || return 1
  assert_link_target "$WORKTREE/broken-link" nowhere
}

test_comments_hashes_normalization_and_duplicates() {
  printf '  # comment\n./nested//value#local\nnested/value#local\n' > "$REPO/.worktreeinclude"
  mkdir "$REPO/nested"
  printf 'value\n' > "$REPO/nested/value#local"

  run_plugin

  assert_symlink "$WORKTREE/nested/value#local" || return 1
  assert_output_contains "symlink 1, skipped 0"
}

test_invalid_entries_are_skipped() {
  printf '../outside\n/absolute\n.git/config\nsafe.env\n' > "$REPO/.worktreeinclude"
  printf 'safe\n' > "$REPO/safe.env"

  run_plugin

  assert_symlink "$WORKTREE/safe.env" || return 1
  assert_output_contains "invalid path: ../outside" || return 1
  assert_output_contains "invalid path: /absolute" || return 1
  assert_output_contains "invalid path: .git/config"
}

test_malformed_config_skips_run() {
  printf 'mode=copy\nunknown=value\n' > "$REPO/.herdr-worktree-include"
  printf '.env\n' > "$REPO/.worktreeinclude"
  printf 'secret\n' > "$REPO/.env"

  run_plugin

  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_missing "$WORKTREE/.env" || return 1
  assert_output_contains "invalid configuration, skipping"
}

test_tracked_exact_conflict() {
  printf 'README\n.env\n' > "$REPO/.worktreeinclude"
  printf 'replacement\n' > "$REPO/README"
  printf 'safe\n' > "$REPO/.env"

  run_plugin

  assert_content "$WORKTREE/README" tracked || return 1
  assert_symlink "$WORKTREE/.env" || return 1
  assert_output_contains "tracked path conflict: README"
}

test_tracked_descendant_conflict() {
  mkdir "$REPO/config"
  printf 'tracked\n' > "$REPO/config/tracked"
  git -C "$REPO" add config/tracked
  git -C "$REPO" commit -qm "Track config child"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  printf 'config\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_file "$WORKTREE/config/tracked" || return 1
  assert_missing "$WORKTREE/config/untracked"
  assert_output_contains "tracked path conflict: config"
}

test_tracked_ancestor_conflict() {
  printf 'tracked-file/child\n' > "$REPO/.worktreeinclude"
  printf 'tracked\n' > "$REPO/tracked-file"
  git -C "$REPO" add tracked-file
  git -C "$REPO" commit -qm "Track parent file"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"

  run_plugin

  assert_file "$WORKTREE/tracked-file" || return 1
  assert_output_contains "tracked path conflict: tracked-file/child"
}

test_tracked_path_absent_from_disk() {
  printf 'sparse.env\n' > "$REPO/sparse.env"
  git -C "$REPO" add sparse.env
  git -C "$REPO" commit -qm "Track sparse path"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  rm "$WORKTREE/sparse.env"
  printf 'local replacement\n' > "$REPO/sparse.env"
  printf 'sparse.env\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/sparse.env" || return 1
  assert_output_contains "tracked path conflict: sparse.env"
}

test_existing_destination_is_preserved() {
  printf 'mode=copy\n' > "$REPO/.herdr-worktree-include"
  printf '.env\n' > "$REPO/.worktreeinclude"
  printf 'source\n' > "$REPO/.env"
  printf 'destination\n' > "$WORKTREE/.env"

  run_plugin

  assert_content "$WORKTREE/.env" destination || return 1
  assert_output_contains "destination exists"
}

test_unsafe_destination_parent_is_skipped() {
  printf 'nested/value\nsafe/value\n' > "$REPO/.worktreeinclude"
  mkdir -p "$REPO/nested" "$REPO/safe" "$TEST_ROOT/outside"
  printf 'nested\n' > "$REPO/nested/value"
  printf 'safe\n' > "$REPO/safe/value"
  ln -s "$TEST_ROOT/outside" "$WORKTREE/nested"
  printf 'not a directory\n' > "$WORKTREE/safe"

  run_plugin

  assert_missing "$TEST_ROOT/outside/value" || return 1
  assert_content "$WORKTREE/safe" "not a directory" || return 1
  assert_output_contains "destination has a symlink or non-directory parent"
}

test_source_symlinked_parent_is_allowed() {
  mkdir "$TEST_ROOT/external"
  printf 'external\n' > "$TEST_ROOT/external/value"
  ln -s "$TEST_ROOT/external" "$REPO/external"
  printf 'external/value\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_symlink "$WORKTREE/external/value" || return 1
  assert_link_target "$WORKTREE/external/value" "$REPO/external/value"
}

test_copy_failure_preserves_partial_destination() {
  mkdir -p "$TEST_ROOT/bin" "$REPO/cache"
  printf 'mode=copy\n' > "$REPO/.herdr-worktree-include"
  printf 'cache\n' > "$REPO/.worktreeinclude"
  printf 'cached\n' > "$REPO/cache/value"
  real_cp=$(command -v cp)
  # Write parameter expansion literally for the fake cp.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ndestination=${@: -1}\nmkdir -p "$destination"\nprintf partial > "$destination/partial"\nexit 1\n' > "$TEST_ROOT/bin/cp"
  chmod +x "$TEST_ROOT/bin/cp"

  OUTPUT=$(PATH="$TEST_ROOT/bin:$PATH" HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" bash "$PLUGIN" 2>&1)
  STATUS=$?

  [ -x "$real_cp" ] || fail "could not locate real cp"
  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_directory "$WORKTREE/cache" || return 1
  assert_content "$WORKTREE/cache/partial" partial || return 1
  assert_output_contains "partial destination may remain"
}

for dependency in git jq bash cp mktemp readlink; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'missing test dependency: %s\n' "$dependency" >&2
    exit 1
  fi
done

run_test "default symlink mode" test_default_symlink
run_test "combined include files" test_combined_include_files
run_test "copy preserves files, directories, and symlinks" test_copy_files_directories_and_symlinks
run_test "comments, hashes, normalization, and duplicates" test_comments_hashes_normalization_and_duplicates
run_test "invalid entries are skipped" test_invalid_entries_are_skipped
run_test "malformed config skips run" test_malformed_config_skips_run
run_test "tracked exact conflict" test_tracked_exact_conflict
run_test "tracked descendant conflict" test_tracked_descendant_conflict
run_test "tracked ancestor conflict" test_tracked_ancestor_conflict
run_test "tracked path absent from disk" test_tracked_path_absent_from_disk
run_test "existing destination is preserved" test_existing_destination_is_preserved
run_test "unsafe destination parents are skipped" test_unsafe_destination_parent_is_skipped
run_test "source symlinked parent is allowed" test_source_symlinked_parent_is_allowed
run_test "copy failure preserves partial destination" test_copy_failure_preserves_partial_destination

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
