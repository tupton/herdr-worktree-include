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

Create `.worktreeinclude` in the main checkout using `.gitignore` syntax:

```text
.env
.env.*
!.env.example
.turbo/
```

The selected paths must also be ignored by Git. Add matching rules to
`.gitignore`, `.git/info/exclude`, or your global excludes file.

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

`include_file=<path>` adds an include file. The plugin reads existing files in declaration order and combines their patterns into one rule set. Later matching patterns override earlier ones, including across files. Duplicate declarations remain significant.

Every include file's patterns are relative to the repository root, even when the include file is in a subdirectory. This matches Git's treatment of files passed with `--exclude-from`.

Missing include files are optional. If an existing include path is not a readable regular file, selection stops and the plugin installs nothing for that worktree.

If no `include_file` setting is present, the plugin looks for `.worktreeinclude`.

By default, `.worktreeinclude` follows [Claude Code's documented selection contract][cc-worktreeinclude]: it uses `.gitignore` syntax and selects only Git-ignored, untracked paths. Transfer behavior differs. This plugin can symlink instead of copying, installs a directly selected directory as one entry, supports multiple include files, and permits selected symlinks.

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

Include files use [Git's `.gitignore` pattern syntax](https://git-scm.com/docs/gitignore). Git performs the matching.

```text
# Local environments except the committed example
.env*
!.env.example

# Tool state
.cache/**/state.json
.turbo/
```

- Blank lines and unescaped leading `#` characters are comments.
- `!` negates a previous match. The last matching pattern decides.
- `*`, `?`, character classes, `**`, root anchoring with `/`, directory-only patterns ending in `/`, and Git's escaping rules are supported.
- Patterns from all configured include files share one ordered rule set.
- A selected path is installed only when standard Git ignore rules also ignore it. Standard sources include `.gitignore` files, `.git/info/exclude`, and the user's global excludes file.
- Tracked paths are never installed.
- A pattern that matches nothing, or matches only non-ignored paths, produces no warning.

Version 0.4.0 changes the old literal-path behavior. Existing entries still work as literal-looking Git-ignore patterns, but their source paths must now be ignored by Git. For example:

```text
# .gitignore or .git/info/exclude
.env

# .worktreeinclude
.env
```

Git does not traverse source symlinks. A pattern may select an ignored symlink itself, but a pattern below that symlink does not reach its target.

Source paths may be symlinks, including links that resolve outside the main checkout. Review local include files before using them.

### Directories

When a pattern matches an ignored directory itself, the plugin installs that directory once. In `symlink` mode this creates a live link to the main checkout. Files added below the source directory later appear in the worktree without another eligibility check.

A pattern that matches only descendants does not install their parent directory. If a selected directory is not itself Git-ignored, the plugin expands it and installs only descendants that are both selected and ignored.

The plugin rejects a selected directory as a whole if it contains tracked content or a nested Git repository. It does not fall back to individual descendants in either case.

## Safety

The include script avoids replacing an existing destination file, directory, or symlink. It also refuses to traverse a destination parent that is a symlink or not a directory.

Before creating each destination, the plugin compares the selected path with `git ls-files`. It skips the entry if:

- The exact path is tracked.
- A tracked path is below the selected path.
- A tracked file or symlink is an ancestor of the selected path.

The plugin checks the Git index, so tracked paths remain protected even when they are absent from disk, including in sparse checkouts.

The plugin supports regular files, directories, and symlinks. It warns and skips sockets, FIFOs, devices, and other special source types.

Pattern matching and Git-ignore checks finish before installation starts. If Git cannot evaluate the full rule set, the plugin warns and installs nothing. Once installation starts, one failed entry does not prevent other entries from being processed.

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
