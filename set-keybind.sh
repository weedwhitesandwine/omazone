#!/usr/bin/env bash
set -euo pipefail

NEWCOMBO="${1:?usage: set-keybind.sh \"SUPER + X\"}"

# This value is substituted into bindings.lua inside a Lua string, so it is
# checked here as well as in the panel. A hotkey is one or more modifiers then a
# single key, and nothing else; anything that does not match that shape is
# refused rather than escaped, because there is no reason for it to exist.
if ! [[ $NEWCOMBO =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$ ]]; then
  echo "ERROR: refusing a hotkey that is not modifiers plus one key: $NEWCOMBO" >&2
  exit 2
fi
FILE="$HOME/.config/hypr/bindings.lua"
MARKER='omarchy-shell shell toggle io.github.weedwhitesandwine.omazone'

# Refuse to work through a symlink at bindings.lua before reading it: an edit
# that followed one would read and then rewrite whatever it pointed at.
if [ -L "$FILE" ]; then
  echo "ERROR: $FILE is a symlink; refusing to edit it" >&2
  exit 2
fi

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found" >&2
  exit 2
fi

if ! grep -qF "$MARKER" "$FILE"; then
  echo "ERROR: Omazone keybind line not found in $FILE" >&2
  exit 2
fi

# The backup and the staged edit both live in the same directory as the
# config, under unpredictable names created exclusively by mktemp (never
# following a symlink), so nothing can have been planted at either name, and
# the rename that swaps the edit in is a single atomic step on the same
# filesystem.
DIR=$(dirname "$FILE")
BACKUP=$(mktemp "$DIR/.bindings.bak.XXXXXXXX")
TMP=$(mktemp "$DIR/.bindings.tmp.XXXXXXXX")
trap 'rm -f "$BACKUP" "$TMP"' EXIT
cp "$FILE" "$BACKUP"
chmod --reference="$FILE" "$TMP" 2>/dev/null || true

awk -v marker="$MARKER" -v combo="$NEWCOMBO" '
  index($0, marker) {
    sub(/o\.bind\("[^"]*"/, "o.bind(\"" combo "\"")
  }
  { print }
' "$FILE" > "$TMP" && mv -f "$TMP" "$FILE"

hyprctl reload >/dev/null

ERRS="$(hyprctl configerrors)"
if [ -n "$ERRS" ]; then
  cp "$BACKUP" "$FILE"
  hyprctl reload >/dev/null
  echo "ERROR: $ERRS" >&2
  exit 1
fi

echo "OK: $NEWCOMBO"
