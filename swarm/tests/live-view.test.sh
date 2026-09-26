#!/usr/bin/env bash
# live-view.test.sh — the live view is the swarm's only answer to "how many
# agents are running", so the thing to pin is what it counts as running.
#
# The bug this suite exists for: a record whose agent died before it could write
# its .ended marker looked like a running agent forever, and a launcher reported
# eight running with three alive. The marker alone is not the test; the process
# has to still be there.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
# A pid that is certainly alive (this shell) and one that is certainly not.
# Taken BEFORE the cleanup trap is armed, deliberately: in bash 3.2 a background
# job inherits the EXIT trap, so `sleep 30 &` under the trap deletes the fixture
# out from under the suite the moment it is killed — every later case then reads
# an empty directory and the suite reports a machine with no agents as correct.
sleep 30 & DEAD=$!; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
trap 'rm -rf "$FIX"' EXIT
SERVER="$HERE/../live-view/server.mjs"
command -v node >/dev/null 2>&1 || { echo "SKIP live-view: node is not on PATH"; exit 0; }

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
run() { # <ticket> <pid> [ended-exit-code]
  local t=$1 pid=$2
  printf '{"run_id":"claim-%s-a","ticket":"%s","child_pid":%s,"started_at":"%s","budget_usd":150,"log":"%s"}\n' \
    "$t" "$t" "$pid" "$NOW_ISO" "$STATE/logs/claim-$t.log" > "$STATE/runs/claim-$t-a.json"
  [ -n "${3:-}" ] && printf '{"exit_code":%s,"ended_at":"%s"}\n' "$3" "$NOW_ISO" > "$STATE/runs/claim-$t-a.ended"
  : > "$STATE/logs/claim-$t.log"
}
snap() {
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  node --input-type=module -e "
    import { snapshot } from '$SERVER'
    console.log(JSON.stringify(snapshot()))"
}

echo "--- a running agent is live ---"
run 501 "$$"
s=$(snap)
want "one live"            "1" "$(printf '%s' "$s" | jq '.live | length')"
want "and nothing finished" "0" "$(printf '%s' "$s" | jq '.done | length')"
want "it carries its ticket" "501" "$(printf '%s' "$s" | jq -r '.live[0].ticket')"

echo "--- a dead agent with NO marker is not live, and is not finished either ---"
run 502 "$DEAD"
s=$(snap)
want "still one live"      "1" "$(printf '%s' "$s" | jq '.live | length')"
want "502 is not among them" "0" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="502")] | length')"

echo "--- a marker makes it finished, with its exit code ---"
run 503 "$DEAD" 1
s=$(snap)
want "one finished"        "1" "$(printf '%s' "$s" | jq '.done | length')"
want "carrying the code"   "1" "$(printf '%s' "$s" | jq '.done[0].exit')"
want "and read as stopped" "stopped" "$(printf '%s' "$s" | jq -r '.done[0].outcome')"

echo "--- a marker on a LIVE pid still means finished ---"
# The marker wins over the process: an agent that wrote its marker and has not
# yet exited is done, not running.
run 504 "$$" 0
s=$(snap)
want "not live"            "0" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="504")] | length')"
want "finished cleanly"    "success" "$(printf '%s' "$s" | jq -r '.done[] | select(.ticket=="504") | .outcome')"

echo "--- the snapshot is stamped, and names the repo ---"
s=$(snap)
want_in "it has an instant" '^"20[0-9]{2}-[0-9]{2}-[0-9]{2}T' "$(printf '%s' "$s" | jq '.at')"
want "and the repo"        "acme/widgets" "$(printf '%s' "$s" | jq -r '.repo')"

echo "--- steps come out of the agent's own log ---"
cat > "$STATE/logs/claim-501.log" <<'LOG'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Run the gates"}}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"The queue order holds."}]}}
LOG
s=$(snap)
want "two steps"           "2" "$(printf '%s' "$s" | jq '[.live[] | select(.ticket=="501")][0].steps | length')"
want "the command is named" "Run the gates" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[0].text')"
want "and what it said"    "say" "$(printf '%s' "$s" | jq -r '[.live[] | select(.ticket=="501")][0].steps[1].kind')"

echo "--- an unreadable record is skipped, not fatal ---"
printf 'not json\n' > "$STATE/runs/claim-599-a.json"
s=$(snap)
want "the rest still answer" "1" "$(printf '%s' "$s" | jq '.live | length')"

exit $FAILED
