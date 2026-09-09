# Orchard

Orchard is an open-source macOS menu bar utility for naming, coloring, and
focusing windows across applications.

## v1

- Discover windows using the public macOS Accessibility API.
- Give any window a custom name and outline color.
- Outline the active labeled window without capturing its contents.
- Focus labeled windows from the menu bar or CLI.
- Persist labels in `~/Library/Application Support/Orchard/`.

Window identity is capability-based, with no app-specific allowlist. Orchard
uses each window's public Accessibility document information when available.
For local documents in Git, it identifies the canonical worktree and its
checked-out branch (or detached HEAD). Opening another file in the same worktree
keeps its tag; switching worktrees or branches in a reused window selects a
different tag. Outside Git, the full document path or URL identifies the context.
Returning to a uniquely identified context restores its saved tag, including
after relaunch.

Windows with no document information, or multiple windows for the same context,
are not restored by title or window-list order. Ambiguous windows receive
runtime-only identities tied to their live Accessibility window. Losing the
document context or changing an unresolved window's title detaches the old tag
rather than guessing. This can also detach tags on routine title changes in apps
that expose no document information. Context changes are detected through title
notifications and polling; changes that an app does not expose through its
document information or title cannot be distinguished.

Older title-based labels remain on disk but must be reapplied once, since their
original document/worktree cannot be recovered safely.

## Privacy

