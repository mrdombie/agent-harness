#!/usr/bin/env bash
# Two simulated windows on one area: they never take the same ticket, and never
# both fix the same red PR. Then the plants: each guard in fix-lock.sh is killed
# in a copy, and the same cases must go red.
#
# A window is a Claude process; here it is a live `sleep` pid named outright, so
# both windows share one login and one host — the case the claim identity
# (login@host) cannot tell apart.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/fix-lock-XXXXXX")
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$SB"' EXIT
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAIM_RUN_ID HARNESS_STATE_DIR FIX_LOCK_WINDOW FIX_LOCK_PID
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# ---- sandbox: an invented project with a bare origin --------------------------
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null
mkdir -p "$SB/work/.claude" "$SB/state" "$SB/bin"
CFGF="$SB/work/.claude/harness.json"   # a scratch project's config, in a temp dir
cat > "$CFGF" <<JSON
{ "repo": "acme/widgets", "integrationBranch": "main", "branchPrefix": "tkt-",
  "stateDir": "$SB/state", "sisterRepos": [],
  "labels": { "drafting": "st:drafting", "ready": "st:ready", "claimed": "st:claimed",
    "inReview": "st:review", "gated": "st:gated", "partial": "st:partial",
    "blocked": "st:blocked", "parked": "st:parked", "externalBlocked": "st:ext-blocked",
    "needsHuman": "st:needs-human", "pmDecision": "st:pm-decision", "pmTrack": "st:pm-track",
    "hold": "hold:human", "decision": ["st:pm-track", "st:pm-decision", "hold:human"] } }
JSON
git -C "$SB/work" add -f -- "$CFGF"
git -C "$SB/work" commit -qm init && git -C "$SB/work" push -q origin main
# gh answers nothing: no PR closes any ticket, no label to restore.
printf '#!/bin/sh\nexit 0\n' > "$SB/bin/gh"; chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" HARNESS_CFG_PATH="$CFGF"

sleep 600 & W1=$!; sleep 600 & W2=$!; PIDS="$W1 $W2"; disown "$W1" "$W2" 2>/dev/null
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null   # a pid that was a window and is gone

win() { # <pid> <kit-scripts-dir> <cmd…> → RC, OUT
  local pid=$1 kit=$2; shift 2
  RC=0
  OUT=$(cd "$SB/work" && FIX_LOCK_REPO="$SB/work" FIX_LOCK_PID="$pid" FIX_LOCK_WINDOW="host:$pid" \
        bash "$kit/fix-lock.sh" "$@" 2>&1) || RC=$?
}
# The same window id the script derives unless told: the stale-holder check reads
# host and pid from the record, so the window is named and the pid is real.

