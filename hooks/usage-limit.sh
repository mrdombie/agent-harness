#!/usr/bin/env bash
# StopFailure (matcher rate_limit) — write down when the plan's usage limit resets.
#
# WHY: on 2026-10-14 agents died at "You've hit your session limit · resets
# 2:40am" and nothing resumed them; the window that owned them had hit the same
# wall, so its turn ended and no reply could record anything. Claude Code fires
# StopFailure INSTEAD of Stop when an API error ended the turn — fire-and-forget,
# output and exit code ignored — so a hook is the only thing still running.
#
# It records the reset in $STATE_DIR/usage-hold (`<epoch>\t<text>`). The limit is
# account-wide, so the coordinator tick and the scheduler read the same file
# (swarm_usage_hold in swarm/swarm-env.sh) and spawn nothing until it passes.
#
# Always exits 0: it can change nothing about the turn, only leave a note.
#
#   usage-limit.sh --reset-epoch "<text>"   print the reset a limit message names
set -u
. "$(dirname "$0")/lib/python.sh" || exit 0
LOG=/tmp/claude-usage-limit.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }
now() { printf '%s' "${USAGE_LIMIT_NOW:-$(date +%s)}"; }

# The wording, measured on this machine's transcripts (2026-10-15):
#   You've hit your session limit · resets 2:40am (Europe/London)
# and, in swarm logs, "resets Sep 29 at 9pm (Europe/London)" and a structured
# "resetsAt":<epoch>. The epoch is exact and wins. A wall that names no time at all
# is held for an hour, rather than read as no wall.
reset_epoch() { # <text>
  harness_python || { echo $(( $(now) + 3600 )); return 0; }
  NOW="$(now)" "${HARNESS_PY[@]}" - "$1" <<'PY'
import os, re, sys, datetime as dt
t = sys.argv[1]; now = int(os.environ["NOW"])
m = re.search(r'"resetsAt"\s*:\s*(\d{9,})', t)
if m:
    print(int(m.group(1))); sys.exit(0)
m = re.search(r'resets (?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?: \(([^)]+)\))?', t)
if not m:
    if re.search(r"hit your [a-z ]*limit|rate_limit|HTTP 429|usage limit", t, re.I):
        print(now + 3600); sys.exit(0)
    sys.exit(1)
mon, day, h, mi, ap, tz = m.groups()
h = int(h) % 12 + (12 if ap == "pm" else 0); mi = int(mi or 0)
try:
    from zoneinfo import ZoneInfo
    zone = ZoneInfo(tz) if tz else None
except Exception:
    zone = None
base = dt.datetime.fromtimestamp(now, zone) if zone else dt.datetime.fromtimestamp(now)
if mon:
    month = dt.datetime.strptime(mon, "%b").month
    cand = base.replace(month=month, day=int(day), hour=h, minute=mi, second=0, microsecond=0)
    # Only a year boundary rolls forward (read Dec 30, "resets Jan 2").
    if cand.timestamp() < now - 180 * 86400:
        cand = cand.replace(year=cand.year + 1)
else:
    cand = base.replace(hour=h, minute=mi, second=0, microsecond=0)
    if cand.timestamp() <= now:
        cand += dt.timedelta(days=1)
print(int(cand.timestamp()))
PY
}

if [ "${1:-}" = "--reset-epoch" ]; then reset_epoch "${2:-}"; exit $?; fi

IN=$(cat)
ERR=$(printf '%s' "$IN" | jq -r '.error // ""' 2>/dev/null)
[ "$ERR" = rate_limit ] || { say "skip error=${ERR:-none}"; exit 0; }

# The state dir the way keep-working.sh finds it: hooks run outside any checkout.
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
_cs=""; [ -f "$_cfg" ] && _cs=$(jq -r '.stateDir // ""' "$_cfg" 2>/dev/null)
SD="${HARNESS_STATE_DIR:-$_cs}"
[ -n "$SD" ] || SD=$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null || true)
SD="${SD/#\~/$HOME}"
[ -n "$SD" ] || { say "skip no-state-dir"; exit 0; }
mkdir -p "$SD" 2>/dev/null || { say "skip state-dir-unwritable $SD"; exit 0; }

# The failure's own words only: the last message counts when it IS the CLI's
# one-line notice, never when a reply quotes one (a CI log read back, say).
TEXT=$(printf '%s' "$IN" | jq -r '.error_details // "" | tostring' 2>/dev/null)
LAST=$(printf '%s' "$IN" | jq -r '.last_assistant_message // "" | tostring' 2>/dev/null)
NOTICE="^[[:space:]]*You('ve| have) hit your [a-z ]*limit( · resets [^·]{1,60})?[[:space:]]*\$"
case "$LAST" in *$'\n'*) LAST="" ;; esac
[[ "$LAST" =~ $NOTICE ]] && TEXT="$TEXT $LAST"
[ -n "${TEXT// /}" ] || TEXT="hit your usage limit"
E=$(reset_epoch "$TEXT") || { say "error=$ERR no reset in text"; exit 0; }
HOLD_F="$SD/usage-hold"
# Keep the LATER of two walls: a weekly wall outlasts the session wall that hit first.
CUR=$(cut -f1 "$HOLD_F" 2>/dev/null); case "$CUR" in ''|*[!0-9]*) CUR=0 ;; esac
if [ "$E" -gt "$CUR" ]; then
  printf '%s\t%s\n' "$E" "$(printf '%s' "$TEXT" | tr '\n\t' '  ' | cut -c1-200)" > "$HOLD_F"
fi
say "error=$ERR hold $(cut -f1 "$HOLD_F" 2>/dev/null) in $HOLD_F"
exit 0
