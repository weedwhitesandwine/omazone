#!/usr/bin/env bash
set -euo pipefail

EPOCH="${1:?usage: get-times.sh <epoch> [<iana-zone> ...]}"
shift

# %-I rather than %I: the 12-hour clock is written "2:30 PM", not "02:30 PM",
# which is what the format toggle previews and what the README promises.
FMT='%H:%M|%-I:%M|%p|%Y-%m-%d|%a|%z|%Z'

LOCAL_OUT=$(date -d "@$EPOCH" +"$FMT" 2>/dev/null) || LOCAL_OUT="ERROR"
echo "__local__|$LOCAL_OUT"

for ZONE in "$@"; do
  ZONE_OUT=$(TZ="$ZONE" date -d "@$EPOCH" +"$FMT" 2>/dev/null) || ZONE_OUT="ERROR"
  echo "$ZONE|$ZONE_OUT"
done
