#!/usr/bin/env bash
# Spawn one agent per ticket, in its own process.
#
# A context window can't be cleared from inside itself — no hook event can do
# it. So the fresh context comes from a fresh process: one spawn, one ticket,
# one worktree, one PR, then exit. Typing /claim into a live session instead
# inherits that session's context and whatever budget it has left.
#
#   claim              claim the next ready ticket
#   claim 7897         claim that ticket
#   claim --fg         interactive, in the foreground, so you can watch it
#
# The detached path runs claude inside a subshell that outlives it, so when the
# agent exits — cleanly, blocked, budget-capped, or killed — the subshell runs
# reconcile-claims.sh immediately. That covers every exit the agent can observe
# and several it can't; the launchd sweep is the backstop for the rest.
#
# Env: CLAIM_BUDGET_USD (default 150), CLAIM_PERMISSION_MODE (default auto)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/toolkit-env.sh" || exit 1
TICKETS_DIR="$STATE_DIR"
RUNS_DIR="$TICKETS_DIR/runs"
LOGS_DIR="$TICKETS_DIR/logs"
BUDGET="${CLAIM_BUDGET_USD:-150}"
PERM_MODE="${CLAIM_PERMISSION_MODE:-auto}"

# The spawner refreshes ITSELF, not only the agent's tree. It is reached through a
# shell function pointing at one copy on the operator's machine, and that copy is
# what went stale first — three days old on 2026-09-27, cd'ing every agent into a
# tree 210 commits behind. Re-exec the integration branch's own copy once, so the
# spawn logic can never be older than the rules it installs.
if [ -z "${SPAWN_CLAIM_CANONICAL:-}" ]; then
  export SPAWN_CLAIM_CANONICAL=1
  _spawn_canon="$(toolkit_tools 2>/dev/null)/scripts/spawn-claim.sh"
  if [ -f "$_spawn_canon" ] && ! cmp -s "$_spawn_canon" "${BASH_SOURCE[0]}"; then
    exec bash "$_spawn_canon" "$@"
  fi
  unset _spawn_canon
fi

FG=0
TICKET=""
for arg in "$@"; do
  case "$arg" in
    --fg) FG=1 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) TICKET="$arg" ;;
  esac
done

command -v claude >/dev/null 2>&1 || { echo "claude CLI not on PATH" >&2; exit 1; }

mkdir -p "$RUNS_DIR" "$LOGS_DIR"

PROMPT="/agent-harness:claim"
[ -n "$TICKET" ] && PROMPT="/agent-harness:claim $TICKET"

# --- foreground: a fresh window you can talk to --------------------------------
# No run record and no budget cap here — --max-budget-usd is silently ignored
# outside --print, and an interactive session you're watching doesn't need a
# watchdog to notice it died. Its lock falls back to artifact-freshness.
if [ "$FG" -eq 1 ]; then
  echo "→ interactive session, fresh context, running $PROMPT"
  echo "  no budget cap (--max-budget-usd only applies to --print runs)"
  SPAWN_ROOT=$(toolkit_spawn_root) || exit 1
  cd "$SPAWN_ROOT" || exit 1   # the branch's checkout: skills, guard rules, reviewers and CLAUDE.md load from its .claude/
  exec claude --permission-mode "$PERM_MODE" --name "claim-${TICKET:-next}" "$PROMPT"
fi

# The WHOLE detached spawn — wrapper subshell, reconcile, and the agent — runs in
# its own session. The first attempt setsid'd only the claude process: the agent
# survived its launcher dying, but the wrapper that writes .ended and runs
# reconcile did not, so four daemon-spawned agents ran on as orphans that nothing
# would ever record as finished. macOS has no setsid(1); perl's POSIX::setsid does
# the same job. Re-exec once, then carry on.
if [ -z "${SPAWN_CLAIM_SESSION:-}" ]; then
  SPAWN_CLAIM_SESSION=1 exec perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!"' -- /bin/bash "$0" "$@"
fi

