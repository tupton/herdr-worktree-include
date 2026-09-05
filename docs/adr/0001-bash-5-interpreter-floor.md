# 1. Require Bash 5

Date: 2026-09-05

## Status

Accepted

## Context

The plugin is a single Bash script that Herdr runs on `worktree.created`:

```toml
command = ["bash", "src/include.sh"]
```

That is a PATH lookup, not a fixed interpreter path. Until now the script targeted **Bash 3.2**, the version Apple ships as `/bin/bash`, so that it would work on a stock macOS machine with no Homebrew Bash ahead of it on PATH.

Holding that floor was not free. Three separate pieces of the script existed only to work around it:

- Functions cannot return arrays, and 3.2 has no `mapfile`, so the phases that produce lists had to populate script-scope arrays instead of returning them.
- No associative arrays, so deduplication was a linear `array_contains` scan — O(n²), with a comment warning future readers not to "simplify" it into a set and silently break 3.2.
- `set -u` errors on `"${arr[@]}"` for an empty array until 4.4, so the script could not adopt `set -u` at all.

Each workaround made the script read as more complicated than the thing it actually does, which is: read a list of paths, symlink or copy each one.

The floor was also never verified. There was no CI, and development happens on a machine where `bash` resolves to Homebrew's 5.3. "Bash 3.2 or later" was an unverified claim in the README.

## Decision

Require **Bash 5.0 or newer**.

When the running interpreter is older, warn and `exit 0` rather than failing. Every other precondition in this script behaves that way already (`jq not found, skipping`, `not a Git worktree`), and the plugin's contract is that it must never break worktree creation. A user on stock macOS Bash gets one explanatory line and a worktree that was created normally, just without the extra files.

CI asserts this: a job runs the plugin under `/bin/bash` on `macos-latest` and requires both exit 0 and the guard's message.

The guard itself must stay parseable by old Bash. As it happens, the 5.x features used here (`mapfile`, `declare -A`) are runtime failures rather than parse errors in 3.2, so a guard at the top of the file is reached before anything else fails.

## Consequences

- A user on stock macOS Bash with no Homebrew Bash on PATH gets no files linked, and a warning saying why. Previously they got working behavior.
- `array_contains` is deleted; deduplication becomes an associative-array lookup.
- Phase functions can return lists via `mapfile -d ''`, so the script's data flow is explicit rather than passed through script-scope arrays.
- `set -uo pipefail` becomes available. `set -e` is deliberately not adopted: it converts unanticipated failures into abrupt mid-run exits with no message and a possibly half-populated worktree, which is the opposite of this plugin's contract.
- The requirement lives in three places — the runtime guard, the README, and this record. Only the guard is load-bearing; `herdr-plugin.toml` has no field for declaring an interpreter version.

## Alternatives considered

**Keep Bash 3.2.** Rejected. The cost is paid in every line of the script, to serve a user who has not appeared — this plugin has one user, on a machine that already runs 5.3. The scenario the floor protects against is also the one it obscures: `bash` silently resolving to an unexpected 3.2 on a machine nobody is watching. An explicit guard handles that better than compatibility does.

**Bash 4.4.** Rejected as a distinction without a population. 4.4 shipped in 2016 and buys the same three wins; anywhere that has 4.4 and not 5.0 is vanishingly rare in 2026.

**Rewrite in zsh 5.** Rejected on tooling. ShellCheck has no zsh support at all (`shellcheck -s zsh` → `Unknown shell: zsh`), which would mean dropping static analysis entirely. zsh is also not reliably present on Linux, half of the plugin's declared `platforms`, and it offers nothing over Bash 5 for this script.

**Hardcode an interpreter path in `herdr-plugin.toml`.** Rejected as non-portable: Homebrew lives at `/opt/homebrew` on Apple Silicon, `/usr/local` on Intel, and `/home/linuxbrew` on Linux.

**Re-exec under a newer Bash found on disk.** Rejected as too implicit. It works until it does not, and then the failure is invisible.
