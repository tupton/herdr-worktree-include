#!/usr/bin/env bash

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PLUGIN=$ROOT/src/include.sh
PLUGIN_BASH=${PLUGIN_BASH:-bash}
TEST_ROOT=
passed=0
failed=0
declare -a ELIGIBLE_ENTRIES=()

# shellcheck source=../src/include.sh
# shellcheck disable=SC1091 # ShellCheck does not resolve the computed root.
source "$PLUGIN"

cleanup() {
  [[ -z $TEST_ROOT ]] || rm -rf "$TEST_ROOT"
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
  [[ -f $1 && ! -L $1 ]] || fail "expected regular file: $1"
}

assert_directory() {
  [[ -d $1 && ! -L $1 ]] || fail "expected directory: $1"
}

assert_symlink() {
  [[ -L $1 ]] || fail "expected symlink: $1; output: $OUTPUT"
}

assert_missing() {
  if [[ -e $1 || -L $1 ]]; then
    fail "expected missing path: $1"
  fi
}

assert_selected() {
  local expected=$1 entry
  for entry in "${ELIGIBLE_ENTRIES[@]}"; do
    [[ $entry != "$expected" ]] || return 0
  done
  fail "expected Eligible leaf entry: $expected"
}

assert_not_selected() {
  local unexpected=$1 entry
  for entry in "${ELIGIBLE_ENTRIES[@]}"; do
    [[ $entry != "$unexpected" ]] || fail "unexpected Eligible leaf entry: $unexpected"
  done
}

assert_content() {
  local actual
  actual=$(<"$1")
  [[ $actual == "$2" ]] || fail "expected '$2' in $1, got '$actual'"
}

assert_link_target() {
  local actual
  actual=$(readlink "$1")
  [[ $actual == "$2" ]] || fail "expected $1 to target $2, got $actual"
}

assert_output_contains() {
  [[ $OUTPUT == *"$1"* ]] || fail "expected output to contain: $1"
}

assert_output_excludes() {
  [[ $OUTPUT != *"$1"* ]] || fail "expected output not to contain: $1"
}

