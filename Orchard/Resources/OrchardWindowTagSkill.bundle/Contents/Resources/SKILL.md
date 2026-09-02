---
name: orchard-window-tag
description: Use Orchard to identify the macOS window for the current Copilot, Claude, or Codex work session by tagging it with the exact session title and a deterministic color.
---

<!-- orchard-skill-version: 1.0.0 -->

# Orchard window tagging

Orchard is a macOS window organizer for developers running multiple coding-agent sessions and worktrees at once. It shows a distinct title and colored outline for each tracked window so the user can quickly identify and return to the window that belongs to a particular task.

Tagging keeps the visible Orchard window identity aligned with the provider's session identity. This reduces the risk of reading, typing, or running commands in the wrong agent session or worktree. `--current` deliberately targets the freshly focused window; Orchard rejects missing or stale focus instead of guessing.

Invoke this skill once near the beginning of a work session after the provider session title is known. Skill invocation is agent-driven and best effort; use an explicit invocation when the tag must be applied.

1. Obtain the current provider session title first. If the provider exposes a session-renaming capability and the title is still a placeholder, choose a concise task title and rename the provider session before tagging.
2. Run `orchard tag --current --title "<exact session title>"`. Pass that title exactly, without adding a suffix or provider name.
3. Add `--provider <lowercase-provider> --session <real-opaque-id>` only when both values are explicitly exposed by the environment. Never invent or infer a session ID.
4. Let Orchard discover the worktree and choose `--color auto` unless the user explicitly requests overrides.
5. Re-run the same idempotent command whenever the provider session title changes.
6. Surface any Orchard error. Do not parse `orchard list`, guess a window ID, or silently fall back to another window.

Examples:

```sh
orchard tag --current --title "Agent worktree tagging"
orchard tag --current --title "Agent worktree tagging" --provider copilot --session "$KNOWN_SESSION_ID"
```
