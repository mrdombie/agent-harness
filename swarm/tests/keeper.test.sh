#!/usr/bin/env bash
# keeper.test.sh — the keeper resumes the kept session only when nothing else
# keeps it: a fresh transcript or a live claude holding it means no run, a quiet
# one means exactly one run, and a usage hold, a hold or a running pass mean none.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"; [ -n "${SLEEPER:-}" ] && kill "$SLEEPER" 2>/dev/null' EXIT
K="$HERE/../keeper.sh"
ID=11111111-2222-3333-4444-555555555555
WORK="$FIX/work dir"; mkdir -p "$WORK"
export KEEPER_PROJECTS_DIR="$FIX/projects" KEEPER_SESSIONS_DIR="$FIX/sessions"
export KEEPER_CLAUDE="$BIN/claude" KEEPER_PS_FILE="$FIX/ps.txt" SWARM_USAGE_HOLD_FILE="$FIX/usage-hold"
mkdir -p "$KEEPER_SESSIONS_DIR" "$KEEPER_PROJECTS_DIR/$(printf '%s' "$WORK" | sed 's/[^A-Za-z0-9]/-/g')"
TR="$KEEPER_PROJECTS_DIR/$(printf '%s' "$WORK" | sed 's/[^A-Za-z0-9]/-/g')/$ID.jsonl"
CALLS="$FIX/claude-calls"
cat > "$BIN/claude" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$CALLS"
sleep "${STUB_SLEEP:-0}"
SH
chmod +x "$BIN/claude"; export CALLS
KLOG="$STATE/coordinator/keeper.log"
NOW=$(date +%s)
reset() { rm -f "$CALLS" "$KLOG" "$SWARM_USAGE_HOLD_FILE" "$KEEPER_SESSIONS_DIR"/*.json; rm -rf "$STATE/coordinator/keeper.lock"; : > "$KEEPER_PS_FILE"; touch "$TR"; }
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
last() { tail -1 "$KLOG" 2>/dev/null | cut -f2; }
pass() { SWARM_NOW="${1:-$NOW}" bash "$K" >/dev/null 2>&1; }
STALE=$(( NOW + 3 * 3600 ))

echo "--- nothing adopted: nothing happens ---"
reset; pass "$STALE"
want "no claude run"      "0" "$(calls)"
want "and no decision"    "no" "$([ -f "$KLOG" ] && echo yes || echo no)"

echo "--- adopt ---"
printf '{"pid":4242,"sessionId":"%s","cwd":"%s"}\n' "$ID" "$WORK" > "$KEEPER_SESSIONS_DIR/4242.json"
bash "$K" adopt "$ID" >/dev/null 2>&1
want "it keeps the session"              "$ID" "$(jq -r .session "$STATE/coordinator/keeper.json")"
want "in the cwd its registry names"     "$WORK" "$(jq -r .cwd "$STATE/coordinator/keeper.json")"
want_in "with the coordinator-tab prompt" "You are the coordinator tab" "$(jq -r .prompt "$STATE/coordinator/keeper.json")"
bash "$K" adopt 'not an id; rm -rf /' >/dev/null 2>&1; rc=$?
want "a non-id is refused"               "2" "$rc"
want "and the kept session is unchanged" "$ID" "$(jq -r .session "$STATE/coordinator/keeper.json")"

echo "--- a fresh transcript: alive, no run ---"
reset; pass "$NOW"
want "no claude run"   "0" "$(calls)"
want "decision: alive" "alive" "$(last)"

echo "--- a quiet transcript, no process: exactly one resume ---"
reset; pass "$STALE"
want "one claude run"                "1" "$(calls)"
want "decision: revived"             "revived" "$(last)"
want "from the session's cwd"        "$WORK" "$(cut -d'|' -f1 "$CALLS")"
want_in "a headless resume of it"    "^-p --resume $ID --permission-mode auto You are the coordinator tab" "$(cut -d'|' -f2 "$CALLS")"
want_not_in "never a work loop"      "/loop|/agent-harness:(work|auto)" "$(cat "$CALLS")"
want "the lock is released after"    "no" "$([ -d "$STATE/coordinator/keeper.lock" ] && echo yes || echo no)"

echo "--- a quiet transcript, but a live claude holds it ---"
reset
printf '{"pid":4242,"sessionId":"%s","cwd":"%s"}\n' "$ID" "$WORK" > "$KEEPER_SESSIONS_DIR/4242.json"
printf '4242 /Applications/x/native-binary/claude --output-format stream-json\n' > "$KEEPER_PS_FILE"
pass "$STALE"
want "registered and running: no run" "0" "$(calls)"
want "decision: alive"                "alive" "$(last)"
reset
printf '{"pid":4242,"sessionId":"%s","cwd":"%s"}\n' "$ID" "$WORK" > "$KEEPER_SESSIONS_DIR/4242.json"
pass "$STALE"
want "a registry entry whose pid is gone holds nothing" "1" "$(calls)"
reset
printf '777 /opt/homebrew/bin/claude --resume %s\n' "$ID" > "$KEEPER_PS_FILE"
pass "$STALE"
want "a claude carrying the id in its args: no run" "0" "$(calls)"
reset
printf '777 /bin/bash keeper-notes %s\n' "$ID" > "$KEEPER_PS_FILE"
pass "$STALE"
want "the id in a process that is not claude holds nothing" "1" "$(calls)"

echo "--- over the usage ceiling: skipped ---"
reset; printf '%s\tweekly wall\n' $(( STALE + 3600 )) > "$SWARM_USAGE_HOLD_FILE"
pass "$STALE"
want "no claude run"            "0" "$(calls)"
want "decision: skipped: usage" "skipped: usage" "$(last)"

echo "--- the swarm held: skipped ---"
reset; echo "owner stopped it" > "$STATE/swarm/HOLD"
pass "$STALE"
want "no claude run"           "0" "$(calls)"
want "decision: skipped: held" "skipped: held" "$(last)"
rm -f "$STATE/swarm/HOLD"

echo "--- two passes at once: one run, the other locked out ---"
reset
STUB_SLEEP=2 SWARM_NOW=$STALE bash "$K" >/dev/null 2>&1 & a=$!
sleep 0.5
STUB_SLEEP=2 SWARM_NOW=$STALE bash "$K" >/dev/null 2>&1 & b=$!
wait $a $b
want "exactly one claude run"    "1" "$(calls)"
want "one pass was locked out"   "1" "$(grep -c $'\tskipped: locked\t' "$KLOG")"
reset; sleep 30 & SLEEPER=$!
mkdir -p "$STATE/coordinator/keeper.lock"; echo "$SLEEPER" > "$STATE/coordinator/keeper.lock/pid"
pass "$STALE"
want "a live lock holder: no run" "0" "$(calls)"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
pass "$STALE"
want "a lock whose holder died is taken over" "1" "$(calls)"

echo "--- a turn that hangs is stopped ---"
reset; s=$SECONDS
KEEPER_TIMEOUT_SEC=1 STUB_SLEEP=20 SWARM_NOW=$STALE bash "$K" >/dev/null 2>&1
want "stopped well before it would finish" "yes" "$([ $(( SECONDS - s )) -lt 10 ] && echo yes || echo no)"
want_in "and the decision says so" "stopped at the 1s limit" "$(tail -1 "$KLOG")"

echo "--- the job: opt-in, through the launcher, every 15 minutes ---"
I="$HERE/../install.sh"
want_not_in "not installed with the default set" "keeper" "$(bash "$I" --jobs 2>&1)"
p=$(bash "$I" --print keeper 2>&1)
want_in "it starts the launcher outside the plugin cache" "<string>$STATE/swarm/run-current.sh</string>" "$p"
want_in "and hands it the keeper's path under the kit"   "<string>swarm/keeper.sh</string>" "$p"
want_in "every 900 seconds"                              "<key>StartInterval</key><integer>900</integer>" "$p"
want_in "with the usage ceiling the coordinator reads"   "<key>SWARM_USAGE_CEILING</key>" "$p"

exit $FAILED