setup_repo() {
  TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worktree-include-test.XXXXXX") || return 1
  REPO=$TEST_ROOT/repo
  WORKTREE=$TEST_ROOT/worktree

  mkdir "$REPO" || return 1
  git -C "$REPO" init -q || return 1
  git -C "$REPO" config user.email test@example.com || return 1
  git -C "$REPO" config user.name "Worktree Include Tests" || return 1
  printf 'tracked\n' >"$REPO/README"
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

run_selection() {
  local diagnostics=$TEST_ROOT/selection.stderr
  ELIGIBLE_ENTRIES=()
  if _worktree_include_select_eligible_leaf_entries \
    "$REPO" "$WORKTREE" ELIGIBLE_ENTRIES 2>"$diagnostics"; then
    STATUS=0
  else
    STATUS=$?
  fi
  OUTPUT=$(<"$diagnostics")
  [[ $STATUS -eq 0 ]] || fail "selection exited $STATUS: $OUTPUT"
}

run_test() {
  local name=$1
  shift

  if [[ -n ${TEST_FILTER:-} && $name != *"$TEST_FILTER"* ]]; then
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

ignore_locally() {
  printf '%s\n' "$1" >>"$REPO/.git/info/exclude"
}

add_index_entry() {
  local repository=$1 path=$2 blob
  blob=$(printf 'index-only\n' | git -C "$repository" hash-object -w --stdin) || return 1
  git -C "$repository" update-index --add --cacheinfo 100644 "$blob" "$path"
}

test_nested_leaf_with_tracked_siblings() {
  mkdir -p "$REPO/src/django"
  printf 'tracked\n' >"$REPO/src/django/models.py"
  git -C "$REPO" add src/django/models.py
  git -C "$REPO" commit -qm "Add application"
  printf 'secret\n' >"$REPO/src/django/.env"
  printf 'src/django/.env\n' >"$REPO/.worktreeinclude"
  ignore_locally 'src/django/.env'

  run_plugin

  [[ $STATUS -eq 0 ]] || fail "plugin exited $STATUS"
  assert_symlink "$WORKTREE/src/django/.env" || return 1
  assert_link_target "$WORKTREE/src/django/.env" "$REPO/src/django/.env" || return 1
  assert_output_contains "symlink 1, skipped 0"
}

test_copy_mode_copies_files_and_preserves_symlinks() {
  printf 'mode=copy\n' >"$REPO/.herdr-worktree-include"
  printf 'plain.env\nsource-link\nbroken-link\n' >"$REPO/.worktreeinclude"
  printf 'plain\n' >"$REPO/plain.env"
  ln -s plain.env "$REPO/source-link"
  ln -s nowhere "$REPO/broken-link"
  ignore_locally 'plain.env'
  ignore_locally 'source-link'
  ignore_locally 'broken-link'

  run_plugin

  assert_file "$WORKTREE/plain.env" || return 1
  assert_content "$WORKTREE/plain.env" plain || return 1
  assert_symlink "$WORKTREE/source-link" || return 1
  assert_link_target "$WORKTREE/source-link" plain.env || return 1
  assert_symlink "$WORKTREE/broken-link" || return 1
  assert_link_target "$WORKTREE/broken-link" nowhere || return 1
  assert_output_contains "copy 3, skipped 0"
}

test_copy_failure_preserves_partial_destination() {
  local real_cp
  real_cp=$(command -v cp) || return 1
  mkdir "$TEST_ROOT/bin"
  printf 'mode=copy\n' >"$REPO/.herdr-worktree-include"
  printf 'local.env\n' >"$REPO/.worktreeinclude"
  printf 'source\n' >"$REPO/local.env"
  ignore_locally 'local.env'
  # Simulate cp writing part of the destination before failing.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nif [[ $1 == -P ]]; then\n  destination=${@: -1}\n  printf partial >"$destination"\n  exit 1\nfi\nexec "$REAL_CP" "$@"\n' >"$TEST_ROOT/bin/cp"
  chmod +x "$TEST_ROOT/bin/cp"

  OUTPUT=$(REAL_CP="$real_cp" PATH="$TEST_ROOT/bin:$PATH" \
    HERDR_PLUGIN_EVENT_JSON="$EVENT_JSON" "$PLUGIN_BASH" "$PLUGIN" 2>&1)
  STATUS=$?

  [[ $STATUS -eq 0 ]] || fail "plugin exited $STATUS"
  assert_file "$WORKTREE/local.env" || return 1
  assert_content "$WORKTREE/local.env" partial || return 1
  assert_output_contains "copy failed: partial destination may remain" || return 1
  assert_output_contains "copy 0, skipped 1"
}

test_leading_slash_and_duplicate_declarations() {
  printf '/.env\n.env\n' >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally '.env'

  run_selection || return 1

  [[ ${#ELIGIBLE_ENTRIES[@]} -eq 1 ]] || fail "expected one Eligible leaf entry"
  assert_selected ".env"
}

test_shared_file_ignores_unsupported_gitignore_patterns() {
  printf '# shared with Claude Code\n.env.*\n!example.env\ncache/\nfoo\\ bar\n.env\n' \
    >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  printf 'local\n' >"$REPO/.env.local"
  ignore_locally '.env'
  ignore_locally '.env.local'

  run_selection || return 1

  assert_selected ".env" || return 1
  assert_not_selected ".env.local" || return 1
  assert_output_contains ".worktreeinclude:2: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:3: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:4: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:5: unsupported pattern, ignoring"
}

test_invalid_literal_paths_are_ignored() {
  printf '../outside\nconfig//local.env\n.git/config\n trailing.env\nvalid.env\n' \
    >"$REPO/.worktreeinclude"
  printf 'valid\n' >"$REPO/valid.env"
  ignore_locally 'valid.env'

  run_selection || return 1

  assert_selected "valid.env" || return 1
  assert_output_contains ".worktreeinclude:1: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:2: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:3: unsupported pattern, ignoring" || return 1
  assert_output_contains ".worktreeinclude:4: unsupported pattern, ignoring"
}

test_missing_tracked_and_nonignored_declarations_are_quietly_omitted() {
  printf 'missing.env\nREADME\nvisible.env\n' >"$REPO/.worktreeinclude"
  printf 'visible\n' >"$REPO/visible.env"

  run_selection || return 1

  [[ ${#ELIGIBLE_ENTRIES[@]} -eq 0 ]] || fail "expected no Eligible leaf entries"
  [[ $OUTPUT == '' ]] || fail "expected no output, got: $OUTPUT"
}

test_standard_git_ignore_sources_are_used() {
  mkdir -p "$REPO/config" "$REPO/nested"
  printf 'root.env\n' >"$REPO/.gitignore"
  printf 'nested.env\n' >"$REPO/nested/.gitignore"
  git -C "$REPO" add .gitignore nested/.gitignore
  git -C "$REPO" commit -qm "Add ignore rules"
  printf 'root\n' >"$REPO/root.env"
  printf 'nested\n' >"$REPO/nested/nested.env"
  printf 'local\n' >"$REPO/config/local.env"
  ignore_locally 'config/local.env'
  printf 'root.env\nnested/nested.env\nconfig/local.env\n' >"$REPO/.worktreeinclude"

  run_selection || return 1

  assert_selected "root.env" || return 1
  assert_selected "nested/nested.env" || return 1
  assert_selected "config/local.env"
}

test_global_git_excludes_are_used() {
  printf 'global.env\n' >"$TEST_ROOT/global-ignore"
  git -C "$REPO" config core.excludesFile "$TEST_ROOT/global-ignore"
  printf 'global\n' >"$REPO/global.env"
  printf 'global.env\n' >"$REPO/.worktreeinclude"

  run_selection || return 1

  assert_selected "global.env"
}

test_directories_and_special_files_are_warned_and_skipped() {
  mkdir "$REPO/cache"
  mkfifo "$REPO/runtime.pipe"
  printf 'cache\nruntime.pipe\n.env\n' >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally 'cache/'
  ignore_locally 'runtime.pipe'
  ignore_locally '.env'

  run_selection || return 1

  assert_not_selected "cache" || return 1
  assert_not_selected "runtime.pipe" || return 1
  assert_selected ".env" || return 1
  assert_output_contains "not a regular file or symlink: cache" || return 1
  assert_output_contains "not a regular file or symlink: runtime.pipe"
}

test_source_symlinked_parent_is_rejected() {
  mkdir "$TEST_ROOT/outside"
  printf 'outside\n' >"$TEST_ROOT/outside/local.env"
  ln -s "$TEST_ROOT/outside" "$REPO/config"
  printf 'config/local.env\n.env\n' >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally 'config/local.env'
  ignore_locally '.env'

  run_selection || return 1

  assert_not_selected "config/local.env" || return 1
  assert_selected ".env" || return 1
  assert_output_contains "source has a symlink or non-directory parent: config/local.env"
}

test_leaf_symlink_to_directory_is_allowed() {
  mkdir "$TEST_ROOT/outside"
  printf 'outside\n' >"$TEST_ROOT/outside/value"
  ln -s "$TEST_ROOT/outside" "$REPO/external"
  printf 'external\n' >"$REPO/.worktreeinclude"
  ignore_locally 'external'

  run_selection || return 1

  assert_selected "external"
}

test_structural_destination_conflicts_are_warned() {
  printf 'bundle\nconfig/local.env\n.env\n' >"$REPO/.worktreeinclude"
  ln -s nowhere "$REPO/bundle"
  mkdir -p "$REPO/config"
  printf 'local\n' >"$REPO/config/local.env"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally 'bundle'
  ignore_locally 'config/local.env'
  ignore_locally '.env'
  add_index_entry "$WORKTREE" bundle/child
  add_index_entry "$WORKTREE" config

  run_selection || return 1

  assert_not_selected "bundle" || return 1
  assert_not_selected "config/local.env" || return 1
  assert_selected ".env" || return 1
  assert_output_contains "tracked path conflict: bundle" || return 1
  assert_output_contains "tracked path conflict: config/local.env"
}

test_structural_source_conflicts_are_warned() {
  printf 'bundle\n.env\n' >"$REPO/.worktreeinclude"
  ln -s nowhere "$REPO/bundle"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally 'bundle'
  ignore_locally '.env'
  add_index_entry "$REPO" bundle/child

  run_selection || return 1

  assert_not_selected "bundle" || return 1
  assert_selected ".env" || return 1
  assert_output_contains "tracked path conflict: bundle"
}

test_case_insensitive_structural_conflicts_are_warned() {
  printf 'config\n.env\n' >"$REPO/.worktreeinclude"
  ln -s nowhere "$REPO/config"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally 'config'
  ignore_locally '.env'
  git -C "$WORKTREE" config core.ignoreCase true
  add_index_entry "$WORKTREE" CONFIG/child

  run_selection || return 1

  assert_not_selected "config" || return 1
  assert_selected ".env" || return 1
  assert_output_contains "tracked path conflict: config"
}

test_tracked_siblings_are_not_structural_conflicts() {
  mkdir -p "$REPO/config"
  printf 'tracked\n' >"$REPO/config/app.json"
  git -C "$REPO" add config/app.json
  git -C "$REPO" commit -qm "Add tracked sibling"
  printf 'local\n' >"$REPO/config/local.json"
  printf 'config/local.json\n' >"$REPO/.worktreeinclude"
  ignore_locally 'config/local.json'

  run_selection || return 1

  assert_selected "config/local.json"
}

test_existing_destination_is_preserved() {
  printf '.env\n' >"$REPO/.worktreeinclude"
  printf 'source\n' >"$REPO/.env"
  printf 'destination\n' >"$WORKTREE/.env"
  ignore_locally '.env'

  run_plugin

  assert_content "$WORKTREE/.env" destination || return 1
  assert_output_contains "destination exists" || return 1
  assert_output_excludes "symlink 0"
}

test_destination_validation_finishes_before_installation() {
  mkdir -p "$REPO/config"
  printf 'first\n' >"$REPO/first.env"
  printf 'second\n' >"$REPO/config/second.env"
  printf 'first.env\nconfig/second.env\n' >"$REPO/.worktreeinclude"
  ignore_locally 'first.env'
  ignore_locally 'config/second.env'
  printf 'blocking\n' >"$WORKTREE/config"

  run_plugin

  assert_symlink "$WORKTREE/first.env" || return 1
  assert_output_contains "destination has a symlink or non-directory parent" || return 1
  assert_output_contains "symlink 1, skipped 0"
}

test_case_insensitive_declaration_resolves_source_spelling() {
  mkdir -p "$REPO/Config"
  printf 'secret\n' >"$REPO/Config/Local.env"
  printf 'config/local.env\n' >"$REPO/.worktreeinclude"
  printf 'Config/Local.env\n' >>"$REPO/.git/info/exclude"
  git -C "$REPO" config core.ignoreCase true

  run_selection || return 1

  assert_selected "Config/Local.env"
}

test_unsafe_destination_parent_is_skipped() {
  mkdir -p "$REPO/config" "$TEST_ROOT/outside"
  printf 'source\n' >"$REPO/config/local.env"
  printf 'config/local.env\n' >"$REPO/.worktreeinclude"
  ignore_locally 'config/local.env'
  ln -s "$TEST_ROOT/outside" "$WORKTREE/config"

  run_plugin

  assert_missing "$TEST_ROOT/outside/local.env" || return 1
  assert_output_contains "destination has a symlink or non-directory parent"
}

test_include_file_can_select_itself() {
  printf '.worktreeinclude\n' >"$REPO/.worktreeinclude"
  ignore_locally '.worktreeinclude'

  run_selection || return 1

  assert_selected ".worktreeinclude"
}

test_obsolete_include_file_config_aborts_run() {
  printf 'mode=copy\ninclude_file=.other\n' >"$REPO/.herdr-worktree-include"
  printf '.env\n' >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally '.env'

  run_plugin

  assert_missing "$WORKTREE/.env" || return 1
  assert_output_contains ".herdr-worktree-include:2: unsupported key: include_file" || return 1
  assert_output_contains "invalid configuration, skipping"
}

test_missing_include_file_is_a_quiet_noop() {
  run_plugin

  [[ $STATUS -eq 0 ]] || fail "plugin exited $STATUS"
  [[ $OUTPUT == '' ]] || fail "expected no output, got: $OUTPUT"
}

test_nonregular_include_file_aborts_run() {
  mkdir "$REPO/.worktreeinclude"

  run_plugin

  assert_output_contains ".worktreeinclude is not a readable file, skipping"
}

test_no_summary_when_nothing_is_eligible() {
  printf '*.env\nmissing.env\nREADME\n' >"$REPO/.worktreeinclude"

  run_plugin

  assert_output_contains "unsupported pattern, ignoring" || return 1
  assert_output_excludes "symlink 0"
}

test_script_is_inert_when_sourced() {
  # shellcheck disable=SC2016 # The nested Bash process expands this script.
  OUTPUT=$("$PLUGIN_BASH" -c '
    plugin=$1
    set +u
    set +o pipefail
    before_flags=$-
    before_directory=$PWD
    set -- first second
    trap ":" TERM
    before_trap=$(trap -p TERM)

    source "$plugin"

    [[ $- == "$before_flags" ]] || exit 11
    [[ $PWD == "$before_directory" ]] || exit 12
    [[ $1 == first && $2 == second ]] || exit 13
    [[ $(trap -p TERM) == "$before_trap" ]] || exit 14
    declare -F _worktree_include_select_eligible_leaf_entries >/dev/null || exit 15
    printf reached
  ' "$PLUGIN" "$PLUGIN" 2>&1)
  STATUS=$?

  [[ $STATUS -eq 0 ]] || fail "sourcing check exited $STATUS: $OUTPUT"
  [[ $OUTPUT == reached ]] || fail "unexpected sourcing output: $OUTPUT"
}

test_selection_failure_clears_output() {
  local not_repo=$TEST_ROOT/not-a-repository diagnostics=$TEST_ROOT/selection.stderr
  local selection_tmp=$TEST_ROOT/selection-tmp
  local -a actual=(stale)
  mkdir "$not_repo" "$selection_tmp"
  printf 'local.env\n' >"$not_repo/.worktreeinclude"
  printf 'secret\n' >"$not_repo/local.env"

  if TMPDIR=$selection_tmp _worktree_include_select_eligible_leaf_entries \
    "$not_repo" "$WORKTREE" actual 2>"$diagnostics"; then
    fail "expected selection failure"
    return 1
  fi

  [[ ${#actual[@]} -eq 0 ]] || fail "selection failure retained partial output"
  local -a leftovers=("$selection_tmp"/herdr-worktree-include.*)
  [[ ! -e ${leftovers[0]} ]] || fail "selection failure leaked temporary storage"
  OUTPUT=$(<"$diagnostics")
  assert_output_contains "could not inspect ignored files"
}

test_selection_output_name_does_not_collide() {
  local -a complete_result=(stale)
  printf '.env\n' >"$REPO/.worktreeinclude"
  printf 'secret\n' >"$REPO/.env"
  ignore_locally '.env'

  _worktree_include_select_eligible_leaf_entries \
    "$REPO" "$WORKTREE" complete_result || return 1

  [[ ${#complete_result[@]} -eq 1 ]] || fail "expected one Eligible leaf entry"
  [[ ${complete_result[0]} == .env ]] || fail "unexpected entry: ${complete_result[0]}"
}

for dependency in git jq bash cp mktemp readlink mkfifo; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'missing test dependency: %s\n' "$dependency" >&2
    exit 1
  fi
done

run_test "script is inert when sourced" test_script_is_inert_when_sourced
run_test "nested leaves with tracked siblings" test_nested_leaf_with_tracked_siblings
run_test "copy mode preserves leaf symlinks" test_copy_mode_copies_files_and_preserves_symlinks
run_test "copy failure preserves partial destination" test_copy_failure_preserves_partial_destination
run_test "leading slash and duplicate declarations" test_leading_slash_and_duplicate_declarations
run_test "shared files ignore unsupported Git patterns" test_shared_file_ignores_unsupported_gitignore_patterns
run_test "invalid literal paths are ignored" test_invalid_literal_paths_are_ignored
run_test "ordinary ineligible declarations are quiet" test_missing_tracked_and_nonignored_declarations_are_quietly_omitted
run_test "standard Git ignore sources are used" test_standard_git_ignore_sources_are_used
run_test "global Git excludes are used" test_global_git_excludes_are_used
run_test "directories and special files are skipped" test_directories_and_special_files_are_warned_and_skipped
run_test "source symlinked parents are rejected" test_source_symlinked_parent_is_rejected
run_test "leaf symlinks to directories are allowed" test_leaf_symlink_to_directory_is_allowed
run_test "structural destination conflicts are warned" test_structural_destination_conflicts_are_warned
run_test "structural source conflicts are warned" test_structural_source_conflicts_are_warned
run_test "case-insensitive structural conflicts are warned" test_case_insensitive_structural_conflicts_are_warned
run_test "tracked siblings are allowed" test_tracked_siblings_are_not_structural_conflicts
run_test "existing destinations are preserved" test_existing_destination_is_preserved
run_test "destination validation finishes before installation" test_destination_validation_finishes_before_installation
run_test "case-insensitive declarations resolve source spelling" test_case_insensitive_declaration_resolves_source_spelling
run_test "unsafe destination parents are skipped" test_unsafe_destination_parent_is_skipped
run_test "include file can select itself" test_include_file_can_select_itself
run_test "obsolete include_file config aborts run" test_obsolete_include_file_config_aborts_run
run_test "missing include file is a quiet noop" test_missing_include_file_is_a_quiet_noop
run_test "nonregular include file aborts run" test_nonregular_include_file_aborts_run
run_test "empty eligible set has no summary" test_no_summary_when_nothing_is_eligible
run_test "selection failure clears output" test_selection_failure_clears_output
run_test "selection output names do not collide" test_selection_output_name_does_not_collide

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