Orchard sends anonymous usage signals through
[TelemetryDeck](https://telemetrydeck.com) for key actions and outcomes.
Window titles, application names, bundle identifiers, and window IDs are never
included in telemetry.

## Install

Download the latest DMG from
[GitHub Releases](https://github.com/ajevans99/orchard/releases), open it, and
drag `Orchard.app` to **Applications** before launching it. Orchard detects
release builds launched from Downloads, a mounted disk image, or another
unstable location and asks you to move the app before granting Accessibility.

After moving the app, run **Install Orchard CLI.command** from the DMG to install
`orchard` at `/usr/local/bin/orchard`. The installer verifies the app and its
agent skill resource are installed first. Alternatively, Homebrew installs both
the app and CLI:

```sh
brew install --cask ajevans99/tap/orchard
```

## Build

Open `Orchard.xcodeproj`, select the **Orchard** scheme and run it on **My Mac**.
On first launch, use Orchard's menu to open System Settings and grant
Accessibility access.

The `OrchardCLI` target builds an executable named `orchard`. Its `skill
install` command reads the versioned skill resource from the sibling app build.
To make both available after building:

```sh
mkdir -p ~/.local/bin
cp ~/Library/Developer/Xcode/DerivedData/Orchard-*/Build/Products/Debug/orchard ~/.local/bin/
ditto ~/Library/Developer/Xcode/DerivedData/Orchard-*/Build/Products/Debug/Orchard.app \
  ~/Applications/Orchard.app
```

Ensure `~/.local/bin` is on your `PATH`.

## Publishing a release

Releases are published from the
[GitHub Releases](https://github.com/ajevans99/orchard/releases) page:

1. Choose **Draft a new release**.
2. Create a version tag such as `v1.0.0`, targeting `main`.
3. Write the release notes and mark test releases as prereleases.
4. Publish the release.

Publishing starts the release workflow at that tag. It builds universal app and
CLI binaries, signs and notarizes them, and uploads both
`Orchard-<tag>-macOS.dmg` and `Orchard-<tag>-macOS.zip` to the existing GitHub
release. The ZIP remains the Homebrew source artifact. Stable releases update
`Casks/orchard.rb` in `ajevans99/homebrew-tap`; prereleases never update
Homebrew.

To test the build without creating a GitHub release, open **Actions → Release → Run
workflow**. Manual runs upload both artifacts to the workflow run instead.
Notarization is enabled by default and can be disabled for a faster build-only
check.

## CLI

```text
orchard list
orchard inspect --current
orchard inspect <window-id> --json
orchard tag --current --title "Agent worktree tagging"
orchard label <window-id> "API debugging"
orchard color <window-id> purple
orchard focus <window-id>
orchard clear <window-id>
orchard skill install
```

`tag --current` is the provider-neutral agent entry point:

```text
orchard tag --current --title <exact-title>
            [--color auto|red|orange|yellow|green|blue|purple|pink]
            [--provider <name>] [--session <opaque-id>]
            [--worktree <path>]
```

The supplied title is displayed exactly, without an Orchard or provider
suffix. `--color` defaults to `auto`. When both provider and session are known,
Orchard deterministically hashes their normalized identity; otherwise it uses
the canonical Git worktree root, falling back to the current directory. The
selected concrete palette color is persisted.

The menu bar app must be running. Current-window tagging reads a fresh Orchard
snapshot and fails rather than guessing when the snapshot is stale, no focused
window exists, or the focused ID is inconsistent. Existing `label`, `color`,
`focus`, and `clear` syntax remains supported. All mutations use Orchard's
serialized command queue, and the app is the sole writer of labels.

## Inspecting window identity

Choose **Inspect** in Orchard's menu to open the **Window Identity** inspector.
It follows the active window by default, so you can leave it open while changing
files, branches, or worktrees in another app. You can also pin a specific window
from its picker. If that identity disappears, the inspector reports it rather
than silently selecting another window.

The inspector shows the native title, current tag/color, Orchard and process
IDs, the document information exposed by Accessibility, the resolved context
and Git HEAD, whether the identity can be restored, and any context-resolution
error. Its latest 10 identity decisions explain preservation, detachment,
restoration, and ambiguous matches. Ordinary polling does not add duplicate
events.

The CLI exposes the same information:

```sh
orchard inspect --current
orchard inspect <window-id>
orchard inspect --current --json
```

`--current` requires fresh, consistent focus, just like tagging. Inspection by
ID can read the last snapshot even after Orchard stops and explicitly marks
stale data. JSON includes the snapshot timestamp, `isStale`, the window record,
and its identity diagnostics. Older app snapshots without diagnostics produce
an explicit update/refresh error.

Diagnostics are local only and never sent in telemetry. They include paths and
titles in Orchard's existing `windows.json` snapshot; review them before sharing
CLI output. The rolling history is scoped to live windows and is not reloaded
after Orchard restarts.

## Agent skill

Install Orchard's bundled, portable Agent Skills document:

```text
orchard skill install [--agent copilot|claude|codex|all]
                      [--scope personal|project] [--force]
```

The defaults are all three agents and personal scope. Personal installs go to
`~/.copilot/skills/orchard-window-tag`, `~/.claude/skills/orchard-window-tag`,
and `~/.agents/skills/orchard-window-tag`. Project installs use the equivalent
`.github/skills`, `.claude/skills`, and `.agents/skills` directories at the Git
root. Installation preflights every selected destination, is an identical-file
no-op, and refuses differing content unless `--force` is supplied.

The skill is maintained as the versioned
`OrchardWindowTagSkill.bundle` resource inside `Orchard.app`; it is not another
application or extension the user opens. The bundle packages the portable
`SKILL.md` and its version metadata for `orchard skill install`. Release command
line tools include a second copy beside the CLI so the command can also run
before Orchard is installed in Applications.

The skill asks Copilot, Claude, or Codex to obtain or set its session title
first and pass that exact title to Orchard. For example:

```sh
orchard tag --current --title "Agent worktree tagging" --provider copilot --session "$KNOWN_SESSION_ID"
orchard tag --current --title "Fix release signing" --provider claude --session "$KNOWN_SESSION_ID"
orchard tag --current --title "Improve queue tests" --provider codex --session "$KNOWN_SESSION_ID"
```

Provider and session arguments should be included only when the environment
exposes real values. Skill activation is agent-driven and therefore best
effort; explicitly invoke the skill when execution must be guaranteed. Re-run
the idempotent tag command if the provider session title changes.

## Extending Orchard

Orchard deliberately uses only public APIs and a small, provider-neutral JSON
contract shared by the app and CLI. The optional agent metadata is open-ended,
so future tools can integrate without provider SDKs, lifecycle hooks, private
session stores, or changes to the core window manager.

## License

MIT
