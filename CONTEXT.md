# Worktree Include

Worktree Include selects local repository content that should be available in a newly created worktree without adding that content to Git.

## Language

**Include declaration**:
A repository-relative literal path declared in `.worktreeinclude`. It identifies one leaf entry in the main checkout.
_Avoid_: Include pattern

**Eligible leaf entry**:
A leaf entry named by an include declaration that standard Git ignore rules ignore. Its repository-relative path is not the same as, below, or above a path tracked in either the main checkout or the newly created worktree.
_Avoid_: Selected path, eligible path

**Leaf entry**:
A repository-relative source item that is either a regular file or a symlink. A symlink is the entry itself, regardless of its target.
_Avoid_: File, directory, installable entry
