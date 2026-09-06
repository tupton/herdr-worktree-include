# 3. Scope and batch include selection

Date: 2026-09-06

## Status

Accepted

## Context

The plugin runs `bash src/include.sh` after `worktree.created`. In Herdr v0.8.2, `start_plugin_command` starts a thread and spawns the child command without waiting for it. Herdr emits `worktree.created` before sending the successful worktree-create response, but event hooks started by that emission continue asynchronously. A created worktree can therefore become visible before its included files do. Herdr also permits up to 32 plugin commands in flight. These are properties of the [v0.8.2 plugin runtime](https://github.com/herdrdev/herdr/blob/v0.8.2/src/app/api/plugins/runtime.rs#L12-L13), its [`start_plugin_command` implementation](https://github.com/herdrdev/herdr/blob/v0.8.2/src/app/api/plugins/runtime.rs#L16-L184), and the [worktree completion path](https://github.com/herdrdev/herdr/blob/v0.8.2/src/app/api/worktrees/deferred.rs#L456-L471).

Latency therefore affects correctness as users perceive it, even though it does not delay the API response. A shell or agent opened in the new worktree may look for an included environment file while the hook is still traversing the source checkout.

ADR 0002 defines selection as an intersection. Git applies the ordered include files using Git-ignore semantics; standard Git ignore rules must also ignore the result; and tracked paths remain ineligible. Include files passed with `--exclude-from` are root-relative and retain declaration order. Git documents both the [exclude-pattern ordering used by `git ls-files`](https://git-scm.com/docs/git-ls-files#_exclude_patterns) and the [standard ignore sources and precedence](https://git-scm.com/docs/gitignore#_description).

This boundary matters. Git-ignore patterns and pathspecs are different languages. For example, a slashless ignore pattern can match a basename at any level, while a pathspec has a directory-prefix rule and its remaining pattern may match slashes unless `glob` magic changes that behavior. See the [Git-ignore pattern rules](https://git-scm.com/docs/gitignore#_pattern_format) and [pathspec definition](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec). The plugin must not translate include rules into pathspec rules or implement a second matcher in Bash.

## Evidence

The following results are measurements, not complexity estimates.

A prior single-run benchmark in `/Users/tupton/code/wizehire/main`, with one include pattern, `src/django/.env`, recorded:

| Operation | Wall time |
| --- | ---: |
| `git ls-files --others --ignored` | 2.23 s |
| The same command with `--directory` | 2.23 s |
| Whole-tree `find` for unsupported source types | 2.70 s |

Recent Herdr plugin logs for that repository recorded 5.883 s, 4.194 s, 4.015 s, and 6.975 s. A small invocation completed in 86 ms. These samples establish the scale of the problem but are not a controlled distribution. A repeat on 2026-09-06, without controlling filesystem cache state, measured 2.17 s, 0.53 s, and 2.40 s for the same three operations. The variance is a reason to benchmark warm and cold runs separately.

The current implementation explains those numbers:

- `discover_candidates` performs two source-tree `git ls-files` traversals, one leaf traversal and one `--directory` traversal (`src/include.sh:357-367`). Git says `--others` lists untracked files and `--directory` collapses a wholly untracked directory ([`git ls-files` options](https://git-scm.com/docs/git-ls-files#_options)).
- It then runs an unconditional recursive `find` over the source tree (`src/include.sh:373-374`). POSIX specifies that `find` recursively descends each starting hierarchy unless pruned ([POSIX `find`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/find.html)).
- `classify_direct_directories` starts another Git process for every candidate directory (`src/include.sh:445-455`).
- The first standard-ignore pass uses ordinary `git check-ignore` for every leaf and directory (`src/include.sh:473`). In Git's implementation, stdin is consumed one path at a time, and each ordinary check calls `find_pathspecs_matching_against_index` ([`builtin/check-ignore.c`](https://github.com/git/git/blob/v2.55.0/builtin/check-ignore.c#L80-L151)). `--no-index` exists specifically to omit that index check ([`git check-ignore --no-index`](https://git-scm.com/docs/git-check-ignore#Documentation/git-check-ignore.txt---no-index)).
- `has_tracked_conflict` repeatedly starts `git config` and `git ls-files` for source paths, destination paths, and ancestors (`src/include.sh:73-98`). Selection invokes it for each candidate and installation invokes it again (`src/include.sh:517-518`, `src/include.sh:560-561`, and `src/include.sh:626-627`).
- `inspect_directory_tree` removes its queue head by copying the rest of the Bash array and calls `git rev-parse` through `is_repository_root` for every visited directory (`src/include.sh:261-301`).

## Complexity model

The following is modeled complexity, not measured runtime. Let:

- `N` be the number of filesystem entries in the source checkout.
- `S` be the number of entries below the planner's scoped roots, with `S <= N`.
- `Ts` and `Td` be source-index and destination-index entry counts.
- `C` be the number of candidate entries.
- `R` be the entries inspected below accepted atomic directories.
- `H` be maximum path depth.

The current broad path is at least three `O(N)` filesystem walks before candidate-specific work. Its repeated conflict checks add process startup and repeated index work proportional to `C` and `H`; the exact Git cost depends on index representation and pathspec pruning. Queue slicing can copy a shrinking array on every directory and is `O(R^2)` in the worst case.

The proposed common literal path is `O(L + Ts*H + Td*H + C*H + R)`, where `L` is the number of literal patterns. It should touch neither unrelated source-tree entries nor the whole source tree. The generic scoped path replaces `N` with `S` for discovery and special-file inspection. The unscoped fallback remains `O(N)` by design. Batched snapshots trade memory proportional to generated conflict keys for eliminating candidate-proportional Git process and index scans.

Big-O does not predict the wall-time improvement by itself. The measured repository is dominated by directory traversal and process work, so phase timings and Trace2 counters remain the deciding evidence.

## Decision

Implement a conservative query planner before candidate discovery. It may derive a root-relative superset of where positive include patterns could match. It must pass every original include snapshot to Git as an ordered `--exclude-from` argument, including duplicate declarations, so Git remains the final matcher. If parsing is uncertain, the planner broadens the scope or uses the existing whole-tree path. It never narrows on a guess.

### Planning tiers

Use three tiers:

| Tier | Condition | Discovery |
| --- | --- | --- |
| Rooted literal | Every positive pattern is safely recognized as a root-relative literal | Probe exact paths and only traverse explicit directory targets |
| Rooted prefix | Every positive non-literal pattern has a safe root-relative directory prefix | Run Git and filesystem inspection only below the union of those prefixes |
| Whole tree | Any positive pattern is slashless or has no safe prefix | Preserve the current repository-wide discovery behavior |

A pattern with an unescaped slash at the beginning or in the middle is root-relative because include files are supplied through `--exclude-from`. A slashless pattern is unscopable because Git may match it at any level. This follows Git's documented [slash rules](https://git-scm.com/docs/gitignore#_pattern_format) and [`--exclude-from` root-relative behavior](https://git-scm.com/docs/git-ls-files#_exclude_patterns).

Only positive patterns introduce search regions. A negated pattern removes matches selected earlier; it does not create a selected path by itself. Git documents negation as re-including a path excluded by a previous pattern ([Git-ignore pattern format](https://git-scm.com/docs/gitignore#_pattern_format)). Negations still remain in every ordered `--exclude-from` argument passed to Git.

The parser recognizes only enough syntax to prove a safe scope:

- For a rooted literal, decode only escapes whose interpretation is unambiguous, remove the anchoring and directory-only markers, and reject `.git`, absolute paths, `..`, invalid trailing escapes, or any uncertain construct.
- For a rooted generic pattern, retain only complete literal path components before the first unescaped metacharacter. A partial component such as `src*` is not the literal directory `src` and cannot scope to it.
- Deduplicate and remove descendant roots covered by a shallower root.
- Treat `core.ignoreCase=true` conservatively. Exact filesystem lookup using the pattern's spelling can miss a differently cased path on a case-sensitive filesystem. Until component-wise case-insensitive discovery is proved correct, downgrade such cases to a broader Git-backed scope or the whole-tree fallback.
- Treat malformed, unsupported, or ambiguous input as unscopable. The fallback is part of correctness, not an error condition.

Each Git discovery command receives literal top-level pathspecs such as `:(top,literal)src/django/.env` or `:(top,literal)src/django`. Pathspecs limit traversal but do not decide inclusion. Git's directory walker computes a pathspec common prefix and uses it to prune the walk ([`fill_directory` in `dir.c`](https://github.com/git/git/blob/v2.55.0/dir.c#L272-L292)); `top` anchors at the worktree root and `literal` disables wildcard interpretation ([pathspec magic](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefpathspecapathspec)).

### Literal fast path

For an all-rooted-literal plan:

- Use no-follow existence and type checks on each exact source path. POSIX `lstat` returns information about a symlink itself rather than its target ([POSIX `lstat`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/lstat.html)). In Bash, preserve the current `-L` handling for broken symlinks.
- Batch file and symlink targets into one Git matching call with the original include arguments and exact literal pathspecs. Do not run the `--directory` traversal for those targets.
- Inspect only explicit directory targets. Do not derive every ancestor of every leaf and do not scan unrelated directories.
- Keep Git as final matcher unless the open question below is resolved with an equivalence test matrix. The literal parser's first job is safe candidate and scope derivation, not replacing Git-ignore semantics.
- If an exact target is a special file, test only that target through the synthetic-index mechanism. Do not run a whole-tree special-file scan.

This path is aimed directly at the measured `src/django/.env` case: one exact lookup and scoped Git matching replace two whole-tree Git walks and one whole-tree `find`.

### Generic scoped and fallback paths

Pass the same set of literal scope pathspecs to both leaf and collapsed `git ls-files` traversals. Multiple roots form a union of safe regions. Original include files still determine the result.

Keep direct-directory semantics. An ignored directory selected as a directory remains one atomic entry; a pattern selecting only descendants does not make the parent atomic. The existing per-directory probe may remain for generic candidates in the first implementation, because inferring direct selection from collapsed output alone is not equivalent. Scope should make that candidate set much smaller. A later batching change needs a Git-backed proof against directory-only patterns, negation, and parent exclusion before replacing those probes.

Do not combine include rules and standard excludes into one `git ls-files` invocation. The contract requires their intersection. Putting both rule sets into one exclude stack applies Git's precedence and last-match behavior to their union, which can produce a different result. Git documents last-match ordering and precedence for ignore sources ([`gitignore`](https://git-scm.com/docs/gitignore#_description)).

### Batch standard-ignore and tracked safety checks

Send every candidate once to a single `git check-ignore --no-index --stdin -z`. This asks Git to apply `.gitignore`, `$GIT_COMMON_DIR/info/exclude`, and `core.excludesFile`, while deliberately separating tracked safety from ignore matching. The command supports NUL-delimited stdin and output, and `--no-index` bypasses the tracked-file suppression ([`git check-ignore` options and output](https://git-scm.com/docs/git-check-ignore#_options)).

Read each index once with `git ls-files -z`, one snapshot for the source checkout and one for the destination worktree. Respect `core.ignoreCase` when building associative sets. From each tracked path build:

- An exact-path set.
- A descendant-conflict set containing directory prefixes that have tracked content below them.
- The original tracked-path set used to test whether a file or symlink is an ancestor of a candidate.

Candidate checks then use set lookups and ancestor iteration rather than Git subprocesses. A tracked directory is represented by descendants, not by a directory index entry, so an ordinary directory prefix is not itself an ancestor conflict. This preserves the existing `tracked directories are not ancestor conflicts` test.

Take fresh source and destination index snapshots immediately before installation and re-evaluate the selected entries. Do not remove this second check. `test_source_tracked_conflict_is_rechecked_before_install` changes the source index after ignore evaluation and requires the race to be detected. The recheck narrows the race window but cannot make filesystem installation atomic with Git index updates.

### Special files and directory safety

Make unsupported-type discovery lazy and scoped. Git's normal untracked walker returns `path_none` for unhandled directory-entry types, so it cannot supply FIFO, socket, or device candidates ([directory-entry type switch in `dir.c`](https://github.com/git/git/blob/v2.55.0/dir.c#L2478-L2505)). Broad wildcard behavior therefore still needs a filesystem walk if warning for selected special files remains part of the contract.

Run that walk only when the plan or an explicit target can select a special file, and only below scoped roots when scopes exist. Check whether any special paths were found before invoking `git hash-object` and constructing a synthetic index. POSIX `find` does not follow encountered symlinks unless `-L` is specified, and `-type` distinguishes regular files, directories, links, FIFOs, devices, and sockets ([POSIX `find`](https://pubs.opengroup.org/onlinepubs/9799919799/utilities/find.html)).

For each selected atomic directory, replace Git-per-directory repository checks with one no-follow subtree walk. During that walk, reject unsupported types and unreadable directories, and collect only plausible repository roots:

- A directory containing a `.git` file or directory.
- A possible bare repository containing repository control files and directories, such as `HEAD`, `objects`, and `refs`.

Invoke Git only to validate those plausible roots. Git defines a gitfile as a `.git` file pointing to the real repository and describes bare repositories as repository administrative files without a checked-out tree ([Git glossary](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefgitfileagitfile) and [bare repository](https://git-scm.com/docs/gitglossary#Documentation/gitglossary.txt-aiddefbarerepositoryabarerepository)). Use a queue head index instead of `pending=("${pending[@]:1}")`, so traversal does not repeatedly copy the queue.

## Caching

Do not make Git's untracked cache or FSMonitor the primary solution. Git's `validate_untracked_cache` rejects the cache when a pathspec is present, ignored entries are being collected or shown, or unmanaged exclude files were added. All three conditions occur in this design or the current include traversal ([`validate_untracked_cache` in `dir.c`](https://github.com/git/git/blob/v2.55.0/dir.c#L2972-L3017)). Scoping still reduces the uncached walk.

Defer cross-event plugin caching. A correct cache key and invalidation scheme would have to cover all include file contents and declaration order, source path existence and type changes, nested `.gitignore` files, `$GIT_COMMON_DIR/info/exclude`, `core.excludesFile`, both source and destination indexes, and `core.ignoreCase`. Cache publication would also need coordination across asynchronous invocations because Herdr v0.8.2 allows 32 plugin commands in flight ([runtime limit](https://github.com/herdrdev/herdr/blob/v0.8.2/src/app/api/plugins/runtime.rs#L12-L13)). Reducing work inside one invocation is simpler and does not introduce stale selection.

## Implementation sequence

1. Add phase timing and subprocess-count instrumentation behind an environment variable. Record plan tier and scoped roots without logging file contents.
2. Add parser fixtures that prove each pattern is classified as literal, prefix-scoped, or fallback. Include escaped metacharacters, escaped leading `!` and `#`, trailing spaces, directory markers, `**`, malformed escapes, slashless patterns, negation, duplicate include files, and `core.ignoreCase`.
3. Implement the planner and add literal top-level pathspecs to both existing Git traversals. Keep the whole-tree fallback unchanged and compare selected-entry byte streams between old and new paths.
4. Add the all-rooted-literal path. Skip collapsed discovery for file and symlink targets; inspect only explicit directory targets.
5. Replace standard-ignore calls with one `check-ignore --no-index --stdin -z`, then add source and destination index snapshots and set-based conflict checks.
6. Preserve a fresh pre-install snapshot and adapt the existing race test to assert that the second snapshot catches the mutation.
7. Scope and delay special-file discovery and `hash-object`.
8. Replace repository checks and queue slicing with the single no-follow safety walk and plausible-root validation.
9. Remove superseded subprocess paths only after the full integration suite and differential fixtures pass.

## Benchmark plan

Measure both direct script performance and user-visible availability. Direct wall time starts before invoking `src/include.sh` and ends at process exit. Event-to-file availability starts when Herdr accepts or begins worktree creation and ends when the last expected include appears in the new worktree. Because hooks are asynchronous, these are different metrics.

For every run, capture:

- Total wall time and phase timings for planning, Git discovery, direct-directory classification, standard ignores, index snapshots, safety inspection, recheck, and installation.
- Total subprocess count and counts by command.
- Git Trace2 `read_directory` regions plus `directories-visited`, `paths-visited`, and `opendir` counters. Git documents the Trace2 event target and structured `data` events ([Trace2 API](https://git-scm.com/docs/api-trace2#_the_event_format_target)); Git emits these traversal counters from [`dir.c`](https://github.com/git/git/blob/v2.55.0/dir.c#L3105-L3161).
- Candidate, accepted-directory, leaf, scoped-root, and inspected-entry counts.
- Warm and cold runs, reported separately with median, p95, minimum, and maximum over enough repetitions to expose variance.

The fixture matrix must vary tree and index size, wide and deep tree shape, one and many rooted literals, rooted wildcard prefixes, slashless wildcards, and forced whole-tree fallback. It must also cover root and nested `.gitignore`, info excludes, global excludes, direct and expanded directories, source and destination tracked conflicts, sparse or absent tracked files, nested and bare repositories, FIFOs and other available special types, symlinks and broken symlinks, `core.ignoreCase`, warm and cold caches, and concurrent worktree events.

Suggested acceptance targets are:

- No selected-entry or warning regressions in the existing integration suite and the new differential matrix.
- For the measured Wizehire literal case, warm direct-script p50 below 250 ms and p95 below 500 ms; cold p95 below 1 s.
- For that literal case, zero whole-tree `ls-files` or `find` traversals and no candidate-proportional Git subprocesses.
- For rooted-prefix fixtures, Trace2 `directories-visited` and `paths-visited` should track the scoped subtree rather than repository size.
- For fallback fixtures, no more than 10 percent median wall-time regression against the current implementation.
- Warm event-to-file p95 below 500 ms and cold p95 below 1 s for a single literal file, measured through Herdr rather than inferred from script time.
- Under concurrent events, no wrong-worktree installs, stale cache behavior, truncated candidate streams, or invocation-limit failures attributable to the plugin.

These are proposed gates, not evidence that the implementation already meets them.

## Consequences and tradeoffs

- The common literal case becomes proportional to explicit targets and index size rather than source-tree size.
- Rooted wildcard patterns gain bounded traversal without changing their matcher.
- Slashless patterns retain current cost. That is the price of preserving their match-at-any-depth meaning.
- Two index snapshots and derived sets use more memory, but replace many short-lived Git processes and repeated index scans.
- The planner adds parsing code. Its output is only a superset scope, and fallback limits the consequence of parser uncertainty.
- Generic direct-directory classification may remain candidate-proportional initially. Optimizing it without changing atomic-directory semantics is separate work.
- The asynchronous Herdr contract remains. Faster execution reduces, but does not eliminate, the interval in which a worktree is visible before includes arrive.

## Alternatives considered

**Combine include and standard excludes in one traversal.** Rejected. That computes one precedence-ordered exclusion result, not the required intersection of two independently evaluated rule sets.

**Translate Git-ignore patterns to pathspecs or shell globs.** Rejected. The syntaxes differ, and ADR 0002 chose Git as the matching authority. The planner may derive a superset prefix only.

**Implement a Bash Git-ignore matcher.** Rejected. Escapes, negation, anchoring, directory-only rules, `**`, and case behavior would duplicate Git and create a second contract.

**Rely on untracked cache or FSMonitor.** Rejected as the primary design. Git disables the relevant untracked-cache path under this command shape, and filesystem monitoring would not remove repeated process and index work.

**Cache complete results across events.** Deferred. The invalidation and concurrency requirements are larger than the selection optimization and a stale positive result can install the wrong path.

**Always use the whole-tree fallback but parallelize it.** Rejected. It increases I/O contention under concurrent hooks and leaves work proportional to repository size for a one-file include.

## Resolved implementation choices

- Preserve current special-file warnings. Each selected standalone special file is warned and skipped; an atomic directory containing one or more special files is rejected with one directory-level warning. Literal plans inspect exact targets; rooted-prefix plans inspect only their scoped roots; whole-tree plans retain broad special-file discovery.
- Keep Git as the final matcher for rooted literals. The planner derives candidate paths and scopes but does not replace Git-ignore matching.
- Retain Git-backed per-directory classification for generic candidates. Scope reduction bounds this work for rooted-prefix plans.
- Expose plan, command-count, candidate-count, inspection-count, and phase-timing diagnostics through the opt-in `HERDR_WORKTREE_INCLUDE_DIAGNOSTICS` file path. This is a plugin testing interface, not a Herdr completion event.
- Use deterministic traversal and subprocess assertions as automated performance gates. Wall-clock acceptance targets remain manual benchmarks because cold-cache preparation and shared CI hardware are not reproducible enough for stable thresholds.
