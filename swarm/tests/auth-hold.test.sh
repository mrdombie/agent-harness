#!/usr/bin/env bash
# auth-hold.test.sh — a paused host resumes by itself: while the auth hold stands,
# swarm_auth_check re-probes once per swarm.authProbeMin; a pass moves the hold aside
# to logs/, a lost-login answer keeps it with its words refreshed, and inside the
# interval no probe runs.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
KIT="$HERE/../.."
export SWARM_LOGS="$STATE/logs" SWARM_AUTH_HOLD_FILE="$STATE/auth-hold" SWARM_ACCOUNT=acct-1 SWARM_HOST=hostA
PROBES="$FIX/probes"

jq -nc '{type:"result", is_error:false, num_turns:1, result:"ok"}' > "$FIX/ok.jsonl"
jq -nc '{type:"result", is_error:true, num_turns:1, terminal_reason:"api_error",
  result:"Failed to authenticate: OAuth token revoked by the owner"}' > "$FIX/expired.jsonl"

env_do() { # <now> <probe answer file> <function…> — run in a fresh shell on the kit
  local now="$1" ans="$2"; shift 2
  SWARM_NOW="$now" SWARM_AUTH_PROBE_CMD="echo x >> '$PROBES'; cat '$ans'" \
    bash -c '. "$1/swarm/swarm-env.sh" >/dev/null 2>&1 || exit 9; shift; "$@"' _ "$KIT" "$@"
}
probes() { [ -f "$PROBES" ] && wc -l < "$PROBES" | tr -d ' ' || echo 0; }
plant_hold() { # a hold written a while ago, and a failed check kept beside it
  rm -f "$PROBES" "$SWARM_LOGS"/auth-hold.* "$SWARM_LOGS/.auth-check"
  printf '%s\tFailed to authenticate: OAuth session expired\thostA\tacct-1\n' "$1" > "$SWARM_AUTH_HOLD_FILE"
  printf '%s\tfailed\tFailed to authenticate: OAuth session expired\n' "$1" > "$SWARM_LOGS/.auth-check"
}

T=$(date +%s); LATER=$(( T + 400 ))

echo "--- a hold older than swarm.authProbeMin: a passing probe clears it ---"
plant_hold "$T"
env_do "$LATER" "$FIX/ok.jsonl" swarm_auth_check >/dev/null; rc=$?
want "the check passes" "0" "$rc"
want "one probe ran" "1" "$(probes)"
want "the hold file is gone" "no" "$([ -f "$SWARM_AUTH_HOLD_FILE" ] && echo yes || echo no)"
aside=$(ls "$SWARM_LOGS"/auth-hold.* 2>/dev/null | head -1)
want "it was moved aside to logs/" "yes" "$([ -n "$aside" ] && echo yes || echo no)"
want_in "the record keeps when and why" "OAuth session expired" "$(cat "$aside" 2>/dev/null)"
env_do "$LATER" "$FIX/ok.jsonl" swarm_auth_hold >/dev/null; want "swarm_auth_hold then returns 1" "1" "$?"

echo "--- a hold older than swarm.authProbeMin: a lost-login probe keeps it ---"
plant_hold "$T"
said=$(env_do "$LATER" "$FIX/expired.jsonl" swarm_auth_check); rc=$?
want "the check fails" "1" "$rc"
want "one probe ran" "1" "$(probes)"
want "the hold stands" "yes" "$([ -f "$SWARM_AUTH_HOLD_FILE" ] && echo yes || echo no)"
want_in "its words are refreshed" "OAuth token revoked" "$(cut -f2 "$SWARM_AUTH_HOLD_FILE")"
want "its since is kept" "$T" "$(cut -f1 "$SWARM_AUTH_HOLD_FILE")"
want_in "the check says the CLI's words" "OAuth token revoked" "$said"
env_do "$LATER" "$FIX/ok.jsonl" swarm_auth_hold >/dev/null; want "swarm_auth_hold still returns 0" "0" "$?"

echo "--- inside swarm.authProbeMin no probe runs ---"
plant_hold "$T"
touch "$SWARM_AUTH_HOLD_FILE"
env_do "$(( T + 60 ))" "$FIX/ok.jsonl" swarm_auth_check >/dev/null; rc=$?
want "the check fails while held" "1" "$rc"
want "no probe ran" "0" "$(probes)"
want "the hold stands" "yes" "$([ -f "$SWARM_AUTH_HOLD_FILE" ] && echo yes || echo no)"

echo "--- the hold removed by hand: a kept failed check is not trusted, a fresh probe runs ---"
plant_hold "$T"
rm -f "$SWARM_AUTH_HOLD_FILE"
env_do "$(( T + 60 ))" "$FIX/ok.jsonl" swarm_auth_check >/dev/null; rc=$?
want "the check passes" "0" "$rc"
want "one probe ran" "1" "$(probes)"
want "the kept check now reads ok" "ok" "$(cut -f2 "$SWARM_LOGS/.auth-check")"

suite_end "$FAILED"
