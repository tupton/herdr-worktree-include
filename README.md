# Herdr Worktree Include

[Herdr](https://herdr.dev) plugin that links or copies selected files from a repository's main checkout into new linked worktrees. Use it for ignored environment and configuration files that should be present in every worktree without being committed.

## Requirements

- Herdr 0.7.0 or later
- macOS or Linux
- Bash 5.0 or later
- Git
- `jq`

macOS includes Bash 3.2. Install a current version with `brew install bash` and put it before `/bin/bash` on `PATH`.

## Installation

```sh
herdr plugin install tupton/herdr-worktree-include
```

For a local checkout:

```sh
herdr plugin link /path/to/herdr-worktree-include
```

## Usage

Create `.worktreeinclude` in the main checkout. List repository-relative file paths:

```text
.env
.env.local
src/django/.env
config/secrets.json
```

Each path must also be ignored by Git. Add matching rules to `.gitignore`, `.git/info/exclude`, or the global excludes file.

The default mode creates absolute symlinks:

```text
new-worktree/src/django/.env -> main-checkout/src/django/.env
```

The plugin processes worktrees created after installation. It does not change existing worktrees.

## Include format

Claude Code treats `.worktreeinclude` as a Git-ignore pattern file. This plugin reads the same file but accepts literal leaf paths only. Leaf paths are those that point to regular files or symlinks, not directories.

A supported declaration of a leaf path:

- Is a literal path relative to the repository root.
- May start with one `/`, which anchors it at the root.
- Names a regular file or symlink, not a directory or special file.
- Has no glob characters, negation, backslash escapes, whitespace, empty components, `.`, `..`, or `.git` components.

Blank lines and lines beginning with `#` are ignored. Duplicate declarations are removed, with the first occurrence keeping its position.

These declarations work in both Claude Code and this plugin:

```text
.env
/.env.local
config/secrets.json
```

These work in Claude Code but not in this plugin:

```text
.env.*
!example.env
cache/
**/secrets.json
```

The plugin warns about and ignores unsupported patterns. One `.worktreeinclude` file can therefore contain richer Claude Code rules alongside the literal paths this plugin uses.

Here, `.env` means only the repository-root `.env`. It does not match `.env` in nested directories. Use the full repository-relative path for nested files.

Missing declarations, declarations that Git does not ignore, and exact source paths already tracked in the main checkout are omitted without a warning. A destination-only tracked path or a declaration above or below a tracked path produces a warning. Existing directories and special files also produce a warning and are skipped.

The plugin validates every declaration before installing anything. Selecting `.worktreeinclude` itself is allowed.

## Configuration

Add `.herdr-worktree-include` to the main checkout to use copy mode:

```ini
mode=copy
```

`mode` is the only supported setting, and it may appear once:

- `mode=symlink` creates an absolute link to the file in the main checkout. This is the default.
- `mode=copy` copies regular files and preserves source symlinks without following them.

An unsupported key, including the former `include_file` setting, invalidates the configuration. The plugin warns and installs nothing for that worktree.

If `.worktreeinclude` is missing, the plugin exits silently. If it is not a readable regular file, the plugin warns and installs nothing.

## Symlinks

The declared leaf may be a symlink, including a broken symlink or one that points to a directory or outside the repository. The plugin uses the symlink itself and does not inspect its target.

An ancestor of the declared leaf must be a directory, not a symlink. For example, the plugin rejects `config/local.env` when `config` is a symlink.

In symlink mode, a source symlink produces a symlink chain: a symlink in the new worktree points to the source symlink rather than to its target. In copy mode, `cp -P` preserves the source symlink and its original target text.

## Safety

The plugin selects a path only when all three conditions hold:

```text
declared literal leaf
AND ignored and untracked in the main checkout
AND free of structural conflicts in both Git indexes
```

It asks Git for ignored, untracked source leaves in one batch, then reads the main and destination worktree indexes once each immediately before installation.

After Git omits exact source paths it already tracks, the plugin rejects a remaining entry with a warning if either index contains:

- The exact path.
- A tracked path below the declared leaf.
- A tracked file, symlink, or gitlink above the declared leaf.

Tracked siblings are allowed. E.g. `src/.env` remains eligible when Git tracks other files under `src/`.

Index checks include tracked paths absent from disk, including sparse-checkout and index-only entries. They respect each checkout's `core.ignoreCase` setting.

The plugin never replaces an existing destination file, directory, or symlink. It also refuses to traverse a destination parent that is a symlink or non-directory.

The plugin completes selection and index checks before installation. After installation starts, a failed entry does not stop later entries. It does not roll back completed entries, since another process may have changed the destination. A failed copy may leave a partial destination.

These checks reduce race windows. They cannot make shell filesystem operations atomic with concurrent index or filesystem changes.

## Testing

Run the integration suite:

```sh
bash tests/integration.sh
```

Selection and tracked-conflict policy tests source `src/include.sh` and exercise their respective internal module interfaces. Installation and event-handling tests execute the script through the same process interface Herdr uses.

Run one group by setting `TEST_FILTER` to part of its name:

```sh
TEST_FILTER="tracked siblings" bash tests/integration.sh
```

Run static checks with [ShellCheck](https://www.shellcheck.net/):

```sh
shellcheck --shell=bash src/include.sh tests/integration.sh
```

## Attribution

Inspired by [hmu332233/herdr-symlink-worktree](https://github.com/hmu332233/herdr-symlink-worktree), an MIT-licensed Bash plugin for linking local files into Herdr worktrees.

## License

MIT. See [LICENSE](./LICENSE).
