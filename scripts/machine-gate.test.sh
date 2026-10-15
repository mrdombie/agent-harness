#!/usr/bin/env bash
# machine-gate.test.sh — heavy local work waits for the machine.
#
# Two halves. The gate itself: it holds above the load ceiling and re-checks,
# it never fails, it lets at most N gate runs go at once, and it frees a slot
# whose holder died. Then the CALL SITES: every skill that starts heavy work
# carries a bash block that calls the gate, and this suite RUNS that block from
# the skill file at a load of 99 and asserts nothing started. Delete the call
# from any one skill and its row goes red — the block either vanishes (not
# found) or runs its work straight through (it did not wait).
set -uo pipefail
for _gv in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$_gv"; done

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$KIT/scripts/machine-gate.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   — $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL — $1"; }

T=$(cd "$(mktemp -d)" && pwd -P)
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$T"; }
trap cleanup EXIT

# Never the machine's own slots, load, config or plugin env.
export HARNESS_GATE_SLOT_DIR="$T/slots" MACHINE_GATE_POLL=0 SWARM_MAX_LOAD=32 HARNESS_GATE_SLOTS=2
export HARNESS_CFG_PATH="$T/none.json"
unset SWARM_LOAD SWARM_LOAD_FILE MACHINE_GATE_MAX_WAIT HARNESS_CFG CLAUDE_PLUGIN_ROOT 2>/dev/null

echo "--- under the ceiling: no wait, nothing printed ---"
out=$(SWARM_LOAD=5 bash "$SUT" wait --max 1 2>&1); rc=$?
[ "$rc" = 0 ] && ok "wait returns 0" || fail "wait returned $rc"
[ -z "$out" ] && ok "and says nothing" || fail "printed: $out"

echo "--- over the ceiling: it says so, re-checks, and never fails ---"
out=$(SWARM_LOAD=99 bash "$SUT" wait --max 1 2>&1); rc=$?
[ "$rc" = 75 ] && ok "a wait that runs out is 75, not a failure" || fail "rc $rc"
printf '%s' "$out" | grep -q 'machine busy (load 99, limit 32), waiting' && ok "the busy line names load and limit" || fail "busy line missing: $out"
[ "$(printf '%s\n' "$out" | grep -c 'machine busy')" -ge 2 ] && ok "it re-checked" || fail "checked only once"

echo "--- run: above the ceiling the command does not start ---"
rm -f "$T/ran"
SWARM_LOAD=99 bash "$SUT" run --max 1 -- touch "$T/ran" >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && ok "75" || fail "rc $rc"
[ ! -e "$T/ran" ] && ok "nothing ran" || fail "the command ran on a busy machine"

echo "--- the load falls while it waits: it goes ahead on its own ---"
echo 99 > "$T/load"; rm -f "$T/ran"
( SWARM_LOAD_FILE="$T/load" MACHINE_GATE_POLL=1 bash "$SUT" run -- touch "$T/ran" > "$T/fall.out" 2>&1; echo $? > "$T/fall.rc" ) &
PIDS+=($!)
sleep 2
[ ! -e "$T/ran" ] && ok "held while busy" || fail "ran while busy"
echo 3 > "$T/load"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -f "$T/fall.rc" ] && break; sleep 1; done
[ -e "$T/ran" ] && ok "ran once the load fell" || fail "never ran: $(cat "$T/fall.out")"
[ "$(cat "$T/fall.rc" 2>/dev/null)" = 0 ] && ok "and passed the command's exit through" || fail "rc $(cat "$T/fall.rc" 2>/dev/null)"

echo "--- the command's own exit code comes back ---"
SWARM_LOAD=1 bash "$SUT" run -- sh -c 'exit 3' 2>/dev/null; rc=$?
[ "$rc" = 3 ] && ok "exit 3 comes back as 3" || fail "rc $rc"
[ -z "$(ls "$T/slots" 2>/dev/null)" ] && ok "and the slot is given back" || fail "slot left behind: $(ls "$T/slots")"

echo "--- at most N gate runs at once, machine-wide ---"
: > "$T/conc.log"
export T
for i in 1 2 3 4 5; do
  ( SWARM_LOAD=1 HARNESS_GATE_SLOTS=2 bash "$SUT" run -- bash -c 'echo s >> "$T/conc.log"; sleep 1; echo e >> "$T/conc.log"' >/dev/null 2>&1 ) &
  PIDS+=($!)
done
wait
peak=$(awk '$1=="s"{n++; if(n>m)m=n} $1=="e"{n--} END{print m+0}' "$T/conc.log")
runs=$(grep -c '^s' "$T/conc.log")
[ "$runs" = 5 ] && ok "all 5 ran in the end" || fail "$runs of 5 ran"
[ "$peak" -le 2 ] && [ "$peak" -ge 1 ] && ok "never more than 2 at once (peak $peak)" || fail "peak $peak with 2 slots"

echo "--- a live holder keeps its slot ---"
mkdir -p "$T/slots"
sleep 30 & live=$!; PIDS+=($live)
mkdir "$T/slots/slot-1"; echo "$live" > "$T/slots/slot-1/pid"
rm -f "$T/ran"
out=$(SWARM_LOAD=1 HARNESS_GATE_SLOTS=1 bash "$SUT" run --max 1 -- touch "$T/ran" 2>&1); rc=$?
[ "$rc" = 75 ] && [ ! -e "$T/ran" ] && ok "full: waited, nothing ran" || fail "rc $rc, ran=$([ -e "$T/ran" ] && echo yes || echo no)"
printf '%s' "$out" | grep -q "machine busy (1 of 1 gate runs going: pid $live" && ok "it names who holds the slot" || fail "no holder line: $out"
[ "$(cat "$T/slots/slot-1/pid")" = "$live" ] && ok "the live holder still holds it" || fail "a live slot was taken"

