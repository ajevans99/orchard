#!/bin/zsh

set -euo pipefail

SCRIPT_DIRECTORY="${0:A:h}"
SOURCE="$SCRIPT_DIRECTORY/Command Line Tools/orchard"
DESTINATION="/usr/local/bin/orchard"

if [[ -d "/Applications/Orchard.app" ]]; then
  APP="/Applications/Orchard.app"
elif [[ -d "$HOME/Applications/Orchard.app" ]]; then
  APP="$HOME/Applications/Orchard.app"
else
  echo "Move Orchard.app to Applications before installing the CLI." >&2
  read "reply?Press Return to close."
  exit 1
fi

if [[ ! -f "$APP/Contents/Resources/OrchardWindowTagSkill.bundle/Contents/Resources/SKILL.md" ]]; then
  echo "The installed Orchard app is missing its agent skill resource." >&2
  read "reply?Press Return to close."
  exit 1
fi

if [[ ! -x "$SOURCE" ]]; then
  echo "The Orchard CLI was not found next to this installer." >&2
  read "reply?Press Return to close."
  exit 1
fi

echo "Installing the Orchard CLI at $DESTINATION"
/usr/bin/sudo /bin/mkdir -p /usr/local/bin
/usr/bin/sudo /usr/bin/install -m 755 "$SOURCE" "$DESTINATION"

echo
echo "Installed successfully. Open a new terminal and run:"
echo "  orchard --help"
echo
read "reply?Press Return to close."
