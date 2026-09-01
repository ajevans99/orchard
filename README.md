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
