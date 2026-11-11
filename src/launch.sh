#!/bin/sh
#
# Herdr worktree.created entry point. Finds a Bash 5 interpreter and runs
# include.sh with it.
#
# Herdr runs plugin commands with the Herdr server's PATH. A server started by
# launchd (for example, through `brew services`) gets /usr/bin:/bin:/usr/sbin:/sbin,
# where `bash` is macOS's Bash 3.2. So this searches every PATH directory in
# order, then package manager locations that such a minimal PATH omits. See
# docs/adr/0005-locate-bash-5-with-a-posix-launcher.md.
#
# POSIX sh only, and no external commands: this must run under any /bin/sh,
# with any PATH.

case $0 in
  */*) script_dir=${0%/*} ;;
  *) script_dir=. ;;
esac

# Searched after PATH. This is the only list of these directories: the README
# and ADR 0005 point here. In order: Apple Silicon Homebrew, Intel Homebrew,
# Linuxbrew, MacPorts.
fallback_dirs=/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/opt/local/bin
search_path=${PATH:-}:$fallback_dirs
first_bash=
first_version=

set -f
saved_ifs=$IFS
IFS=:
for dir in $search_path; do
  # Skip empty and relative entries, which would resolve against the working
  # directory.
  case $dir in
    /*) ;;
    *) continue ;;
  esac

  candidate=$dir/bash
  if [ ! -f "$candidate" ] || [ ! -x "$candidate" ]; then
    continue
  fi

  # shellcheck disable=SC2016 # The candidate Bash expands this.
  if "$candidate" -c '[ "${BASH_VERSINFO[0]:-0}" -ge 5 ]' 2>/dev/null; then
    IFS=$saved_ifs
    set +f
    exec "$candidate" "$script_dir/include.sh" "$@"
  fi

  if [ -z "$first_bash" ]; then
    first_bash=$candidate
    # shellcheck disable=SC2016 # The candidate Bash expands this.
    first_version=$("$candidate" -c 'printf %s "${BASH_VERSION:-unknown}"' 2>/dev/null)
  fi
done
IFS=$saved_ifs
set +f

if [ -n "$first_bash" ]; then
  printf 'worktree-include: Bash 5 or newer is required, found %s at %s, skipping\n' \
    "${first_version:-unknown}" "$first_bash" >&2
else
  printf 'worktree-include: Bash 5 or newer is required, none found, skipping\n' >&2
fi
exit 0
