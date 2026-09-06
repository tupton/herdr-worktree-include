#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$ROOT/src/include.sh
# Herdr invokes the plugin as `bash src/include.sh`, so PATH lookup is the
# default. CI overrides this to pin an explicit interpreter.
PLUGIN_BASH=${PLUGIN_BASH:-bash}
TEST_ROOT=
DIAGNOSTICS_FILE=
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

assert_diagnostic() {
  local expression=$1 expected=$2 actual
  actual=$(jq -r "$expression" "$DIAGNOSTICS_FILE") || return 1
  [ "$actual" = "$expected" ] || fail "expected diagnostic $expression to be '$expected', got '$actual'"
}

installed_entries() {
  (cd "$WORKTREE" && find . -type l -print0)
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
  DIAGNOSTICS_FILE=
  FORCE_WHOLE_TREE=0
}

run_plugin() {
  if [ -n "$DIAGNOSTICS_FILE" ]; then
    OUTPUT=$(HERDR_WORKTREE_INCLUDE_FORCE_WHOLE_TREE="${FORCE_WHOLE_TREE:-0}" \
      HERDR_WORKTREE_INCLUDE_DIAGNOSTICS="$DIAGNOSTICS_FILE" \
      HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  else
    OUTPUT=$(HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  fi
  STATUS=$?
  return 0
}

run_test() {
  name=$1
  shift

  if [ -n "${TEST_FILTER:-}" ] && [[ $name != *"$TEST_FILTER"* ]]; then
    return 0
  fi

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

test_rooted_literal_uses_literal_plan() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src/django"
  printf 'secret\n' > "$REPO/src/django/.env"
  printf 'src/django/.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/django/.env" || return 1
  assert_diagnostic '.plan.tier' rooted-literal || return 1
  assert_diagnostic '.plan.roots | join(",")' src/django/.env || return 1
  assert_diagnostic '.commands.discovery_directories' 0 || return 1
  assert_diagnostic '.commands.direct_directory_probes' 0 || return 1
  assert_diagnostic '.commands.special_find' 0
}

test_rooted_prefix_scopes_discovery() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src/app" "$REPO/unrelated/deep"
  printf 'root\n' > "$REPO/src/root.env"
  printf 'nested\n' > "$REPO/src/app/nested.env"
  printf 'outside\n' > "$REPO/unrelated/deep/outside.env"
  printf 'src/**/*.env\nsrc/*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/root.env" || return 1
  assert_symlink "$WORKTREE/src/app/nested.env" || return 1
  assert_missing "$WORKTREE/unrelated/deep/outside.env" || return 1
  assert_diagnostic '.plan.tier' rooted-prefix || return 1
  assert_diagnostic '.plan.roots | join(",")' src || return 1
  assert_diagnostic '.commands.discovery_directories' 1
}

test_slashless_pattern_uses_whole_tree_plan() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/nested"
  printf 'root\n' > "$REPO/root.env"
  printf 'nested\n' > "$REPO/nested/local.env"
  printf '*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/root.env" || return 1
  assert_symlink "$WORKTREE/nested/local.env" || return 1
  assert_diagnostic '.plan.tier' whole-tree || return 1
  assert_diagnostic '.plan.roots | length' 0 || return 1
  assert_diagnostic '.commands.discovery_directories' 1 || return 1
  assert_diagnostic '.commands.special_find' 1
}

test_negation_does_not_broaden_literal_plan() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'secret\n' > "$REPO/src/local.env"
  printf 'example\n' > "$REPO/src/example.env"
  printf 'src/local.env\n!**/example.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/local.env" || return 1
  assert_missing "$WORKTREE/src/example.env" || return 1
  assert_diagnostic '.plan.tier' rooted-literal || return 1
  assert_diagnostic '.plan.roots | join(",")' src/local.env
}

