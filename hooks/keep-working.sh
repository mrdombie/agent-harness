#!/usr/bin/env bash
# Backstop for "the loop keeps going while there is runnable work".
#
# WHY: /work and /auto are instructions, not a runtime. On 2026-08-29 the model
# tried to hand back twice with context and runnable tickets remaining. work.md
# named `/goal` as "the only hard enforcement" for this — measured 2026-09-14,
# there is no goal.md and no hook referencing it on this machine, so the loop had
# nothing holding it open at all. This is that enforcement, rebuilt.
#
# A Stop hook CANNOT print to the user's terminal — plain stdout goes to the debug
# log. exit 2 feeds the reason back to the model and CONTINUES the turn, which is
# exactly what a keep-going backstop needs.
#
# A blocking Stop hook is how /goal looped ~20x on 2026-08-30. SEVEN guards below,
# each of which alone ends the turn, plus a hard per-session nag budget. The
# common path is guard 3 — one stat call, no network.
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-keep-working.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# The two project facts — the state dir and the repo slug — come from
# .claude/harness.json. This hook fires on every Stop, including in sessions
# started outside a checkout, so both fall back to the resolver's last-seen
# values the same way block-hookify-rules.sh does. With neither, the hook stands
# down: it cannot ask a board it cannot name, and a nag aimed at the wrong
# project is worse than no nag.
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
if [ -f "$_cfg" ]; then
  eval "$(jq -r '"_cs=\(.stateDir // "" | @sh) _cr=\(.repo // "" | @sh)"' "$_cfg" 2>/dev/null)"
fi
TDIR="${HARNESS_STATE_DIR:-${_cs:-}}"
[ -n "$TDIR" ] || TDIR=$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null || true)
TDIR="${TDIR/#\~/$HOME}"
REPO="${HARNESS_REPO_SLUG:-${_cr:-}}"
[ -n "$REPO" ] || REPO=$(cat "$HOME/.claude/.harness-last-repo-slug" 2>/dev/null || true)
[ -n "$TDIR" ] && [ -n "$REPO" ] || { say "exit0 unconfigured"; exit 0; }
LOOP_FILE="$TDIR/.loop-active"      # written by the loop flows when the loop starts
STOP_FILE="$TDIR/.stop-reason"      # written by the flow when a stop condition fires
LABEL_FILE="$TDIR/.session-label"
MAX_NAGS=6                          # hard ceiling per session, whatever else happens

# 1. The documented escape hatch. We have already blocked once this turn.
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && {
  say "exit0 stop_hook_active"; exit 0; }

