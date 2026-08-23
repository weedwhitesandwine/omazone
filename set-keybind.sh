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

# What Hyprland was already unhappy about before this edit. Reverting on "any
# error at all" means one unrelated, pre-existing mistake elsewhere in the
# config makes every rebind here silently undo itself and blame this plugin.
BEFORE="$(hyprctl configerrors 2>/dev/null || true)"

# The marker only proves the toggle command is somewhere in the file, not that
# there is an `o.bind("…")` on that line to rewrite. Count the substitutions,
# so a file that was written some other way is refused rather than reported as
# a success that changed nothing.
CHANGED=$(awk -v marker="$MARKER" -v combo="$NEWCOMBO" '
  index($0, marker) {
    n += sub(/o\.bind\("[^"]*"/, "o.bind(\"" combo "\"")
  }
  { print > tmp }
  END { print n + 0 > "/dev/stderr" }
' tmp="$TMP" "$FILE" 2>&1 >/dev/null) || CHANGED=0

if [ "${CHANGED:-0}" -lt 1 ]; then
  echo "ERROR: found the Omazone line but no o.bind(\"…\") on it to change" >&2
  exit 2
fi
mv -f "$TMP" "$FILE"

# Past this point the file on disk has changed, so every failure has to put it
# back. `set -e` would abort before the revert and the EXIT trap would then
# delete the backup, leaving the config edited, unverified and unrecoverable.
restore() {
  cp "$BACKUP" "$FILE"
  hyprctl reload >/dev/null 2>&1 || true
}

if ! hyprctl reload >/dev/null 2>&1; then
  restore
  echo "ERROR: could not ask Hyprland to reload; the shortcut was put back" >&2
  exit 1
fi

if ! AFTER="$(hyprctl configerrors 2>/dev/null)"; then
  restore
  echo "ERROR: could not read Hyprland's config errors; the shortcut was put back" >&2
  exit 1
fi

if [ -n "$AFTER" ] && [ "$AFTER" != "$BEFORE" ]; then
  restore
  echo "ERROR: $AFTER" >&2
  exit 1
fi

echo "OK: $NEWCOMBO"
