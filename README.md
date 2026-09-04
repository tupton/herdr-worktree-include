# Herdr Worktree Include

Herdr Worktree Include is a [Herdr](https://herdr.dev) plugin that symlinks or copies selected files and directories from a repository's main checkout into Herdr-created worktrees.

It is intended for local, git-ignored state that should be available in a
new worktree without being committed, such as environment files, local tool
configuration, and caches.

See [Claude Code's documentation about how to copy gitignored files into worktrees](https://code.claude.com/docs/en/worktrees#copy-gitignored-files-into-worktrees) for inspiration and more details.

## Requirements

- Herdr 0.7.0 or later
- macOS or Linux
- Bash 3.2 or later
- Git
- `jq` available on your path

## Installation

Install from GitHub:

```sh
herdr plugin install tupton/herdr-worktree-include
```

Or link a local checkout while developing the plugin:

```sh
herdr plugin link /path/to/herdr-worktree-include
```

## Quick Start

Create `.worktreeinclude` in the main checkout with one repository-relative
path per line:

```text
.env
.env.local
.turbo
```

The default mode is `symlink`. When Herdr creates a linked worktree, the plugin
creates links at the corresponding paths:

```text
new-worktree/.env -> main-checkout/.env
```

The plugin only handles worktrees created after it is installed. It does not
modify existing worktrees.

## Project Configuration

Add `.herdr-worktree-include` to the main checkout to select copy mode or use
additional include files:

```ini
mode=copy
include_file=.worktreeinclude
include_file=.worktreeinclude.local
```

Supported settings:

- `mode=symlink` links every selected path to the main checkout. This is the default.
- `mode=copy` recursively copies every selected path. Source symlinks are preserved rather than followed.
- `include_file=<path>` adds an include file. Every configured file that exists is read in declaration order. Entries from all files are combined, and duplicate paths are processed once in first-seen order. Missing files are ignored, allowing optional local include files. Existing paths that are not readable files are logged and skipped.

If no `include_file` setting is present, the plugin looks for `.worktreeinclude`.

The settings format is intentionally limited. It accepts one `key=value` pair per line, blank lines, and comments where the first non-whitespace character is `#`. Surrounding whitespace is ignored. Inline comments and quoted values are not interpreted specially.

An unsupported key, duplicate `mode`, invalid mode, or invalid include-file path invalidates the configuration. The plugin logs the error, creates nothing, and exits successfully so the Herdr event is not marked as failed.

This allows a committed `.worktreeinclude` to define team-wide entries while an optional `.worktreeinclude.local` adds personal entries. Keep the local file untracked without changing `.gitignore`:

```sh
printf '%s\n' '.worktreeinclude.local' >> .git/info/exclude
```

The project configuration may also be kept local. To use the default include file without committing either configuration file:

```sh
printf '%s\n' '.herdr-worktree-include' '.worktreeinclude' >> .git/info/exclude
```

## Include File Format

Include files accept one literal repository-relative path per line:

```text
# Local environment
.env
.env.local

# Tool state
.cache/tool
```

- Blank lines and full-line `#` comments are ignored.
- `#` elsewhere in a line is part of the path.
- Glob patterns and negation are not supported.
- Duplicate paths are processed once, in first-seen order.
- Empty and `.` path components are normalized.
- Absolute paths, `..` components, `.git`, and paths below `.git` are rejected.
- Missing sources and invalid entries are logged and skipped independently.

Source paths and their parents may be symlinks, including links that resolve outside the main checkout. Review local include files before using them.

## Safety

Worktree Include never replaces an existing destination file, directory, or symlink. It also refuses to traverse a destination parent that is a symlink or not a directory.

Before creating each destination, the plugin compares the selected path with `git ls-files`. It skips the entry if:

- The exact path is tracked.
- A tracked path is below the selected path.
- A tracked file or symlink is an ancestor of the selected path.

The Git index is authoritative, so tracked paths remain protected when they are absent from disk, including in sparse checkouts.

Copy failures may leave a partial destination behind. The plugin does not remove it because it may have been created or replaced concurrently by another process. Remove an incomplete destination before retrying; other invalid or conflicting entries do not prevent safe entries from being processed.

## Testing

The same dependencies are required to run the integration suite, so ensure that `jq` is on the path. Run the integration suite with:

```sh
bash tests/integration.sh
```

The tests create temporary Git repositories and linked worktrees, invoke the event handler directly, and remove the temporary data afterward.

For static checks, use [ShellCheck](https://www.shellcheck.net/):

```sh
shellcheck --shell=bash src/include.sh tests/integration.sh
```

## Attribution

This independent plugin was inspired by [hmu332233/herdr-symlink-worktree](https://github.com/hmu332233/herdr-symlink-worktree), an MIT-licensed Bash plugin for linking local files into Herdr worktrees.

## License

MIT. See [LICENSE](./LICENSE).
