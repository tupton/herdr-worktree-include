# Worktree Include

Worktree Include selects local repository content that should be available in a newly created worktree without adding that content to Git.

## Language

**Include pattern**:
A Git-ignore pattern read from an ordered include file.

**Selected path**:
A source path selected by the combined include patterns after Git applies last-match-wins ordering.

**Eligible path**:
A selected path that standard Git ignore rules also ignore and that Git does not track.

**Installable entry**:
An eligible file, symlink, or atomic directory that passes the plugin's safety checks.
