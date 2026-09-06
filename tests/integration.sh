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
  printf '*\n' > "$REPO/.git/info/exclude"

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
  printf 'include_file=.missing\ninclude_file=.first\ninclude_file=.second\n' > "$REPO/.herdr-worktree-include"
  printf 'first.env\nshared.env\n' > "$REPO/.first"
  printf 'second.env\nshared.env\n' > "$REPO/.second"
  printf 'first\n' > "$REPO/first.env"
  printf 'second\n' > "$REPO/second.env"
  printf 'shared\n' > "$REPO/shared.env"

  run_plugin

  assert_symlink "$WORKTREE/first.env" || return 1
  assert_symlink "$WORKTREE/second.env" || return 1
  assert_symlink "$WORKTREE/shared.env" || return 1
  assert_output_contains "symlink 3, skipped 0"
}

test_include_files_use_last_match() {
  printf 'include_file=.first\ninclude_file=.second\n' > "$REPO/.herdr-worktree-include"
  printf '*.env\n' > "$REPO/.first"
  printf '!shared.env\nlocal.env\n' > "$REPO/.second"
  printf 'shared\n' > "$REPO/shared.env"
  printf 'local\n' > "$REPO/local.env"

  run_plugin

  assert_missing "$WORKTREE/shared.env" || return 1
  assert_symlink "$WORKTREE/local.env"
}

test_duplicate_include_declarations_are_significant() {
  printf 'include_file=.include\ninclude_file=.exclude\ninclude_file=.include\n' > "$REPO/.herdr-worktree-include"
  printf '*.env\n' > "$REPO/.include"
  printf '!*.env\n' > "$REPO/.exclude"
  printf 'secret\n' > "$REPO/local.env"

  run_plugin

  assert_symlink "$WORKTREE/local.env"
}

test_include_files_are_root_relative() {
  mkdir "$REPO/config" "$REPO/nested"
  printf 'include_file=config/include\n' > "$REPO/.herdr-worktree-include"
  printf '/root.env\n' > "$REPO/config/include"
  printf 'root\n' > "$REPO/root.env"
  printf 'nested\n' > "$REPO/nested/root.env"

  run_plugin

  assert_symlink "$WORKTREE/root.env" || return 1
  assert_missing "$WORKTREE/nested/root.env"
}

test_include_file_can_select_itself() {
  printf 'include_file=.worktreeinclude.local\n' > "$REPO/.herdr-worktree-include"
  printf '*\n' > "$REPO/.worktreeinclude.local"

  run_plugin

  assert_symlink "$WORKTREE/.worktreeinclude.local"
}

test_non_ignored_match_is_skipped() {
  printf '.env\n' > "$REPO/.worktreeinclude"
  printf 'secret\n' > "$REPO/.env"
  printf '!/.env\n' >> "$REPO/.git/info/exclude"

  run_plugin

  assert_missing "$WORKTREE/.env"
}

test_standard_gitignore_sources_are_used() {
  printf '' > "$REPO/.git/info/exclude"
  printf '*.env\n' > "$REPO/.worktreeinclude"
  printf '/root.env\n' > "$REPO/.gitignore"
  mkdir "$REPO/nested"
  printf '/local.env\n' > "$REPO/nested/.gitignore"
  printf 'root\n' > "$REPO/root.env"
  printf 'local\n' > "$REPO/nested/local.env"
  printf 'visible\n' > "$REPO/visible.env"

  run_plugin

  assert_symlink "$WORKTREE/root.env" || return 1
  assert_symlink "$WORKTREE/nested/local.env" || return 1
  assert_missing "$WORKTREE/visible.env"
}

test_global_gitignore_source_is_used() {
  printf '' > "$REPO/.git/info/exclude"
  printf '*.env\n' > "$REPO/.worktreeinclude"
  printf '/global.env\n' > "$TEST_ROOT/global-ignore"
  git -C "$REPO" config core.excludesFile "$TEST_ROOT/global-ignore"
  printf 'global\n' > "$REPO/global.env"
  printf 'visible\n' > "$REPO/visible.env"

  run_plugin

  assert_symlink "$WORKTREE/global.env" || return 1
  assert_missing "$WORKTREE/visible.env"
}