test_many_entries_use_batched_safety_checks() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/config"
  for number in 1 2 3 4 5; do
    printf 'value %s\n' "$number" > "$REPO/config/$number.env"
    printf 'config/%s.env\n' "$number" >> "$REPO/.worktreeinclude"
  done
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  for number in 1 2 3 4 5; do
    assert_symlink "$WORKTREE/config/$number.env" || return 1
  done
  assert_diagnostic '.commands.standard_ignores' 1 || return 1
  assert_diagnostic '.commands.source_index_snapshots' 2 || return 1
  assert_diagnostic '.commands.destination_index_snapshots' 2
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
  # Track the selected source path after the initial source snapshot has been
  # emitted, so only the fresh pre-install snapshot can observe the change.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n"$REAL_GIT" "$@"\nstatus=$?\nif [ "$#" -eq 4 ] && [ "$1" = -C ] && [ "$2" = "$REPO" ] && [ "$3" = ls-files ] && [ "$4" = -z ] && [ ! -e "$STATE" ]; then\n  : > "$STATE"\n  "$REAL_GIT" -C "$REPO" add -f race.env\nfi\nexit "$status"\n' > "$TEST_ROOT/bin/git"
  chmod +x "$TEST_ROOT/bin/git"

  OUTPUT=$(REPO="$REPO" STATE="$TEST_ROOT/source-snapshot-seen" REAL_GIT="$real_git" \
    PATH="$TEST_ROOT/bin:$PATH" HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" \
    "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  STATUS=$?

  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_missing "$WORKTREE/race.env" || return 1
  assert_output_contains "tracked path conflict: race.env"
}

test_destination_tracked_conflict_is_rechecked_before_install() {
  printf 'race.env\n' > "$REPO/.worktreeinclude"
  printf 'local\n' > "$REPO/race.env"
  mkdir "$TEST_ROOT/bin"
  real_git=$(command -v git)
  blob=$(printf 'destination race\n' | git -C "$WORKTREE" hash-object -w --stdin)
  # Add an index-only destination entry after the initial destination snapshot.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n"$REAL_GIT" "$@"\nstatus=$?\nif [ "$#" -eq 4 ] && [ "$1" = -C ] && [ "$2" = "$WORKTREE" ] && [ "$3" = ls-files ] && [ "$4" = -z ] && [ ! -e "$STATE" ]; then\n  : > "$STATE"\n  "$REAL_GIT" -C "$WORKTREE" update-index --add --cacheinfo "100644,$BLOB,race.env"\nfi\nexit "$status"\n' > "$TEST_ROOT/bin/git"
  chmod +x "$TEST_ROOT/bin/git"

  OUTPUT=$(WORKTREE="$WORKTREE" BLOB="$blob" STATE="$TEST_ROOT/destination-snapshot-seen" \
    REAL_GIT="$real_git" PATH="$TEST_ROOT/bin:$PATH" HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" \
    "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  STATUS=$?

  [ "$STATUS" -eq 0 ] || fail "plugin exited $STATUS"
  assert_missing "$WORKTREE/race.env" || return 1
  assert_output_contains "tracked path conflict: race.env"
}

test_ordinary_directory_tree_needs_no_repository_validation() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/cache/one/two/three"
  printf 'value\n' > "$REPO/cache/one/two/three/value"
  printf '/cache/\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/cache" || return 1
  assert_diagnostic '.commands.repository_validations' 0
}

test_invalid_git_marker_is_not_a_repository() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/cache"
  printf 'not a gitfile\n' > "$REPO/cache/.git"
  printf 'value\n' > "$REPO/cache/value"
  printf '/cache/\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/cache" || return 1
  assert_diagnostic '.commands.repository_validations' 1
}

test_rooted_literal_special_file_avoids_recursive_find() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/runtime"
  mkfifo "$REPO/runtime/pipe"
  printf '/runtime/pipe\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_missing "$WORKTREE/runtime/pipe" || return 1
  assert_output_contains "unsupported source type: $REPO/runtime/pipe" || return 1
  assert_diagnostic '.plan.tier' rooted-literal || return 1
  assert_diagnostic '.commands.special_find' 0 || return 1
  assert_diagnostic '.commands.special_match' 1
}

