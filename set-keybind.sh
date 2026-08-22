#!/usr/bin/env bash
set -euo pipefail

NEWCOMBO="${1:?usage: set-keybind.sh \"SUPER + X\"}"

# This value is substituted into bindings.lua inside a Lua string, so it is
# checked here as well as in the panel. A hotkey is one or more modifiers then a
# single key, and nothing else; anything that does not match that shape is
# refused rather than escaped, because there is no reason for it to exist.
if ! [[ $NEWCOMBO =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2]))$ ]]; then
  echo "ERROR: refusing a hotkey that is not modifiers plus one key: $NEWCOMBO" >&2
  exit 2
fi
FILE="$HOME/.config/hypr/bindings.lua"
MARKER='omarchy-shell shell toggle io.github.weedwhitesandwine.omazone'

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 2
fi

if ! grep -qF "$MARKER" "$FILE"; then
  echo "ERROR: Omazone keybind line not found in $FILE" >&2
  exit 2
fi

BACKUP="$FILE.bak.$(date +%s)"
cp "$FILE" "$BACKUP"

awk -v marker="$MARKER" -v combo="$NEWCOMBO" '
  index($0, marker) {
    sub(/o\.bind\("[^"]*"/, "o.bind(\"" combo "\"")
  }
  { print }
' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

hyprctl reload >/dev/null

ERRS="$(hyprctl configerrors)"
if [ -n "$ERRS" ]; then
  cp "$BACKUP" "$FILE"
  hyprctl reload >/dev/null
  echo "ERROR: $ERRS" >&2
  exit 1
fi

echo "OK: $NEWCOMBO"
