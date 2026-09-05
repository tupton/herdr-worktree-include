# Use Git-ignore semantics for include selection

`.worktreeinclude` uses Git's ignore-pattern syntax so the same file can drive this plugin and Claude Code without carrying two meanings. Selection is the intersection of the ordered include patterns and standard Git ignores: a path must match the include rules, be ignored by Git, and be untracked. This intentionally replaces the plugin's earlier literal-path format; using Git as the matcher avoids a second, subtly different implementation of escaping, negation, anchoring, and `**`.

Directories remain atomic when the include rules and standard ignores both match the directory itself. This preserves directory symlinks, but requires rejecting a selected directory when it contains tracked content, a nested repository, or an unsupported file type. Patterns that select only descendants are expanded instead.