test_rooted_prefix_does_not_inspect_unrelated_special_file() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/runtime" "$REPO/unrelated"
  printf 'secret\n' > "$REPO/runtime/local.env"
  mkfifo "$REPO/unrelated/pipe"
  printf '/runtime/*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/runtime/local.env" || return 1
  [[ $OUTPUT != *"unrelated/pipe"* ]] || fail "unexpected warning for unrelated special file" || return 1
  assert_diagnostic '.commands.special_find' 1 || return 1
  assert_diagnostic '.commands.special_match' 0
}

test_mixed_prefix_plan_warns_for_literal_special_file() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/runtime" "$REPO/outside"
  printf 'secret\n' > "$REPO/runtime/local.env"
  mkfifo "$REPO/outside/pipe"
  printf '/runtime/*.env\n/outside/pipe\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/runtime/local.env" || return 1
  assert_missing "$WORKTREE/outside/pipe" || return 1
  assert_output_contains "unsupported source type: $REPO/outside/pipe" || return 1
  assert_diagnostic '.plan.tier' rooted-prefix
}

test_uncertain_patterns_fall_back() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'value\n' > "$REPO/src/a.env"
  printf '/src/[a\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_diagnostic '.plan.tier' whole-tree
}

test_case_insensitive_selection_falls_back() {
  git -C "$REPO" config core.ignoreCase true
  mkdir -p "$REPO/Source"
  printf 'value\n' > "$REPO/Source/local.env"
  printf '/source/local.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_diagnostic '.plan.tier' whole-tree
}

test_nested_git_component_falls_back() {
  git -C "$REPO" config core.ignoreCase false
  printf '/cache/.git/config\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_diagnostic '.plan.tier' whole-tree
}

test_forced_fallback_matches_rooted_prefix_result() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src/nested"
  printf 'root\n' > "$REPO/src/root.env"
  printf 'nested\n' > "$REPO/src/nested/local.env"
  printf 'skip\n' > "$REPO/src/nested/local.txt"
  printf '/src/**/*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/planned.json

  run_plugin

  assert_symlink "$WORKTREE/src/root.env" || return 1
  assert_symlink "$WORKTREE/src/nested/local.env" || return 1
  installed_entries > "$TEST_ROOT/planned-entries"
  planned_output=$OUTPUT
  rm "$WORKTREE/src/root.env" "$WORKTREE/src/nested/local.env"
  rmdir "$WORKTREE/src/nested" "$WORKTREE/src"
  FORCE_WHOLE_TREE=1
  DIAGNOSTICS_FILE=$TEST_ROOT/fallback.json

  run_plugin

  assert_symlink "$WORKTREE/src/root.env" || return 1
  assert_symlink "$WORKTREE/src/nested/local.env" || return 1
  installed_entries > "$TEST_ROOT/fallback-entries"
  cmp "$TEST_ROOT/planned-entries" "$TEST_ROOT/fallback-entries" || \
    fail "planned and fallback installed different entries" || return 1
  [ "$OUTPUT" = "$planned_output" ] || fail "planned and fallback warnings differed" || return 1
  actual=$(jq -r '.plan.tier' "$DIAGNOSTICS_FILE") || return 1
  [ "$actual" = whole-tree ] || fail "expected forced whole-tree plan, got $actual"
}

test_only_negations_skip_discovery() {
  git -C "$REPO" config core.ignoreCase false
  printf 'secret\n' > "$REPO/local.env"
  printf '!*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_missing "$WORKTREE/local.env" || return 1
  assert_diagnostic '.plan.tier' rooted-literal || return 1
  assert_diagnostic '.commands.discovery_leaves' 0 || return 1
  assert_diagnostic '.commands.discovery_directories' 0
}

