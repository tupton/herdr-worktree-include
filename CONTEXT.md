# Worktree Include

Worktree Include selects local repository content that should be available in a newly created worktree without adding that content to Git.

## Language

**Include declaration**:
A repository-relative literal path declared in `.worktreeinclude`. It identifies one leaf entry in the main checkout.
_Avoid_: Include pattern

**Eligible leaf entry**:
A declared leaf entry that standard Git ignore rules ignore and that Git does not track in either relevant checkout.
_Avoid_: Selected path, eligible path

**Leaf entry**:
A repository-relative source item that is either a regular file or a symlink. A symlink is the entry itself, regardless of its target.
_Avoid_: File, directory, installable entry
