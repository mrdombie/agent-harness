#!/usr/bin/env bash
# status-line.test.sh — the one line at the bottom of every Claude Code window.
#
# What this suite exists for: a status line that reads "no agents working" when
# it simply could not see is worse than no status line at all, because the
# operator reads it as an idle machine and starts more work on a full one. Every
# case below is about that distinction — a missing answer is never nothing.
#
# The second thing it pins is where the cost goes. A statusLine command runs on
# every render, and the parts of this answer measured 170 ms (sourcing the swarm
# env), 95 ms (the live view) and 581 ms (GitHub). So the render path must read a
# cache and nothing else, and the suite asserts GitHub was not called on it.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
trap 'rm -rf "$FIX"' EXIT
SL="$HERE/../status-line.sh"

# The clock every case sits at, so "stale" is a decision and never a race.
# It is REAL now, not a pinned constant: the cache is a real file and its mtime
# is real, so a clock pinned in the past makes every line this suite writes look
# like it came from the future and no staleness case tests anything.
NOW=$(date +%s)
fix_at "$NOW"

# The render path spawns its refresh detached, which a test must not race. Every
# case here drives the paths directly: --print computes and writes the cache,
# --render reads it.
print()  { bash "$SL" --print 2>&1; }
render() { SWARM_STATUS_NO_REFRESH=1 bash "$SL" --render 2>&1; }
cache()  { printf '%s/swarm/status-line.txt' "$STATE"; }
holds()  { printf '%s/swarm/hold-prs.count' "$STATE"; }
# Start a case from nothing cached. Without this the suite shares one hold count
# across every case and reads the FIRST case's answer for the rest of the run —
# which it did, intermittently, depending on whether two cases landed inside the
# same second. The cache is correct in production and wrong as a test premise.
fresh()  { rm -f "$(cache)" "$(holds)"; }
# Both `date`s again: -r is an epoch on BSD and a FILE on GNU, so the fallback
# is not optional — without it a Linux runner ages the cache to "now" and every
# staleness case below passes by testing nothing.
touch_at() { # <epoch> <file>
  local stamp
  stamp=$(date -u -r "$1" +%Y%m%d%H%M.%S 2>/dev/null) || stamp=$(date -u -d "@$1" +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$2"
}
age_cache() { touch_at "$1" "$(cache)"; }

echo "--- the ordinary answer ---"
fresh
fix_live "" 3
printf '[{"number":1},{"number":2}]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want "three agents"      "3 agents working · 2 need you" "$out"

echo "--- one is singular, in both halves ---"
fresh
fix_live "" 1
printf '[{"number":1}]\n' > "$FIX/gh/prs-all.json"
want "one of each"       "1 agent working · 1 needs you" "$(print)"

echo "--- an idle machine says so, and says nothing about approvals ---"
fresh
fix_live "" 0
printf '[]\n' > "$FIX/gh/prs-all.json"
want "nothing running"   "no agents working" "$(print)"

echo "--- THE CASE THIS EXISTS FOR: no answer is not zero ---"
fresh
fix_live_down
printf '[]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want     "the warning, not a count" "swarm view not answering" "$out"
want_not_in "and never 'no agents'" "no agents working" "$out"

echo "--- a stale answer is not an answer either ---"
# The view is up and answering, but its snapshot was taken 20 minutes ago: the
# machine it describes has been through two full scheduler passes since.
fresh
fix_live "" 4
fix_at "$NOW"
jq --arg at "$(swarm_iso $((NOW - 1200)))" '.at = $at' "$FIX/live.json" > "$FIX/live.json.t" && mv "$FIX/live.json.t" "$FIX/live.json"
printf '[{"number":9}]\n' > "$FIX/gh/prs-all.json"
out=$(print)
want_in     "the warning"              "swarm view not answering" "$out"
want_not_in "never the stale count"    "4 agents"                 "$out"
want_in     "approvals still reported" "1 needs you"              "$out"

echo "--- a count GitHub has never given is unknown, not zero ---"
fix_live "" 2
fix_at "$NOW"
rm -f "$STATE/swarm/hold-prs.count"
# A gh that FAILS, which is a different world from a gh that answers zero — the
# fixture's own stub answers zero for a question it has no file for, and zero is
# a real answer. Only the failure is unknown.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh-down"; chmod +x "$BIN/gh-down"
out=$(SWARM_GH="$BIN/gh-down" bash "$SL" --print 2>&1)
want_in     "the agents half still lands" "2 agents working" "$out"
want_in     "and approvals are unknown"   "approvals unknown" "$out"
want_not_in "not silently none"           "needs you"         "$out"

echo "--- the render path reads the cache and calls nothing ---"
fresh
fix_live "" 3
fix_at "$NOW"
printf '[{"number":1},{"number":2}]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
: > "$GH_LOG"
BEFORE=$(cat "$GH_LOG" | wc -l | tr -d ' ')
out=$(render)
want "it prints the cached line" "3 agents working · 2 need you" "$out"
want "GitHub was not asked"     "$BEFORE" "$(cat "$GH_LOG" | wc -l | tr -d ' ')"

echo "--- the hold count is cached too, so a recompute does not re-ask ---"
fresh
fix_live "" 1
printf '[{"number":1},{"number":2},{"number":3}]\n' > "$FIX/gh/prs-all.json"
print >/dev/null
: > "$GH_LOG"
want "second compute agrees"  "1 agent working · 3 need you" "$(print)"
want "and asked GitHub again" "0" "$(grep -c 'pr list' "$GH_LOG" | tr -d ' ')"

echo "--- a cache older than the hard limit is stale, not current ---"
age_cache $((NOW - 3600))
out=$(render)
want_in     "the warning"          "not answering" "$out"
want_not_in "never the old count"  "3 agents"      "$out"

echo "--- a MISSING cache is a cold start, not a stale answer ---"
fresh
fix_live "" 5
printf '[]\n' > "$FIX/gh/prs-all.json"
out=$(render)
want "it computes once, correctly" "5 agents working" "$out"
want "and it wrote the cache"      "5 agents working" "$(cat "$(cache)")"

echo "--- one line, always ---"
fix_live "" 3
fix_at "$NOW"
want "print is one line"  "1" "$(print | wc -l | tr -d ' ')"
want "render is one line" "1" "$(render | wc -l | tr -d ' ')"

echo "--- it names no ticket numbers ---"
fix_live "" 2
fix_at "$NOW"
jq '.live[0].ticket = "10932" | .live[0].title = "Status line in every window"' "$FIX/live.json" > "$FIX/live.json.t" && mv "$FIX/live.json.t" "$FIX/live.json"
out=$(print)
want_not_in "no ticket number" "10932" "$out"
want_not_in "no title"         "Status line" "$out"

echo "--- install writes a statusLine the CLI will run ---"
SETTINGS="$FIX/settings.json"
printf '{"model":"opus"}\n' > "$SETTINGS"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null
want     "type is command"   "command" "$(jq -r '.statusLine.type' "$SETTINGS")"
want_in  "it points at us"   "status-line\.sh"  "$(jq -r '.statusLine.command' "$SETTINGS")"
want     "nothing else lost" "opus" "$(jq -r '.model' "$SETTINGS")"

echo "--- install is idempotent, and uninstall leaves the rest alone ---"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null
want "still one statusLine" "1" "$(jq '[paths|select(.[-1]=="statusLine")]|length' "$SETTINGS")"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --uninstall >/dev/null
want "statusLine gone"      "null" "$(jq -r '.statusLine // "null"' "$SETTINGS")"
want "model kept"           "opus" "$(jq -r '.model' "$SETTINGS")"

echo "--- install refuses to write settings it cannot parse ---"
printf '{oops\n' > "$SETTINGS"
CLAUDE_SETTINGS="$SETTINGS" bash "$SL" --install >/dev/null 2>&1 && bad "it should have refused" || ok "it refused"
want "and left the file alone" "{oops" "$(cat "$SETTINGS")"

exit "$FAILED"