test_missing_include_is_optional_but_invalid_include_aborts() {
  printf 'include_file=.missing\ninclude_file=.not-a-file\ninclude_file=.valid\n' > "$REPO/.herdr-worktree-include"
  mkdir "$REPO/.not-a-file"
  printf '.env\n' > "$REPO/.valid"
  printf 'secret\n' > "$REPO/.env"

  run_plugin

  assert_missing "$WORKTREE/.env" || return 1
  assert_output_contains "include path is not a readable file: $REPO/.not-a-file"
}

test_selected_directory_is_installed_once() {
  printf 'cache/\n' > "$REPO/.worktreeinclude"
  mkdir -p "$REPO/cache/sub"
  printf 'one\n' > "$REPO/cache/one"
  printf 'two\n' > "$REPO/cache/sub/two"

  run_plugin

  assert_symlink "$WORKTREE/cache" || return 1
  assert_link_target "$WORKTREE/cache" "$REPO/cache" || return 1
  assert_output_contains "symlink 1, skipped 0"
}

test_overlapping_directories_install_shallowest_once() {
  printf 'cache/\ncache/sub/\n' > "$REPO/.worktreeinclude"
  mkdir -p "$REPO/cache/sub"
  printf 'nested\n' > "$REPO/cache/sub/value"

  run_plugin

  assert_symlink "$WORKTREE/cache" || return 1
  assert_link_target "$WORKTREE/cache" "$REPO/cache" || return 1
  assert_output_contains "symlink 1, skipped 0"
}

test_descendant_pattern_does_not_install_parent() {
  printf 'cache/*.json\n' > "$REPO/.worktreeinclude"
  mkdir "$REPO/cache"
  printf 'json\n' > "$REPO/cache/data.json"
  printf 'text\n' > "$REPO/cache/data.txt"

  run_plugin

  assert_directory "$WORKTREE/cache" || return 1
  [ ! -L "$WORKTREE/cache" ] || fail "expected a real destination parent: $WORKTREE/cache"
  assert_symlink "$WORKTREE/cache/data.json" || return 1
  assert_missing "$WORKTREE/cache/data.txt"
}

test_non_ignored_selected_directory_expands_to_ignored_children() {
  printf 'cache/\n' > "$REPO/.worktreeinclude"
  printf '!/cache/\n/cache/*\n!/cache/public.txt\n' > "$REPO/.git/info/exclude"
  mkdir "$REPO/cache"
  printf 'private\n' > "$REPO/cache/private.txt"
  printf 'public\n' > "$REPO/cache/public.txt"

  run_plugin

  assert_symlink "$WORKTREE/cache/private.txt" || return 1
  assert_missing "$WORKTREE/cache/public.txt" || return 1
  [ ! -L "$WORKTREE/cache" ] || fail "expected selected directory to be expanded"
}

test_nested_ignored_directory_is_installed_once() {
  printf '*/\n' > "$REPO/.worktreeinclude"
  printf '!/cache/\n/cache/sub/\n' > "$REPO/.git/info/exclude"
  mkdir -p "$REPO/cache/sub"
  printf 'nested\n' > "$REPO/cache/sub/value"

  run_plugin

  assert_directory "$WORKTREE/cache" || return 1
  [ ! -L "$WORKTREE/cache" ] || fail "expected a real destination parent: $WORKTREE/cache"
  assert_symlink "$WORKTREE/cache/sub" || return 1
  assert_link_target "$WORKTREE/cache/sub" "$REPO/cache/sub"
}

test_non_ignored_selected_directory_with_tracked_content_is_rejected() {
  mkdir "$REPO/cache"
  printf 'tracked\n' > "$REPO/cache/tracked"
  git -C "$REPO" add -f cache/tracked
  git -C "$REPO" commit -qm "Track cache child"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  printf '!/cache/\n/cache/local\n' > "$REPO/.git/info/exclude"
  printf 'local\n' > "$REPO/cache/local"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache/local" || return 1
  assert_output_contains "tracked path conflict: cache"
}

