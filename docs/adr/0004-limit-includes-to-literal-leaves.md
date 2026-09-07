# Limit includes to literal leaves

Status: Accepted

The full Git-ignore matcher and atomic directory support made a plugin for sharing a few environment and configuration files perform recursive discovery, classify directory matches, inspect directory trees, create synthetic indexes for special files, and maintain a query planner. Preserve `.worktreeinclude` as a file Claude Code can read, but support only unescaped repository-relative literal declarations that name regular files or symlinks. Warn and ignore richer Git-ignore patterns so one file can still serve both tools.

An eligible leaf must also be ignored and untracked according to normal Git rules. One batched `git ls-files --others --ignored --exclude-standard` query establishes source eligibility, and one index read per checkout protects exact paths, tracked descendants, and tracked file ancestors. Tracked siblings under an ordinary parent directory remain valid. Selection completes before installation, but completed filesystem writes are not rolled back.

This decision removes directory installation, glob expansion, multiple include files, diagnostics, recursive source-tree discovery, and the selection planner. It supersedes ADR 0002 and ADR 0003. The narrower contract favors the common `.env` and local configuration use case over cache-directory support and full Claude Code matching parity.