# core <kit-scripts-dir> → number of failed cases (0 = the guards hold)
core() {
  local k=$1 n=0 r1 r2
  git -C "$SB/work" push -q origin --delete refs/fixing/7 refs/fixing/8 refs/fixing/9 2>/dev/null || true
  # 1. One red PR, two windows: the second is told to take other work.
  win "$W1" "$k" acquire 7 --why "checks red";   [ "$RC" -eq 0 ]  || n=$((n+1))
  win "$W2" "$k" acquire 7;                       [ "$RC" -eq 10 ] || n=$((n+1))
  # 2. Only the holder holds it, and the other window cannot release it.
  win "$W1" "$k" holds 7;   [ "$RC" -eq 0 ]  || n=$((n+1))
  win "$W2" "$k" holds 7;   [ "$RC" -eq 12 ] || n=$((n+1))
  win "$W2" "$k" release 7; [ "$RC" -eq 12 ] || n=$((n+1))
  # 3. Both windows at the same instant: exactly one wins.
  ( cd "$SB/work" && FIX_LOCK_REPO="$SB/work" FIX_LOCK_PID="$W1" FIX_LOCK_WINDOW="host:$W1" bash "$k/fix-lock.sh" acquire 8 >/dev/null 2>&1; echo $? > "$SB/r1" ) &
  ( cd "$SB/work" && FIX_LOCK_REPO="$SB/work" FIX_LOCK_PID="$W2" FIX_LOCK_WINDOW="host:$W2" bash "$k/fix-lock.sh" acquire 8 >/dev/null 2>&1; echo $? > "$SB/r2" ) &
  wait 2>/dev/null
  r1=$(cat "$SB/r1"); r2=$(cat "$SB/r2")
  { [ "$r1" = 0 ] && [ "$r2" = 10 ]; } || { [ "$r1" = 10 ] && [ "$r2" = 0 ]; } || n=$((n+1))
  echo "    race: window 1 rc=$r1, window 2 rc=$r2" >&2
  # 4. A window that died: its lock goes to the next window that asks.
  win "$DEAD" "$k" acquire 9; [ "$RC" -eq 0 ] || n=$((n+1))
  win "$W2" "$k" acquire 9;   { [ "$RC" -eq 0 ] && grep -q 'took over' <<<"$OUT"; } || n=$((n+1))
  # 5. A lock past its expiry goes too, even from a live window.
  RC=0; OUT=$(cd "$SB/work" && FIX_LOCK_NOW=$(( $(date +%s) + 3 * 3600 )) FIX_LOCK_REPO="$SB/work" \
              FIX_LOCK_PID="$W2" FIX_LOCK_WINDOW="host:$W2" bash "$k/fix-lock.sh" acquire 7 2>&1) || RC=$?
  { [ "$RC" -eq 0 ] && grep -q 'expired' <<<"$OUT"; } || n=$((n+1))
  echo "$n"
}

echo "fix-lock: two windows, one red PR"
n=$(core "$HERE"); [ "$n" -eq 0 ] && ok "every case holds on the shipped script" || bad "$n case(s) failed on the shipped script"

echo "claim-lock: two windows, one ticket"
CW=""
for p in "$W1" "$W2"; do
  ( cd "$SB/work" && CLAIM_REPO="$SB/work" CLAIM_SESSION_PID="$p" \
      bash "$HERE/claim-lock.sh" acquire 41 --branch "tkt-41/x" --worktree "/wt/$p" >/dev/null 2>&1; echo $? > "$SB/c$p" ) &
  CW="$CW $!"
done
for p in $CW; do wait "$p" 2>/dev/null; done
c1=$(cat "$SB/c$W1"); c2=$(cat "$SB/c$W2")
{ [ "$c1$c2" = "010" ] || [ "$c1$c2" = "100" ]; } && ok "one window took ticket 41, the other lost the race (rc $c1/$c2)" \
  || bad "both or neither took ticket 41 (rc $c1/$c2)"

# ---- the plants: kill each guard in a copy, the cases must fail ----------------
plant() { # <desc> <python replace old> <new>
  local d="$SB/plant"; rm -rf "$d"; mkdir -p "$d"; cp "$HERE"/*.sh "$d/"
  python3 - "$d/fix-lock.sh" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  grep -qF -- "$3" "$d/fix-lock.sh" || { bad "plant did not land: $1"; return; }
  local m; m=$(core "$d" 2>/dev/null)
  [ "$m" -gt 0 ] && ok "planted: $1 → $m case(s) go red" || bad "planted: $1 → still green (the guard is decorative)"
}
echo "plants"
plant "the create is a force-push, not a must-not-exist lease" \
  '--force-with-lease="$NS/$pr:" 2>&1' '--force 2>&1'
plant "a live window's lock reads as stale" \
  '  [ "$exp" -le "$(now)" ] && { printf '"'"'expired'"'"'; return 0; }' \
  '  printf '"'"'expired'"'"'; return 0'
plant "the window is the machine, as the claim identity is" \
  'WINDOW="${FIX_LOCK_WINDOW:-$HOST:$WIN_PID}"' 'WINDOW="$HOST"'
plant "a dead window's lock is never taken over" \
  'if [ "$host" = "$HOST" ] && ! claim_pid_alive "$pid"; then' 'if false; then'

exit $fail