test_selected_directory_with_tracked_content_is_rejected() {
  mkdir "$REPO/cache"
  printf 'tracked\n' > "$REPO/cache/tracked"
  git -C "$REPO" add -f cache/tracked
  git -C "$REPO" commit -qm "Track cache child"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  printf 'local\n' > "$REPO/cache/local"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache/local" || return 1
  assert_output_contains "tracked path conflict: cache"
}

test_selected_directory_with_nested_repository_is_rejected() {
  mkdir -p "$REPO/cache/nested"
  git -C "$REPO/cache/nested" init -q
  printf 'nested\n' > "$REPO/cache/nested/value"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache" || return 1
  assert_output_contains "selected directory contains a nested Git repository: cache"
}

test_selected_nested_repository_is_rejected() {
  mkdir "$REPO/nested"
  git -C "$REPO/nested" init -q
  printf 'nested\n' > "$REPO/nested/value"
  printf 'nested/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/nested" || return 1
  assert_output_contains "selected directory contains a nested Git repository: nested"
}

test_newline_named_nested_repository_is_rejected() {
  local nested=$'nested\n'
  mkdir "$REPO/cache"
  git init -q "$REPO/cache/$nested"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache" || return 1
  assert_output_contains "selected directory contains a nested Git repository: cache"
}

test_selected_directory_with_bare_repository_is_rejected() {
  mkdir "$REPO/cache"
  git init --bare -q "$REPO/cache/nested.git"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache" || return 1
  assert_output_contains "selected directory contains a nested Git repository: cache"
}

test_selected_directory_with_special_file_is_rejected() {
  mkdir "$REPO/cache"
  mkfifo "$REPO/cache/pipe"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/cache" || return 1
  assert_output_contains "selected directory contains an unsupported source type: cache"
}

test_selected_symlink_is_retained_without_traversal() {
  mkdir "$TEST_ROOT/external"
  printf 'external\n' > "$TEST_ROOT/external/value"
  ln -s "$TEST_ROOT/external" "$REPO/external"
  printf 'external\nexternal/value\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_symlink "$WORKTREE/external" || return 1
  assert_link_target "$WORKTREE/external" "$REPO/external"
}