# 2. Cooldown + budget. At most one nag per session per 10 minutes, and never
#    more than MAX_NAGS in one session. A model that genuinely cannot continue
#    costs a handful of extra turns, not an unbounded loop.
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
MDIR="${TMPDIR:-/tmp}/claude-keep-working"; mkdir -p "$MDIR"
MARK="$MDIR/$SID"; COUNT="$MDIR/$SID.count"
if [ -f "$MARK" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$MARK" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt 600 ] && { say "exit0 cooldown ${AGE}s $SID"; exit 0; }
fi
N=$(cat "$COUNT" 2>/dev/null || echo 0)
[ "$N" -ge "$MAX_NAGS" ] && { say "exit0 budget-spent $N $SID"; exit 0; }

# 3. Is a LOOP running? Not merely "is there work on the board" — /project, /standup
#    and /cheatsheet end turns legitimately with 469 ready tickets on the board,
#    and nagging those would be noise. /work and /auto write .loop-active when
#    their loop starts; nothing else does.
[ -f "$LOOP_FILE" ] || { say "exit0 no-loop-file"; exit 0; }
LAGE=$(( $(date +%s) - $(stat -f %m "$LOOP_FILE" 2>/dev/null || echo 0) ))
[ "$LAGE" -gt 21600 ] && { say "exit0 loop-stale ${LAGE}s"; exit 0; }

# 4. Did the flow declare a stop condition? .stop-reason NEWER than .loop-active
#    means this loop ended deliberately — dry label, gate it cannot green, a
#    decision only the PM can make, a permission denial. All legitimate.
if [ -f "$STOP_FILE" ]; then
  SM=$(stat -f %m "$STOP_FILE" 2>/dev/null || echo 0)
  LM=$(stat -f %m "$LOOP_FILE" 2>/dev/null || echo 0)
  [ "$SM" -ge "$LM" ] && { say "exit0 stop-declared $(head -1 "$STOP_FILE" 2>/dev/null)"; exit 0; }
fi

# 5. Whose loop is this? The files above are single global slots and several
#    agents share them, so a fresh .loop-active may belong to somebody else.
#    /work records the owning Claude session PID in .session-label.owner;
#    lib/claude-session.sh derives the same value by walking our own tree.
#
#    Measured 2026-09-18: session 73885 was told to ship nine tickets from
#    session 58632's scope because nothing here ever opened that file.
#
#    Unowned, stale-owned, or our own identity unresolvable all fall through to
#    the behaviour that existed before this guard, so nothing loses protection.
# shellcheck source=lib/claude-session.sh
. "$(dirname "$0")/lib/claude-session.sh" 2>/dev/null || say "warn no-session-lib"
if declare -F scope_owned_by_peer >/dev/null 2>&1; then
  if PEER=$(scope_owned_by_peer "$TDIR/.session-label.owner"); then
    say "exit0 not-my-loop owner=$PEER"; exit 0
  fi
fi

# 6. Is the scope a label the board can be asked about? A bare-number scope
#    ("ticket 9822") is single-ticket mode and is MEANT to stop after one.
[ -f "$LABEL_FILE" ] || { say "exit0 no-label-file"; exit 0; }
SCOPE=$(cut -f1 < "$LABEL_FILE" | head -1)
[ -n "$SCOPE" ] || { say "exit0 empty-scope"; exit 0; }
#    The scope "auto" is /auto's own marker for "the whole board" — not a label.
#    Asking for --label auto returns an empty list, which would read as dry and
#    silence this hook for the one flow most meant to keep going.
LABEL_ARGS=(--label "$SCOPE")
case "$SCOPE" in
  ticket\ *|"") say "exit0 single-ticket-scope [$SCOPE]"; exit 0 ;;
  auto)         LABEL_ARGS=() ;;
esac

# 7. The measurement: does this scope still have runnable tickets? This is the
#    observable state work.md demands — never "until the context is full", which
#    can only be met by burning tokens.
#
#    Query the configured repo by its canonical slug. Asking through a repo
#    REDIRECT silently returns 0, which would read as "dry" and permanently
#    silence this hook.
#
#    A 15s cache keeps a chatty session from hitting the API every stop.
CACHE="$MDIR/$SID.ready"
READY=""
if [ -f "$CACHE" ]; then
  CAGE=$(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  [ "$CAGE" -lt 15 ] && READY=$(cat "$CACHE" 2>/dev/null)
fi
if [ -z "$READY" ]; then
  READY=$(gh issue list --repo "$REPO" --state open \
            "${LABEL_ARGS[@]}" --label status:ready --limit 100 \
            --json number -q 'length' 2>/dev/null) || READY=""
  [ -n "$READY" ] && printf '%s' "$READY" > "$CACHE"
fi

# gh unreachable, unauthenticated, or the label does not exist -> UNKNOWN, and an
# unknown is not a reason to hold the turn open. Same rule as "no live claims
# accompanied by a stderr line is UNKNOWN, never an empty rung" — but erring the
# other way, because a false nag costs Dom an interruption.
[ -n "$READY" ] || { say "exit0 ready-unknown scope=$SCOPE"; exit 0; }
[ "$READY" -le 0 ] 2>/dev/null && { say "exit0 scope-dry scope=$SCOPE"; exit 0; }

# Nag.
touch "$MARK"; echo $(( N + 1 )) > "$COUNT"
say "exit2 nagging scope=$SCOPE ready=$READY nag=$((N+1))/$MAX_NAGS session=$SID"
cat >&2 <<EOF
You are in a /work or /auto loop and you stopped with $READY runnable tickets
still in scope "$SCOPE". No stop condition was recorded.

Take the next one. Re-triage from /auto Step 1 (your own merge may have turned
trunk red), then \`/claim <n>\` and ship it. No check-in, no "shall I continue".

If a stop condition DID fire — the runnable list is empty, a gate will not go
green after real effort, a migration will not apply, a spec ambiguity only the PM
can resolve, or a permission-gate denial — record it and stop:

  echo "<the condition, in one line>" > $TDIR/.stop-reason

A permission-gate denial, reasoned or not, OUTRANKS this hook: hold and surface,
never route around it. Writing the stop reason is the correct response to one.
EOF
exit 2