test_escaped_literal_metacharacter_uses_literal_plan() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'literal\n' > "$REPO/src/*.env"
  printf '/src/\\*.env\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/*.env" || return 1
  assert_diagnostic '.plan.tier' rooted-literal || return 1
  assert_diagnostic '.plan.roots | join(",")' 'src/*.env'
}

test_escaped_leading_markers_use_literal_plan() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'hash\n' > "$REPO/src/#local"
  printf 'bang\n' > "$REPO/src/!important"
  printf '/src/\\#local\n/src/\\!important\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/#local" || return 1
  assert_symlink "$WORKTREE/src/!important" || return 1
  assert_diagnostic '.plan.tier' rooted-literal
}

test_trailing_space_and_malformed_escape_fall_back() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'value\n' > "$REPO/src/value"
  printf '/src/value   \n/src/other\\\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/value" || return 1
  assert_diagnostic '.plan.tier' whole-tree
}

test_crlf_include_file_falls_back_without_changing_match() {
  git -C "$REPO" config core.ignoreCase false
  mkdir -p "$REPO/src"
  printf 'value\n' > "$REPO/src/value"
  printf '/src/value\r\n' > "$REPO/.worktreeinclude"
  DIAGNOSTICS_FILE=$TEST_ROOT/diagnostics.json

  run_plugin

  assert_symlink "$WORKTREE/src/value" || return 1
  assert_diagnostic '.plan.tier' whole-tree
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

for dependency in git jq bash cp mktemp readlink mkfifo; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'missing test dependency: %s\n' "$dependency" >&2
    exit 1
  fi
done

run_test "default symlink mode" test_default_symlink
run_test "rooted literal uses literal plan" test_rooted_literal_uses_literal_plan
run_test "rooted prefix scopes discovery" test_rooted_prefix_scopes_discovery
run_test "slashless pattern uses whole tree plan" test_slashless_pattern_uses_whole_tree_plan
run_test "negation does not broaden literal plan" test_negation_does_not_broaden_literal_plan
run_test "many entries use batched safety checks" test_many_entries_use_batched_safety_checks
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
run_test "destination tracked conflicts are rechecked before install" test_destination_tracked_conflict_is_rechecked_before_install
run_test "ordinary directory trees need no repository validation" test_ordinary_directory_tree_needs_no_repository_validation
run_test "invalid git markers are not repositories" test_invalid_git_marker_is_not_a_repository
run_test "rooted literal special files avoid recursive find" test_rooted_literal_special_file_avoids_recursive_find
run_test "rooted prefix does not inspect unrelated special files" test_rooted_prefix_does_not_inspect_unrelated_special_file
run_test "mixed prefix plans warn for literal special files" test_mixed_prefix_plan_warns_for_literal_special_file
run_test "uncertain patterns fall back" test_uncertain_patterns_fall_back
run_test "case insensitive selection falls back" test_case_insensitive_selection_falls_back
run_test "nested git components fall back" test_nested_git_component_falls_back
run_test "forced fallback matches rooted prefix result" test_forced_fallback_matches_rooted_prefix_result
run_test "only negations skip discovery" test_only_negations_skip_discovery
run_test "escaped literal metacharacters use literal plan" test_escaped_literal_metacharacter_uses_literal_plan
run_test "escaped leading markers use literal plan" test_escaped_leading_markers_use_literal_plan
run_test "trailing spaces and malformed escapes fall back" test_trailing_space_and_malformed_escape_fall_back
run_test "CRLF include files fall back without changing matches" test_crlf_include_file_falls_back_without_changing_match
run_test "tracked path absent from disk" test_tracked_path_absent_from_disk
run_test "existing destination is preserved" test_existing_destination_is_preserved
run_test "unsafe destination parents are skipped" test_unsafe_destination_parent_is_skipped
run_test "source symlinked parent is not traversed" test_source_symlinked_parent_is_not_traversed
run_test "copy failure preserves partial destination" test_copy_failure_preserves_partial_destination

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
