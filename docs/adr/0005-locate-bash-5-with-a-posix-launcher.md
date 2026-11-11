# 5. Locate Bash 5 with a POSIX launcher

Date: 2026-11-11

## Status

Accepted. Reverses the "Re-exec under a newer Bash found on disk" alternative rejected in ADR 0001. The Bash 5 floor from ADR 0001 is unchanged.

## Context

ADR 0001 kept `command = ["bash", "src/include.sh"]` and relied on `PATH` to find Bash 5. It treated an unexpected Bash 3.2 as a rare misconfiguration that the guard would report.

That assumption failed on the plugin's one known machine. Herdr runs plugin commands with the Herdr server's environment, not the user's shell. `brew services start herdr` registers a launchd agent, and launchd starts the server with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. There, `bash` is `/bin/bash` 3.2. Homebrew's Bash 5 was installed but not on that `PATH`. The plugin stopped working after a reboot let the launchd server win over a server started from a shell. The guard reported "found 3.2.57", which was accurate but not actionable from inside the plugin.

So this is the default result of a supported way to run Herdr on macOS, not a misconfiguration.

## Decision

Herdr runs `sh src/launch.sh`. The launcher is POSIX `sh` and calls no external commands, so it works under any `/bin/sh` and any `PATH`. It:

1. Checks `bash` in every `PATH` directory, in order. It skips empty and relative entries.
2. Then checks a fixed list of package manager directories. `fallback_dirs` in `src/launch.sh` is the only place that lists them.
3. Execs the first candidate whose `BASH_VERSINFO[0]` is at least 5, passing `include.sh`.
4. If none qualifies, warns with the first Bash it found and its version, or says none was found, and exits 0.

`include.sh` keeps its own Bash 5 guard for direct runs and for sourcing.

## Consequences

- A launchd-started Herdr server works when Homebrew or MacPorts Bash 5 is installed. No `PATH` setup is needed.
- `PATH` still wins. A user who puts a Bash 5 first on `PATH` gets that Bash.
- ADR 0001's concern was that re-exec "works until it does not, and then the failure is invisible." The launcher addresses this. Its failure message names the interpreter it rejected and where it found it. Success is visible in Herdr's plugin log, which records the plugin's stdout.
- The fallback locations are a fixed list. A Bash 5 installed elsewhere, for example by Nix or mise, is found only through `PATH`.
- The interpreter requirement now has two runtime checks: the launcher's search and `include.sh`'s guard.
- CI runs the launcher on macOS under launchd's `PATH` and requires that `include.sh` passes its guard.

## Alternatives considered

**Ask users to fix launchd's `PATH`** (`launchctl config user path`). Rejected as the default. It needs `sudo` and a reboot, it affects every launchd agent, and nothing in the plugin points users to it.

**Ask users not to run Herdr as a brew service.** Rejected. It is a valid way to run Herdr, and the plugin can't tell users before it fails.

**Hardcode an interpreter in `herdr-plugin.toml`.** Still rejected for ADR 0001's reason: Homebrew's prefix differs by platform and architecture.
