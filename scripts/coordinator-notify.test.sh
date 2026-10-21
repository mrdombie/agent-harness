#!/usr/bin/env bash
# coordinator-notify.test.sh — the owner channel carries the owner's decisions and
# nothing else: agent work goes to the agent log whatever class a caller passes,
# an owner line carries its key, and shadow writes nothing anywhere.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
N="$HERE/coordinator-notify.sh"
C="$STATE/coordinator"
cat > "$BIN/ping" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/ping.log"
SH
chmod +x "$BIN/ping"
export COORDINATOR_NOTIFY_CMD="$BIN/ping"
unset COORDINATOR_SHADOW
fresh() { rm -rf "$C"; : > "$FIX/ping.log"; }
needs() { cat "$C/needs-you.md" 2>/dev/null; }
agent() { cut -f2,3 "$C/agent-work.log" 2>/dev/null; }

echo "--- an owner decision reaches the owner, carrying its key ---"
fresh
COORDINATOR_SHADOW=0 bash "$N" --class owner "signoff-batch:1@a,2@b" "2 screens are ready"
want_in "needs-you has the line and its key" '^- \[ \] .* — 2 screens are ready <!-- key:signoff-batch:1@a,2@b -->$' "$(needs)"
want "the owner is pinged"                 "2 screens are ready" "$(cat "$FIX/ping.log")"
want "nothing lands in the agent log"      "" "$(agent)"
COORDINATOR_SHADOW=0 bash "$N" --class owner "signoff-batch:1@a,2@b" "2 screens are ready"
want "a key is written once"               "1" "$(needs | grep -c .)"
COORDINATOR_SHADOW=0 bash "$N" --class=owner "decision:77:scope" "Ship the export without CSV, or wait?"
want_in "a judged decision is the owner's"  'key:decision:77:scope' "$(needs)"
COORDINATOR_SHADOW=0 bash "$N" --class owner "decision:78:x" $'two\nlines'
want "a newline cannot split an entry"      "3" "$(needs | grep -c .)"

echo "--- agent work never reaches the owner, whatever the caller says ---"
fresh
COORDINATOR_SHADOW=0 bash "$N" --class owner "red-pr:41:abc" "PR #41 is red only on the layout spec, needs the spec fixed"
want "a red PR filed as owner is not the owner's" "" "$(needs)"
want "and pings nobody"                    "" "$(cat "$FIX/ping.log")"
want_in "it is agent work, logged"         $'^red-pr:41:abc\tPR #41 is red only' "$(agent)"
COORDINATOR_SHADOW=0 bash "$N" --class owner "frozen:claim-9-x:123" "run claim-9-x is stuck"
COORDINATOR_SHADOW=0 bash "$N" --class owner "red-develop:2026-10-15" "develop is red"
COORDINATOR_SHADOW=0 bash "$N" "lane-hold:12:abc" "PR #12 needs sign-off again"
want "stuck agents, a red develop, a re-hold: none is the owner's" "" "$(needs)"
want "all three are logged"                "3" "$(grep -cvE '^red-pr' <<<"$(agent)")"
COORDINATOR_SHADOW=0 bash "$N" "decision:79:x" "no class given"
want "no class means agent, even for a decision key" "" "$(needs)"
bash "$N" --class boss "decision:1:x" "x" 2>/dev/null
want "an unknown class is refused"         "2" "$?"

echo "--- shadow writes nothing anywhere ---"
fresh
bash "$N" --class owner "disk-low:2026-10-15" "Disk is low"
bash "$N" --class agent "red-pr:1:a" "red"
want "no needs-you, no agent log, no ping" "" "$(needs; agent; cat "$FIX/ping.log")"
want_in "both are logged as would"         $'would\tnotify\tdisk-low' "$(cat "$C/actions.log")"
want_in "the agent one too"                $'would\tnotify-agent\tred-pr:1:a' "$(cat "$C/actions.log")"
COORDINATOR_SHADOW=0 bash "$N" --class owner "disk-low:2026-10-15" "Disk is low"
want "a key seen in shadow still reaches the owner live" "1" "$(needs | grep -c 'Disk is low')"

suite_end "$FAILED"
