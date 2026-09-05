# Herdr Worktree Include

Herdr Worktree Include is a [Herdr](https://herdr.dev) plugin that symlinks or copies selected files and directories from a repository's main checkout into worktrees created by Herdr.

Use it for local, git-ignored files that should be available in a new worktree
without being committed, such as environment files, local tool configuration,
and caches.

See [Claude Code's documentation about copying gitignored files into worktrees][cc-worktreeinclude] for background and more details.

## Requirements

- Herdr 0.7.0 or later
- macOS or Linux
- Bash 5.0 or later (macOS ships Bash 3.2; install a current Bash with `brew install bash`)
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

## Quick start

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

The plugin handles only worktrees created after installation. It does not
modify existing worktrees.

## Project configuration

Add `.herdr-worktree-include` to the main checkout to select copy mode or use
additional include files:

```ini
mode=copy
include_file=.worktreeinclude
include_file=.worktreeinclude.local
```

### Supported settings

#### mode

`mode=symlink` links every selected path to the main checkout. This is the default.

`mode=copy` recursively copies every selected path. Source symlinks are preserved rather than followed.

#### `include_file`

`include_file=<path>` adds an include file. The plugin reads existing files in declaration order, combines their entries, and removes duplicates. It ignores missing files, so local include files can be optional. It logs and skips existing paths that are not readable files.

If no `include_file` setting is present, the plugin looks for `.worktreeinclude`.

> [!NOTE]
>
> [Claude Code also uses `.worktreeinclude`][cc-worktreeinclude]. The config for this plugin _does not_ use full `gitignore` syntax. It is a simple list of paths, with no support for globs. See [Include File Format](#include-file-format) below.

[cc-worktreeinclude]: https://code.claude.com/docs/en/worktrees#copy-gitignored-files-into-worktrees

The config format is simple `key=value`. Lines that begin with `#` are ignored.

An unsupported key, duplicate `mode`, invalid mode, or invalid include-file path is invalid configuration. The plugin logs the error, but otherwise does nothing and does not block creation of the worktree.

Multiple `include_file` entries are allowed. This enables a committed `.worktreeinclude` to define project-wide entries while an optional `.worktreeinclude.local` adds personal entries. Keep the local file untracked without changing `.gitignore` by adding it to your local exclude config:

```sh
echo '.worktreeinclude.local' >> .git/info/exclude
```

The project configuration may also be kept local. To use the default include file without committing either configuration file:

```sh
echo '.herdr-worktree-include'  >> .git/info/exclude
echo '.worktreeinclude' >> .git/info/exclude
```

## Include file format

Include files accept one literal repository-relative path per line. Glob patterns, negation, and other `gitignore`-style syntax is _not_ supported.

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
- Duplicate paths are processed once.
- Empty and `.` path components are normalized.
- Absolute paths, `..` components, `.git`, and paths below `.git` are rejected.
- Missing files and paths and invalid entries are logged and skipped independently.

Source paths may be symlinks, including links that resolve outside the main checkout. Review local include files before using them.

## Safety

The include script avoids replacing an existing destination file, directory, or symlink. It also refuses to traverse a destination parent that is a symlink or not a directory.

Before creating each destination, the plugin compares the selected path with `git ls-files`. It skips the entry if:

- The exact path is tracked.
- A tracked path is below the selected path.
- A tracked file or symlink is an ancestor of the selected path.

The plugin checks the Git index, so tracked paths remain protected even when they are absent from disk, including in sparse checkouts.

Copy failures may leave a partial destination behind. The plugin does not remove or otherwise clean up failed destinations because it may have been created or replaced concurrently by another process. Remove an incomplete destination before retrying. Other invalid or conflicting entries do not prevent safe entries from being processed.

## Testing

The integration suite needs the same dependencies as the plugin, including `jq` on your path. Run it with:

```sh
bash tests/integration.sh
```

The tests create temporary Git repositories and linked worktrees, invoke the event handler directly, and remove the temporary data afterward.

For static checks, use [ShellCheck](https://www.shellcheck.net/):

```sh
shellcheck --shell=bash src/include.sh tests/integration.sh
```

## Attribution

This plugin was inspired by [hmu332233/herdr-symlink-worktree](https://github.com/hmu332233/herdr-symlink-worktree), an MIT-licensed Bash plugin for linking local files into Herdr worktrees.

## License

MIT. See [LICENSE](./LICENSE).
