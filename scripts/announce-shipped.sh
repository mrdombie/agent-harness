#!/usr/bin/env bash
# Announce a merged ticket so the operator cannot miss it: a big banner on stdout
# (the caller pastes it into its reply) plus a desktop notification with a sound.
# Usage: announce-shipped.sh <ticket> "<title>" [<pr-url>]
set -uo pipefail

TICKET="${1:?usage: announce-shipped.sh <ticket> \"<title>\" [<pr-url>]}"
TITLE="${2:?usage: announce-shipped.sh <ticket> \"<title>\" [<pr-url>]}"
URL="${3:-}"
TICKET="${TICKET#\#}"

cat <<'ART'
 ██████╗  ██████╗ ███╗   ██╗███████╗
 ██╔══██╗██╔═══██╗████╗  ██║██╔════╝
 ██║  ██║██║   ██║██╔██╗ ██║█████╗
 ██║  ██║██║   ██║██║╚██╗██║██╔══╝
 ██████╔╝╚██████╔╝██║ ╚████║███████╗
 ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝╚══════╝
ART
echo " ════════════════════════════════════"
echo "  ✅ TICKET #$TICKET COMPLETED"
echo "  $TITLE"
[ -n "$URL" ] && echo "  $URL"
echo " ════════════════════════════════════"

# osascript string literals take no escapes we control, so strip the quote characters.
if command -v osascript >/dev/null 2>&1; then
  SAFE=$(printf '%s' "$TITLE" | tr -d '"\\')
  osascript -e "display notification \"$SAFE\" with title \"✅ Ticket #$TICKET completed\"" >/dev/null 2>&1 || true
fi
# Played directly: a notification's own sound is muted by per-app notification settings.
SOUND=/System/Library/Sounds/Glass.aiff
if command -v afplay >/dev/null 2>&1 && [ -f "$SOUND" ]; then
  afplay "$SOUND" >/dev/null 2>&1 &
fi
exit 0
