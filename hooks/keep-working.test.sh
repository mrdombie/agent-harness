#!/usr/bin/env bash
# Plant tests for keep-working.sh. Exit 1 on any mismatch.
#
# Every case plants the thing that should make the hook fire or stay quiet.
# A hook that never fires is decorative; a hook that always fires is the /goal
# 20x loop again — so the quiet cases carry as much weight as the nagging ones.
#
# The ready-count probe is planted through the cache file, so no test touches the
# network and no test depends on what the live board happens to hold today.
#
# The subject is the hook BESIDE THIS FILE, not a copy in a machine's ~/.claude:
# testing an installed copy is how a kit reports green about code it does not
# ship. The project facts are planted in a scratch state dir and passed in the
# environment, so the suite runs on any machine and touches no real queue.
H="$(cd "$(dirname "$0")" && pwd)/keep-working.sh"; fail=0
T=$(mktemp -d)
export HARNESS_STATE_DIR="$T" HARNESS_REPO_SLUG="owner/repo"
LOOP="$T/.loop-active"; STOP="$T/.stop-reason"; LABEL="$T/.session-label"
OWNER="$LABEL.owner"
MDIR="${TMPDIR:-/tmp}/claude-keep-working"

MDIRC(){ rm -rf "$MDIR"; }
trap 'MDIRC; rm -rf "$T"' EXIT

# want: nag | quiet ; args: <desc> <stop_hook_active> <session>
t(){ want=$1 desc=$2 active=$3 sess=$4
  jq -nc --argjson a "$active" --arg s "$sess" \
    '{session_id:$s,hook_event_name:"Stop",stop_hook_active:$a,last_assistant_message:"Merged it."}' \
    | "$H" >/dev/null 2>&1
  [ $? -eq 2 ] && got=nag || got=quiet
  mark=OK; [ "$got" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-9s want=%-6s got=%-6s %s\n' "$mark" "$want" "$got" "$desc"; }

# plant the ready count for session $1 as $2, so guard 6 never reaches the network
ready(){ mkdir -p "$MDIR"; printf '%s' "$2" > "$MDIR/$1.ready"; }

loop_on(){ printf 'project:content-lab\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
           rm -f "$STOP" "$OWNER"; touch "$LOOP"; }

# --- the case the hook exists for ---------------------------------------------
rm -rf "$MDIR"; loop_on; ready s1 7
t nag   'loop running, 7 ready, no stop reason'          false s1

# --- guard 1: the documented escape hatch -------------------------------------
rm -rf "$MDIR"; ready s2 7
t quiet 'stop_hook_active — already blocked this turn'   true  s2

# --- guard 2: cooldown and budget ---------------------------------------------
rm -rf "$MDIR"; ready s3 7
t nag   'cooldown — first stop of the session'           false s3
ready s3 7
t quiet 'cooldown — second stop, same session'           false s3
ready s4 7
t nag   'cooldown is per session, not global'            false s4

rm -rf "$MDIR"; mkdir -p "$MDIR"; echo 6 > "$MDIR/s5.count"; ready s5 7
t quiet 'nag budget spent (6 already this session)'      false s5

# --- guard 3: only /work and /auto loops --------------------------------------
rm -rf "$MDIR"; loop_on; rm -f "$LOOP"; ready s6 7
t quiet 'no .loop-active — /project and /standup are safe' false s6

rm -rf "$MDIR"; loop_on; ready s7 7
touch -t 202001010000 "$LOOP"
t quiet 'loop file stale — no live loop'                 false s7

# --- guard 4: a declared stop condition silences it ----------------------------
rm -rf "$MDIR"; loop_on; ready s8 7
sleep 1; echo 'gate will not go green after three tries' > "$STOP"
t quiet 'stop reason newer than loop start'              false s8

rm -rf "$MDIR"; loop_on; ready s9 7
echo 'an old reason from a previous loop' > "$STOP"; sleep 1; touch "$LOOP"
t nag   'stop reason OLDER than loop start — stale, ignored' false s9

# --- guard 5: single-ticket scope is meant to stop -----------------------------
rm -rf "$MDIR"; loop_on; ready s10 7
printf 'ticket 9822\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
t quiet '/work 9822 — one ticket, then stop'             false s10

rm -rf "$MDIR"; loop_on; ready s11 7
rm -f "$LABEL"
t quiet 'no .session-label — scope unknown'              false s11

rm -rf "$MDIR"; loop_on; ready s11b 7
printf 'auto\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$LABEL"
t nag   '/auto scope is the whole board, not a label'    false s11b

# --- guard 6: the measurement --------------------------------------------------
rm -rf "$MDIR"; loop_on; ready s12 0
t quiet 'scope dry — 0 ready, stopping is correct'       false s12

rm -rf "$MDIR"; loop_on; ready s13 1
t nag   'one ready ticket is still work'                 false s13

# gh unreachable: plant a cache that is EMPTY, which is what a failed probe
# leaves behind. An unknown must not hold the turn open.
rm -rf "$MDIR"; loop_on; mkdir -p "$MDIR"; : > "$MDIR/s14.ready"
PATH=/nonexistent-for-this-test "$H" >/dev/null 2>&1 <<< \
  '{"session_id":"s14","hook_event_name":"Stop","stop_hook_active":false}'
rc=$?
mark=OK; [ $rc -eq 2 ] && { mark=MISMATCH; fail=1; }
printf '%-9s want=%-6s got=%-6s %s\n' "$mark" quiet "$([ $rc -eq 2 ] && echo nag || echo quiet)" \
  'gh unavailable — UNKNOWN never holds the turn open'

# --- guard 5: whose loop is this? ---------------------------------------------
# The coordination files are single global slots shared by every concurrent
# agent. PID 1 is always alive and is never a Claude session, so it stands in
# for a live peer. This case is the guard's death-plant: delete the guard and it
# is the one that flips back to nag.
rm -rf "$MDIR"; loop_on; ready s15 7; echo 1 > "$OWNER"
t quiet 'a live PEER owns the scope — not our loop to hold open'  false s15

# Our own session must STILL be nagged. Without this the guard could be written
# to suppress everything and the case above would never notice.
# The walk is inlined deliberately: the test must know the answer independently
# of the helper it is testing.
rm -rf "$MDIR"; loop_on; ready s16 7
( P=$$; while [ "$P" -gt 1 ]; do
    case "$(ps -p $P -o comm= 2>/dev/null)" in claude|*/claude) echo "$P"; break;; esac
    P=$(ps -p $P -o ppid= 2>/dev/null | tr -d ' ')
  done ) > "$OWNER"
t nag   'we own the scope — the backstop still fires'             false s16

# A dead owner is an abandoned loop, not a peer's.
rm -rf "$MDIR"; loop_on; ready s17 7
# A PID that is provably not in use. Spawning one and killing it is racy here:
# `sleep` is intercepted in some sandboxes, and a just-freed PID can be reused by
# the jq/hook processes the harness spawns a moment later — which made this case
# report the guard as broken when the guard was correct.
DEAD=99999; while ps -p "$DEAD" >/dev/null 2>&1; do DEAD=$((DEAD+1)); done
echo "$DEAD" > "$OWNER"
t nag   'owner PID is dead — stale, treated as unowned'           false s17

# No owner recorded at all is the world before this guard.
rm -rf "$MDIR"; loop_on; ready s18 7; rm -f "$OWNER"
t nag   'no owner recorded — unchanged from before the guard'     false s18

echo
[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES — see MISMATCH rows above"
exit "$fail"
