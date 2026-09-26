#!/usr/bin/env bash
# report.test.sh — the reporter is the one thing here that SENDS somewhere, so
# what this suite pins is what may leave the machine: a label, never a command;
# a redacted title, never a token; and nothing at all when there is nowhere
# authenticated to send it.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
R="$HERE/../report.sh"
r() { bash "$R" "$@" 2>&1; }

fix_live widgets 0
jq '.live = [{
  ticket:"701", title:"A run holding ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAA in its name",
  project:"widgets", startedAgoMin:12, quietSec:30,
  steps:[ {kind:"do", text:"git push --force origin main"},
          {kind:"do", text:"cd /Users/someone/secret-project && npm test"},
          {kind:"do", text:"Run the gates"},
          {kind:"say", text:"The queue order holds."} ]}]' \
  "$FIX/live.json" > "$FIX/l" && mv "$FIX/l" "$FIX/live.json"
printf '1\twidgets\t702\t150\t-\t-\t2026-09-26T00:00:00Z\n' > "$STATE/swarm/queue.tsv"

echo "--- a bare command never leaves the machine ---"
J=$(r --json)
want_not_in "no push command"    'git push' "$J"
want_not_in "no path"            'secret-project' "$J"
want_in "it says so plainly"     'Running a command in its workspace' "$J"
want "both commands replaced"    "2" "$(printf '%s' "$J" | jq '[.live[0].steps[] | select(.text == "Running a command in its workspace")] | length')"

echo "--- a described step keeps its description ---"
want_in "the label survives"     'Run the gates' "$J"
want_in "and so does what it said" 'The queue order holds' "$J"

echo "--- anything token-shaped is replaced ---"
want_not_in "the token is gone"  'ghp_AAAA' "$J"
want_in "and marked"             '\[redacted\]' "$J"

echo "--- the queue travels as numbers, not as briefs ---"
want "one waiting"               "1" "$(printf '%s' "$J" | jq '.queued | length')"
want "named by ticket"           "702" "$(printf '%s' "$J" | jq -r '.queued[0].ticket')"

echo "--- what is stuck comes from the swarm's own logs ---"
printf '%s usage limit — holding until 7:20pm\n' "$(date -u +%FT%TZ)" > "$STATE/logs/scheduler.log"
want_in "the hold is reported"   "usage limit, until 7:20pm" "$(r --json)"
printf '%s STOP #11 (101): 3 repairs in 24h and still CI red\n' "$(swarm_day 2>/dev/null || date -u +%F)T10:00:00Z" > "$STATE/logs/repair-watch.log"
want_in "so is a stopped fix"    "stopped after 3 repairs" "$(r --json)"

echo "--- a live view that cannot be reached is reported, not guessed ---"
fix_live_down
want_in "it says it is blind"    '"kind": "blind"' "$(r --json)"
want "and claims no agents"      "0" "$(r --json | jq '.live | length')"
fix_live widgets 0

echo "--- the screen ---"
out=$(r)
want_in "it counts"              'load [0-9]+ · 0 running · 1 queued' "$out"
want_in "and names what waits"   '#702' "$out"

echo "--- push refuses rather than sending unauthenticated ---"
: > "$FIX/pushed"
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do case "$prev" in --data-binary) printf '%s' "$a" > "$FIX/pushed" ;; esac; prev="$a"; done
[ -f "$FIX/live.json" ] || exit 7
cat "$FIX/live.json"
SH
chmod +x "$BIN/curl"
out=$(SWARM_REPORT_URL=https://example.invalid/api/live r --push; echo "rc=$?")
want_in "it refuses with no secret" 'refusing to push unauthenticated' "$out"
want_in "and fails"                 'rc=1' "$out"
want "nothing was sent"             "0" "$(wc -c < "$FIX/pushed" | tr -d ' ')"

echo "--- with a secret it sends the same shape the screen drew ---"
printf 'hunter2\n' > "$STATE/swarm/report-secret"
SWARM_REPORT_URL=https://example.invalid/api/live r --push >/dev/null
want_not_in "still no command"   'git push' "$(cat "$FIX/pushed")"
want_in "and it is the report"   '"queued"' "$(cat "$FIX/pushed")"

echo "--- no report url: it says so and sends nothing ---"
: > "$FIX/pushed"
out=$(SWARM_REPORT_URL= r --push)
want_in "it says there is nowhere to send" 'nothing to push to' "$out"
want "and sent nothing"          "0" "$(wc -c < "$FIX/pushed" | tr -d ' ')"

exit $FAILED
