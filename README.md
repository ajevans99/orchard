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
That keeps labels across relaunches, but apps that frequently rewrite their
window titles may receive a new identity.

## Privacy

Orchard sends anonymous usage signals through
[TelemetryDeck](https://telemetrydeck.com) for key actions and outcomes.
Window titles, application names, bundle identifiers, and window IDs are never
included in telemetry.

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

The `OrchardCLI` target builds an executable named `orchard`. To make it
available in your shell after building:

```sh
mkdir -p ~/.local/bin
cp ~/Library/Developer/Xcode/DerivedData/Orchard-*/Build/Products/Debug/orchard ~/.local/bin/
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
orchard label <window-id> "API debugging"
orchard color <window-id> purple
orchard focus <window-id>
orchard clear <window-id>
```

The menu bar app must be running for window discovery and focus requests.

## Extending Orchard

The first release deliberately uses only public APIs and a small JSON contract
between the app and CLI. Future adapters can enrich window metadata from tools
such as Xcode and VS Code without coupling the core window manager to them.

## License

MIT