echo "--- a dead holder's slot is recovered by pid ---"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
rm -f "$T/ran"
out=$(SWARM_LOAD=1 HARNESS_GATE_SLOTS=1 bash "$SUT" run --max 1 -- touch "$T/ran" 2>&1); rc=$?
[ "$rc" = 0 ] && [ -e "$T/ran" ] && ok "dead pid: slot freed and the run went ahead" || fail "rc $rc: $out"
printf '%s' "$out" | grep -q "which is gone — freed" && ok "and says it freed it" || fail "silent reap: $out"

echo "--- a slot with no pid yet is mid-take, not stale ---"
mkdir -p "$T/slots/slot-1"; rm -f "$T/ran"
SWARM_LOAD=1 HARNESS_GATE_SLOTS=1 bash "$SUT" run --max 1 -- touch "$T/ran" >/dev/null 2>&1; rc=$?
[ "$rc" = 75 ] && [ -d "$T/slots/slot-1" ] && ok "a fresh pid-less slot is left alone" || fail "rc $rc"
touch -t 202001010000 "$T/slots/slot-1"
SWARM_LOAD=1 HARNESS_GATE_SLOTS=1 bash "$SUT" run --max 1 -- touch "$T/ran" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "an old pid-less slot is reaped" || fail "rc $rc"
rm -rf "$T/slots"; mkdir -p "$T/slots"

echo "--- the ceiling and slot count come from harness.json when not in the env ---"
printf '{"swarm":{"maxLoad":4,"gateSlots":1}}' > "$T/cfg.json"
out=$(env -u SWARM_MAX_LOAD -u HARNESS_GATE_SLOTS HARNESS_CFG_PATH="$T/cfg.json" SWARM_LOAD=5 bash "$SUT" status 2>&1)
printf '%s' "$out" | grep -q 'limit 4 · gate slots 1' && ok "swarm.maxLoad and swarm.gateSlots read" || fail "$out"
out=$(env -u SWARM_MAX_LOAD -u HARNESS_GATE_SLOTS SWARM_LOAD=5 bash "$SUT" status 2>&1)
printf '%s' "$out" | grep -q 'limit 32 · gate slots 2' && ok "defaults 32 and 2 with no config" || fail "$out"

# ---- the call sites ----------------------------------------------------------
# Each skill's fenced bash block that calls machine-gate.sh, run as written.
blocks() { # <file> — every ```bash block mentioning machine-gate.sh, NUL-separated
  awk '/^[[:space:]]*```bash[[:space:]]*$/{inb=1; b=""; next}
       inb && /^[[:space:]]*```[[:space:]]*$/{inb=0; if (b ~ /machine-gate\.sh/) printf "%s%c", b, 0; next}
       inb{b=b $0 "\n"}' "$1"
}

site() { # <label> <file> <cwd> <marker-expected-absent-at-99>
  local label="$1" f="$2" n=0 b rc out
  while IFS= read -r -d '' b; do
    n=$((n+1))
    # The block's own work, standing in for what follows it in the skill: if the
    # block returns 0 at load 99, the skill goes on to start heavy work.
    out=$(cd "$3" && CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=99 MACHINE_GATE_MAX_WAIT=1 \
            bash -c "$b"$'\n''touch "'"$T"'/started"' 2>&1); rc=$?
    if [ "$rc" = 75 ] && [ ! -e "$T/started" ] && printf '%s' "$out" | grep -q 'machine busy'; then
      ok "$label: block $n holds at load 99 and says so"
    else
      fail "$label: block $n did not hold at load 99 (rc $rc, started=$([ -e "$T/started" ] && echo yes || echo no))"
    fi
    rm -f "$T/started"
    out=$(cd "$3" && CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=1 MACHINE_GATE_MAX_WAIT=1 \
            bash -c "$b" 2>&1); rc=$?
    [ "$rc" = 0 ] && ok "$label: block $n goes ahead at load 1" || fail "$label: block $n refused at load 1 (rc $rc): $out"
  done < <(blocks "$f")
  [ "$n" -gt 0 ] || fail "$label: no bash block calls machine-gate.sh — heavy work starts without waiting"
}

echo "--- every path that starts heavy work waits for the machine ---"
# A checked-in project whose one changed-only gate touches $MG_TEST_MARK. Read
# only: the suite never writes into it.
FIXREPO="$KIT/scripts/fixtures/machine-gate"
export MG_TEST_MARK="$T/gated"
for s in claim work auto bug finish; do site "$s" "$KIT/skills/$s/SKILL.md" "$FIXREPO"; done
site "gate-runner" "$KIT/agents/gate-runner.md" "$FIXREPO"

echo "--- finish: the gate commands themselves are what is held ---"
b=$(blocks "$KIT/skills/finish/SKILL.md" | tr '\0' '\n')
rm -f "$T/gated"
(cd "$FIXREPO" && CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=99 MACHINE_GATE_MAX_WAIT=1 bash -c "$b" >/dev/null 2>&1)
[ ! -e "$T/gated" ] && ok "at load 99 no gate command ran" || fail "gates.changed ran on a busy machine"
(cd "$FIXREPO" && CLAUDE_PLUGIN_ROOT="$KIT" SWARM_LOAD=1 MACHINE_GATE_MAX_WAIT=1 bash -c "$b" >/dev/null 2>&1)
[ -e "$T/gated" ] && ok "at load 1 the gate commands ran" || fail "gates.changed never ran"
grep -nE '^[^#]*eval "\$CHANGED"' "$KIT/skills/finish/SKILL.md" >/dev/null \
  && fail "finish still runs gates.changed as a bare eval somewhere" || ok "no bare eval of gates.changed left in finish"

echo
echo "machine-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