test_special_file_is_skipped() {
  printf 'pipe\n.env\n' > "$REPO/.worktreeinclude"
  mkfifo "$REPO/pipe"
  printf 'secret\n' > "$REPO/.env"

  run_plugin

  assert_missing "$WORKTREE/pipe" || return 1
  assert_symlink "$WORKTREE/.env" || return 1
  assert_output_contains "unsupported source type: $REPO/pipe"
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

test_gitignore_syntax() {
  printf '# comment\n*.env\n!example.env\n\\#local\n\\!important\n' > "$REPO/.worktreeinclude"
  printf 'secret\n' > "$REPO/app.env"
  printf 'example\n' > "$REPO/example.env"
  printf 'hash\n' > "$REPO/#local"
  printf 'important\n' > "$REPO/!important"

  run_plugin

  assert_symlink "$WORKTREE/app.env" || return 1
  assert_missing "$WORKTREE/example.env" || return 1
  assert_symlink "$WORKTREE/#local" || return 1
  assert_symlink "$WORKTREE/!important" || return 1
  assert_output_contains "symlink 3, skipped 0"
}

test_root_anchoring_and_globs() {
  printf '/root.env\n**/nested.env\n' > "$REPO/.worktreeinclude"
  mkdir "$REPO/deep"
  printf 'root\n' > "$REPO/root.env"
  printf 'other\n' > "$REPO/deep/root.env"
  printf 'nested\n' > "$REPO/deep/nested.env"

  run_plugin

  assert_symlink "$WORKTREE/root.env" || return 1
  assert_missing "$WORKTREE/deep/root.env" || return 1
  assert_symlink "$WORKTREE/deep/nested.env"
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
  assert_output_contains "symlink 1, skipped 0"
}

test_tracked_descendant_conflict() {
  mkdir "$REPO/config"
  printf 'tracked\n' > "$REPO/config/tracked"
  git -C "$REPO" add -f config/tracked
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
  git -C "$REPO" add -f tracked-file
  git -C "$REPO" commit -qm "Track parent file"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"

  run_plugin

  assert_file "$WORKTREE/tracked-file" || return 1
  assert_missing "$WORKTREE/tracked-file/child"
}

test_tracked_directory_is_not_an_ancestor_conflict() {
  mkdir -p "$REPO/src/django"
  printf 'tracked\n' > "$REPO/src/django/tracked"
  git -C "$REPO" add -f src/django/tracked
  git -C "$REPO" commit -qm "Track sibling file"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  printf 'secret\n' > "$REPO/src/django/.env"
  printf 'src/django/.env\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_symlink "$WORKTREE/src/django/.env" || return 1
  assert_link_target "$WORKTREE/src/django/.env" "$REPO/src/django/.env"
}

test_source_only_tracked_ancestor_conflict() {
  printf 'tracked\n' > "$REPO/source-parent"
  git -C "$REPO" add -f source-parent
  git -C "$REPO" commit -qm "Track source parent"
  rm "$REPO/source-parent"
  mkdir "$REPO/source-parent"
  printf 'local\n' > "$REPO/source-parent/child.env"
  printf 'source-parent/child.env\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/source-parent/child.env" || return 1
  assert_output_contains "tracked path conflict: source-parent/child.env"
}

test_case_insensitive_tracked_conflict() {
  git -C "$REPO" config core.ignoreCase true
  git -C "$WORKTREE" config core.ignoreCase true
  mkdir "$REPO/Cache"
  printf 'tracked\n' > "$REPO/Cache/tracked"
  git -C "$REPO" add -f Cache/tracked
  git -C "$REPO" commit -qm "Track case-sensitive cache child"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  rm "$REPO/Cache/tracked"
  printf 'local\n' > "$REPO/Cache/local"
  printf 'cache/\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/Cache/local" || return 1
  assert_output_contains "tracked path conflict: Cache"
}

test_source_tracked_conflict_is_rechecked_before_install() {
  printf 'race.env\n' > "$REPO/.worktreeinclude"
  printf 'local\n' > "$REPO/race.env"
  mkdir "$TEST_ROOT/bin"
  real_git=$(command -v git)
  # Track the selected source path after selection and before installation.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n"$REAL_GIT" "$@"\nstatus=$?\ncase " $* " in\n  *" check-ignore "*) "$REAL_GIT" -C "$REPO" add -f race.env ;;\nesac\nexit "$status"\n' > "$TEST_ROOT/bin/git"
  chmod +x "$TEST_ROOT/bin/git"

  OUTPUT=$(REPO="$REPO" REAL_GIT="$real_git" PATH="$TEST_ROOT/bin:$PATH" \
    HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" bash "$PLUGIN" 2>&1)
  STATUS=$?

  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_missing "$WORKTREE/race.env" || return 1
  assert_output_contains "tracked path conflict: race.env"
}

test_tracked_path_absent_from_disk() {
  printf 'sparse.env\n' > "$REPO/sparse.env"
  git -C "$REPO" add -f sparse.env
  git -C "$REPO" commit -qm "Track sparse path"
  git -C "$WORKTREE" reset -q --hard "$DEFAULT_BRANCH"
  rm "$WORKTREE/sparse.env"
  printf 'local replacement\n' > "$REPO/sparse.env"
  printf 'sparse.env\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/sparse.env"
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

test_source_symlinked_parent_is_not_traversed() {
  mkdir "$TEST_ROOT/external"
  printf 'external\n' > "$TEST_ROOT/external/value"
  ln -s "$TEST_ROOT/external" "$REPO/external"
  printf 'external/value\n' > "$REPO/.worktreeinclude"

  run_plugin

  assert_missing "$WORKTREE/external/value"
}

test_copy_failure_preserves_partial_destination() {
  mkdir -p "$TEST_ROOT/bin" "$REPO/cache"
  printf 'mode=copy\n' > "$REPO/.herdr-worktree-include"
  printf 'cache\n' > "$REPO/.worktreeinclude"
  printf 'cached\n' > "$REPO/cache/value"
  real_cp=$(command -v cp)
  # Delegate to the real cp except for the -RP call install_entry makes, so
  # the plugin's own include-file snapshot copy still succeeds.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "$1" = -RP ] || exec "$REAL_CP" "$@"\ndestination=${@: -1}\nmkdir -p "$destination"\nprintf partial > "$destination/partial"\nexit 1\n' > "$TEST_ROOT/bin/cp"
  chmod +x "$TEST_ROOT/bin/cp"

  OUTPUT=$(REAL_CP="$real_cp" PATH="$TEST_ROOT/bin:$PATH" HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" bash "$PLUGIN" 2>&1)
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
run_test "include files use last match" test_include_files_use_last_match
run_test "duplicate include declarations are significant" test_duplicate_include_declarations_are_significant
run_test "include files are root relative" test_include_files_are_root_relative
run_test "include file can select itself" test_include_file_can_select_itself
run_test "non-ignored matches are skipped" test_non_ignored_match_is_skipped
run_test "standard gitignore sources are used" test_standard_gitignore_sources_are_used
run_test "global gitignore source is used" test_global_gitignore_source_is_used
run_test "invalid include files abort selection" test_missing_include_is_optional_but_invalid_include_aborts
run_test "selected directories are installed once" test_selected_directory_is_installed_once
run_test "overlapping directories install shallowest once" test_overlapping_directories_install_shallowest_once
run_test "descendant patterns do not install parents" test_descendant_pattern_does_not_install_parent
run_test "non-ignored selected directories expand" test_non_ignored_selected_directory_expands_to_ignored_children
run_test "nested ignored directories are installed once" test_nested_ignored_directory_is_installed_once
run_test "non-ignored selected directories reject tracked content" test_non_ignored_selected_directory_with_tracked_content_is_rejected
run_test "selected directories reject tracked content" test_selected_directory_with_tracked_content_is_rejected
run_test "selected directories reject nested repositories" test_selected_directory_with_nested_repository_is_rejected
run_test "selected nested repositories are rejected" test_selected_nested_repository_is_rejected
run_test "newline-named nested repositories are rejected" test_newline_named_nested_repository_is_rejected
run_test "selected directories reject bare repositories" test_selected_directory_with_bare_repository_is_rejected
run_test "selected directories reject special files" test_selected_directory_with_special_file_is_rejected
run_test "selected symlinks are retained" test_selected_symlink_is_retained_without_traversal
run_test "special files are skipped" test_special_file_is_skipped
run_test "copy preserves files, directories, and symlinks" test_copy_files_directories_and_symlinks
run_test "gitignore comments, negation, and escapes" test_gitignore_syntax
run_test "root anchoring and globs" test_root_anchoring_and_globs
run_test "malformed config skips run" test_malformed_config_skips_run
run_test "tracked exact conflict" test_tracked_exact_conflict
run_test "tracked descendant conflict" test_tracked_descendant_conflict
run_test "tracked ancestor conflict" test_tracked_ancestor_conflict
run_test "tracked directories are not ancestor conflicts" test_tracked_directory_is_not_an_ancestor_conflict
run_test "source-only tracked ancestor conflict" test_source_only_tracked_ancestor_conflict
run_test "case-insensitive tracked conflict" test_case_insensitive_tracked_conflict
run_test "source tracked conflicts are rechecked before install" test_source_tracked_conflict_is_rechecked_before_install
run_test "tracked path absent from disk" test_tracked_path_absent_from_disk
run_test "existing destination is preserved" test_existing_destination_is_preserved
run_test "unsafe destination parents are skipped" test_unsafe_destination_parent_is_skipped
run_test "source symlinked parent is not traversed" test_source_symlinked_parent_is_not_traversed
run_test "copy failure preserves partial destination" test_copy_failure_preserves_partial_destination

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
