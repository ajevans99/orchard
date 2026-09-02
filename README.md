# Orchard

Orchard is an open-source macOS menu bar utility for naming, coloring, and
focusing windows across applications.

## v1

- Discover windows using the public macOS Accessibility API.
- Give any window a custom name and outline color.
- Outline the active labeled window without capturing its contents.
- Focus labeled windows from the menu bar or CLI.
- Persist labels in `~/Library/Application Support/Orchard/`.

Orchard identifies a window from its application bundle ID and native title.
Already-tracked Accessibility windows keep their runtime identity when the
native title changes. Across Orchard relaunches, apps that frequently rewrite
window titles may still receive a new identity.

## Install

Tagged releases contain a signed and notarized universal build of `Orchard.app`
and the `orchard` CLI. Download the latest archive from
[GitHub Releases](https://github.com/ajevans99/orchard/releases), or install
both through Homebrew:

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

Create the `ajevans99/homebrew-tap` repository and add these GitHub Actions
secrets to this repository:

- `APPLE_TEAM_ID`
- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY`
- `HOMEBREW_TAP_TOKEN` with write access to `ajevans99/homebrew-tap`

Push a version tag such as `v1.0` to build, sign, notarize, and publish the
release. When `HOMEBREW_TAP_TOKEN` is configured, the workflow also updates the
tap's `Casks/orchard.rb`.

## CLI

```text
orchard list
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
`OrchardWindowTagSkill.bundle` resource inside `Orchard.app`; it is not embedded
in Swift source. `orchard skill install` reports the bundled skill version it
installs. Releases also place the resource bundle beside the CLI so skill
installation works before the app is moved to `/Applications`.

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