# --- detached: the default -----------------------------------------------------
# PRINT-MODE RULE, prepended to every detached prompt. Measured 2026-09-19 on the
# origin project's first swarm: three of the first eight agents ended their turn
# with "running in the background; I'll pick it up when it completes" — a
# screenshot run, a route capture, a Monitor on a log — and in `claude -p` ending
# the turn ends the process. All three exited 0 with the fix built and tested,
# nothing pushed and no PR, stranded in their worktrees. The pattern is
# load-induced, so it recurs exactly when the swarm is biggest. CLAIM_EXTRA
# carries a resume brief when re-spawning a stranded run.
PRINT_MODE_RULE="You are running in print mode: the moment you end your turn, this process exits and nothing you left running survives. NEVER start something in the background and end your turn intending to pick it up — no Monitor you wait on, no 'I'll check when it completes', no backgrounded screenshot or capture. Wait for every check in the foreground, then continue. If a real-route capture is too slow under load, retry it in the foreground with a longer timeout; do not defer it. The turn ends when the PR is PUSHED and HANDED OFF — local gates green (lint:changed, typecheck, test:changed), both review trailers on the pushed head, PR ready with auto-merge armed, the hold label on if pixels changed, and a one-line 'Handed off at <sha>' comment on the PR. Do NOT wait for CI: a watcher brings an agent back if CI goes red or the PR conflicts. Or the turn ends when you have PARKED the ticket per /agent-harness:claim's park procedure: commit, push, draft PR, resume brief on the issue, label — all BEFORE the banner. An exit with unpushed work is a failed run. Kill only processes you started (record their PIDs); never pkill a pattern that could match another agent's."
PROMPT="$PRINT_MODE_RULE

$PROMPT"
[ -n "${CLAIM_EXTRA:-}" ] && PROMPT="$PROMPT

$CLAIM_EXTRA"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_ID="claim-${TICKET:-next}-$STAMP-$$"
LOG="$LOGS_DIR/$RUN_ID.log"
RECORD="$RUNS_DIR/$RUN_ID.json"

# Exported so /claim writes run_id + run_log into the lockfile's meta.json —
# that association is what lets the watchdog tell this agent's claim from
# anyone else's.
export CLAIM_RUN_ID="$RUN_ID"
export CLAIM_RUN_LOG="$LOG"
export CLAIM_AGENT="$(toolkit_login)@$(hostname -s 2>/dev/null || hostname | cut -d. -f1)"   # resolved once per run, inherited by every claim-lock call

SPAWN_ROOT=$(toolkit_spawn_root) || exit 1
cd "$SPAWN_ROOT" || exit 1   # the branch's checkout: skills, guard rules, reviewers and CLAUDE.md load from its .claude/

