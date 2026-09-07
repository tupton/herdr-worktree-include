# Herdr Worktree Include

Herdr Worktree Include is a [Herdr](https://herdr.dev) plugin that symlinks or copies selected leaf entries from a repository's main checkout into new linked worktrees.

It is intended for Git-ignored environment and configuration leaf entries that should be available in each worktree without being committed.

## Requirements

- Herdr 0.7.0 or later
- macOS or Linux
- Bash 5.0 or later
- Git
- `jq`

macOS ships Bash 3.2. Install a current Bash with `brew install bash` and make sure it appears before `/bin/bash` on `PATH`.

## Installation

```sh
herdr plugin install tupton/herdr-worktree-include
```

To link a local checkout while developing the plugin:

```sh
herdr plugin link /path/to/herdr-worktree-include
```

## Usage

Create `.worktreeinclude` in the main checkout and list repository-relative leaf entries:

```text
.env
.env.local
src/django/.env
config/secrets.json
```

Each declaration must also be ignored by Git. Add matching rules to `.gitignore`, `.git/info/exclude`, or the user's global excludes file.

The default mode creates absolute symlinks:

```text
new-worktree/src/django/.env -> main-checkout/src/django/.env
```

The plugin handles only worktrees created after installation. It does not modify existing worktrees.

## Include format

Claude Code defines `.worktreeinclude` as a Git-ignore pattern file. This plugin reads the same file but deliberately supports only a literal leaf subset aimed at environment and configuration leaf entries.

A supported declaration:

- Is a literal path relative to the repository root.
- May begin with one `/`, which this plugin treats as root anchoring.
- Names a regular file or a symlink. Directories and special files are not supported.
- Contains no glob metacharacters, negation, backslash escapes, whitespace, empty components, `.` components, `..` components, or `.git` components.

Blank lines and lines beginning with `#` are ignored. Duplicate declarations are deduplicated, with the first occurrence keeping its position.

These declarations work in both Claude Code and this plugin:

```text
.env
/.env.local
config/secrets.json
```

These are valid for Claude Code but unsupported by this plugin:

```text
.env.*
!example.env
cache/
**/secrets.json
```

The plugin warns and ignores unsupported patterns. This lets one `.worktreeinclude` contain richer rules for Claude Code while this plugin handles only its literal subset.

A slashless declaration has narrower meaning here than it has in Git-ignore syntax. `.env` means only the repository-root `.env`, not every `.env` at any depth. Use the full repository-relative path for nested files.

Missing declarations, tracked leaf entries, and declarations not ignored by normal Git rules are quietly omitted. An existing declaration that names a directory or special file is warned about and skipped.

The plugin reads the complete include file and validates every candidate before it starts installing entries. Selecting `.worktreeinclude` itself is allowed.

## Configuration

Add `.herdr-worktree-include` to the main checkout to select copy mode:

```ini
mode=copy
```

The only supported setting is `mode`, and it may appear once:

- `mode=symlink` creates an absolute link to the leaf in the main checkout. This is the default.
- `mode=copy` copies regular files and preserves source symlinks without following them.

Unsupported keys, including the former `include_file` setting, invalidate the configuration. The plugin warns and installs nothing for that worktree.

If `.worktreeinclude` is missing, the plugin exits without output. If it exists but is not a readable regular file, the plugin warns and installs nothing.

## Symlinks

The final source entry may be a symlink, including a broken symlink or one that resolves to a directory or a path outside the repository. The plugin operates on the symlink itself and does not inspect its target.

An ancestor of the declared leaf may not be a symlink or non-directory. For example, `config/local.env` is rejected if `config` is a symlink.

In symlink mode, selecting a source symlink creates a link to that source path, producing a symlink chain. In copy mode, `cp -P` preserves the source symlink and its original target text.

## Safety

Selection is the intersection of three conditions:

```text
declared literal leaf
AND ignored and untracked in the main checkout
AND free of structural conflicts in both Git indexes
```

The plugin asks Git for ignored, untracked source leaves in one batch. It then reads the main and destination worktree indexes once each immediately before installation.

An entry is rejected with a warning if either index contains:

- The exact path.
- A tracked path below the declared leaf.
- A tracked file, symlink, or gitlink above the declared leaf.

Tracked siblings are allowed. For example, `src/django/.env` remains eligible when Git tracks other files under `src/django`.

Index checks include tracked paths absent from disk, including sparse-checkout and index-only entries. They respect each checkout's `core.ignoreCase` setting.

The plugin never replaces an existing destination file, directory, or symlink. It also refuses to traverse a destination parent that is a symlink or non-directory.

All selection and index checks finish before installation begins. Once installation starts, one failed entry does not prevent later entries from being processed. Completed entries are not rolled back because another process may have changed the destination. A failed copy may leave a partial destination.

The checks narrow race windows but cannot make shell filesystem operations atomic with concurrent index or filesystem changes.

## Testing

Run the integration suite:

```sh
bash tests/integration.sh
```

Run one group by setting `TEST_FILTER` to part of its name:

```sh
TEST_FILTER="tracked siblings" bash tests/integration.sh
```

Run static checks with [ShellCheck](https://www.shellcheck.net/):

```sh
shellcheck --shell=bash src/include.sh tests/integration.sh
```

## Attribution

This plugin was inspired by [hmu332233/herdr-symlink-worktree](https://github.com/hmu332233/herdr-symlink-worktree), an MIT-licensed Bash plugin for linking local files into Herdr worktrees.

## License

MIT. See [LICENSE](./LICENSE).
