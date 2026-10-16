#!/usr/bin/env bash
# coordinator-feed.test.sh — each kind of coordinator line renders its own row,
# with the tick's own time; the window opens once and only once.
# Then the plant: a kind deleted from the feed falls through to the plain row.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
FAILED=0
F="$HERE/../coordinator-feed.sh"
export NO_COLOR=1

# The coordinator's own lines, as coordinator-tick.sh prints them.
cat > "$FIX/coordinator.out.log" <<'LOG'
10:52:01 tick: did mode, cap 4, config from /tmp/harness.json
10:52:02 ended: claim-12554-a exit 0 — PR: https://example.test/pull/9
10:52:03 live: 3 run(s) [12554 12559 12565]
10:52:04 event: red-pr #12561 PR 12709 — clashes with the integration branch
10:52:05 event: signoff PR 51,52,53,54,55 — a batch of screens is green and waiting on sign-off
10:52:06 spawned #10638 (repair)
10:52:07 spawn: 4 live, cap 4 — no slot
10:52:08 tick: done
skip #12621 (repair): needs:human-approval
LOG
out=$(bash "$F" --render < "$FIX/coordinator.out.log")
line() { printf '%s\n' "$out" | grep -F -- "$1" | head -1; }
want "check started"   "10:52:01 ── check started"                                  "$(line '10:52:01')"
want "a build ended"   "10:52:02 ■ finished claim-12554-a exit 0 — PR: https://example.test/pull/9" "$(line '10:52:02')"
want "what is building" "10:52:03 ● building 3 run(s) [12554 12559 12565]"          "$(line '10:52:03')"
want "a red PR"        "10:52:04 ▲ red #12561 PR 12709 — clashes with the integration branch" "$(line '10:52:04')"
want "sign-offs ready" "10:52:05 ★ for you sign-offs ready: PR 51,52,53,54,55 — a batch of screens is green and waiting on sign-off" "$(line '10:52:05')"
want "a build started" "10:52:06 ▶ started #10638 (repair)"                         "$(line '10:52:06')"
want "why nothing started" "10:52:07 ‖ not starting: 4 live, cap 4 — no slot"       "$(line '10:52:07')"
want "check done"      "10:52:08 ── check done, next in 5 min"                       "$(line '10:52:08')"
want_in "an unstamped line still renders" '^ +skip #12621' "$(line 'skip #12621')"
want "nine lines, nine rows" "9" "$(printf '%s\n' "$out" | grep -c .)"

echo "--- the window opens once ---"
cat > "$BIN/opener" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/opened.log"
SH
chmod +x "$BIN/opener"
SWARM_FEED_OPENER="$BIN/opener" bash "$F" --open-once >/dev/null 2>&1
SWARM_FEED_OPENER="$BIN/opener" bash "$F" --open-once >/dev/null 2>&1
want "opened once, not twice" "1" "$(grep -c . "$FIX/opened.log" 2>/dev/null || echo 0)"
want_in "it follows the coordinator's log" "--log $STATE/logs/coordinator.out.log" "$(cat "$FIX/opened.log" 2>/dev/null)"

echo "--- plant: the red row deleted falls through to the plain row ---"
P="$FIX/kit"; mkdir -p "$P"; cp -R "$HERE/../../swarm" "$HERE/../../scripts" "$P/"
python3 - "$P/swarm/coordinator-feed.sh" <<'PY' || bad "plant did not land"
import sys
p = sys.argv[1]; s = open(p).read()
lines = [l for l in s.split("\n") if not l.lstrip().startswith('"event: red-pr"*)')]
if len(lines) != s.count("\n"): sys.exit(1)
open(p, "w").write("\n".join(lines))
PY
grep -q '"event: red-pr"' "$P/swarm/coordinator-feed.sh" && bad "plant: the red row is still in the copy"
pout=$(bash "$P/swarm/coordinator-feed.sh" --render < "$FIX/coordinator.out.log" | grep -F '10:52:04')
[ "$pout" = "10:52:04 ▲ red #12561 PR 12709 — clashes with the integration branch" ] \
  && bad "planted: the red row deleted and it still renders → the test cannot see it" \
  || ok "planted: the red row deleted → '$pout' → red"

exit $FAILED