(
  # Backgrounded so the agent's OWN pid is knowable. The record used to carry
  # only this subshell's pid, and if the subshell was killed while claude
  # survived as an orphan, the watchdog read the run as dead and released the
  # lock out from under a working agent.
  #
  # This subshell waits on the agent, so it lives exactly as long as the agent
  # does: claim-lock.sh records it as the claim's session instead of walking the
  # process tree, which cannot reach the agent from a native parent on Windows.
  # macOS ships bash 3.2, which has no $BASHPID; the exec'd sh's parent is this
  # subshell on every bash.
  CLAIM_SESSION_PID="${BASHPID:-$(exec sh -c 'echo $PPID')}"
  export CLAIM_SESSION_PID
  claude -p "$PROMPT" \
    --permission-mode "$PERM_MODE" \
    --max-budget-usd "$BUDGET" \
    --name "$RUN_ID" \
    --add-dir "$TICKETS_DIR" \
    --output-format stream-json --verbose \
    >> "$LOG" 2>&1 &
  CLAUDE_PID=$!
  printf '%s\n' "$CLAUDE_PID" > "$RUNS_DIR/$RUN_ID.child"
  # Windows: the MSYS pid above is invisible to anything that is not MSYS (the
  # live view's node server among them). Record the native pid beside it.
  [ -r "/proc/$CLAUDE_PID/winpid" ] && cat "/proc/$CLAUDE_PID/winpid" > "$RUNS_DIR/$RUN_ID.child.winpid"
  ps -o lstart= -p "$CLAUDE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//' \
    > "$RUNS_DIR/$RUN_ID.child.started" || true
  wait "$CLAUDE_PID"
  code=$?

  # Mark the run ended BEFORE reconciling. This subshell is still alive while
  # reconcile runs, so a bare `kill -0` on its pid would report the agent as
  # working and the failure would be missed.
  printf '{"run_id":"%s","exit_code":%d,"ended_at":"%s"}\n' \
    "$RUN_ID" "$code" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RUNS_DIR/$RUN_ID.ended"

  # NOT --quiet. This is the immediate signal that the agent died, and the log
  # is where you look to find out what happened to it. --quiet routes every
  # verdict through a suppressed say(), summary included, so the reconcile ran
  # invisibly: the GH label still landed, but nothing in the log said a claim
  # had been escalated or why. Caught on the first real spawn — a 15s
  # budget-capped run whose log had no trace of the reconcile at all.
  printf '\n--- post-exit reconcile (%s) ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
  "$SCRIPT_DIR/reconcile-claims.sh" >> "$LOG" 2>&1
) &

SUBSHELL_PID=$!
# `disown` only stops bash sending SIGHUP; the run stays in the terminal's
# process group, so closing the terminal still kills the "detached" run. Put it
# in its own session where one is available, which is what the header promises.
if command -v setsid >/dev/null 2>&1; then
  setsid -w true >/dev/null 2>&1 || true
fi
disown "$SUBSHELL_PID" 2>/dev/null || true

# The agent's pid is written from inside the subshell, so it may not exist yet.
# Wait briefly rather than record a null the watchdog would have to interpret.
CLAUDE_PID=""; CLAUDE_STARTED=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$RUNS_DIR/$RUN_ID.child" ] && break
  sleep 0.2
done
[ -s "$RUNS_DIR/$RUN_ID.child" ] && CLAUDE_PID=$(cat "$RUNS_DIR/$RUN_ID.child")
[ -s "$RUNS_DIR/$RUN_ID.child.started" ] && CLAUDE_STARTED=$(cat "$RUNS_DIR/$RUN_ID.child.started")
SUBSHELL_STARTED=$(ps -o lstart= -p "$SUBSHELL_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')
SUBSHELL_WINPID=""; CLAUDE_WINPID=""
[ -r "/proc/$SUBSHELL_PID/winpid" ] && SUBSHELL_WINPID=$(cat "/proc/$SUBSHELL_PID/winpid")
[ -s "$RUNS_DIR/$RUN_ID.child.winpid" ] && CLAUDE_WINPID=$(cat "$RUNS_DIR/$RUN_ID.child.winpid")

cat > "$RECORD" <<EOF
{
  "run_id": "$RUN_ID",
  "pid": $SUBSHELL_PID,
  "pid_started": "$SUBSHELL_STARTED",
  "winpid": ${SUBSHELL_WINPID:-null},
  "child_pid": ${CLAUDE_PID:-null},
  "child_pid_started": "$CLAUDE_STARTED",
  "child_winpid": ${CLAUDE_WINPID:-null},
  "log": "$LOG",
  "ticket": "${TICKET:-}",
  "operator": "$(gh api user --jq .login 2>/dev/null || whoami)@$(hostname -s 2>/dev/null || hostname | cut -d. -f1)",
  "budget_usd": $BUDGET,
  "permission_mode": "$PERM_MODE",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "→ spawned $RUN_ID (pid $SUBSHELL_PID), budget \$$BUDGET, permissions $PERM_MODE"
echo "  log: $LOG"
echo "  tail -f \"$LOG\" | jq -r 'select(.type==\"assistant\") | .message.content[]? | select(.type==\"text\") | .text'"
