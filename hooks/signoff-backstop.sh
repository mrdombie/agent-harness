#!/usr/bin/env bash
# Backstop for the agent sign-off banner (.claude/shared/agent-signoff.md).
#
# WHY: the operator loses track of which area an agent was on and starts a second agent on
# work already in flight. The flow files carry the rule; a written rule is not
# enforcement. This makes the model print the banner when it forgot.
#
# A Stop hook CANNOT print to the user's terminal — measured 2026-09-04: plain
# stdout goes to the debug log, and stdout is surfaced only for UserPromptSubmit,
# UserPromptExpansion, SessionStart and PostModelSwitch. So the only way to get a
# line in front of the operator is exit 2, which feeds the reason back and continues the
# turn. Measured: banner absent -> num_turns 2 and the banner printed; banner
# present -> num_turns 1 and the hook silent.
#
# A blocking Stop hook is how /goal looped ~20x on 2026-08-30. FOUR guards below,
# each of which alone ends the turn. The common path is guard 4 — one file read
# and a grep.
set -uo pipefail

IN=$(cat)
LOG=/tmp/claude-signoff-backstop.log
say() { echo "$(date -u +%FT%TZ) $*" >> "$LOG"; }

# 0. A DRIVER STEP IS NOT A PERSON'S TURN. The driver exports HARNESS_DRIVER_RUN
#    for the step it is running, and both Stop hooks stand down on it. Measured on
#    the 2026-09-27 trial: this hook's exit 2 made the model replace its whole final
#    answer with the four-line banner, so the driver read no JSON at all on either
#    ticket and both runs parked at step 1 of 7. A banner is an instruction to an
#    operator's terminal; there is no operator here, and nothing to keep track of
#    that the run record does not already hold.
[ -n "${HARNESS_DRIVER_RUN:-}" ] && { say "exit0 driver-run ${HARNESS_DRIVER_RUN}"; exit 0; }

# 1. The documented escape hatch. We have already blocked once this turn.
[ "$(printf '%s' "$IN" | jq -r '.stop_hook_active // false')" = "true" ] && {
  say "exit0 stop_hook_active"; exit 0; }

# 2. Cooldown. At most one nag per session per 10 minutes, so a model that keeps
#    forgetting costs one extra turn occasionally, never one per turn.
SID=$(printf '%s' "$IN" | jq -r '.session_id // "nosession"')
MDIR="${TMPDIR:-/tmp}/claude-signoff-backstop"; mkdir -p "$MDIR"
MARK="$MDIR/$SID"
if [ -f "$MARK" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$MARK" 2>/dev/null || stat -f %m "$MARK" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt 600 ] && { say "exit0 cooldown ${AGE}s $SID"; exit 0; }
fi

# 3. Is there project work in play at all? .session-label is written by every work
#    flow when its scope resolves. Stale = no live flow, so treat as absent.
#    PROXY, named: a label written in the last 6 hours stands in for "a work flow
#    is running". It is shared across sessions, so a second session asking about
#    something else gets the banner too — that is wanted, it is the exact moment
#    the operator would otherwise start a duplicate agent.
# The kit's own files: the plugin root when run as a plugin hook, else this file's parent.
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
# The state dir: env overrides first, then the checkout's harness.json. A session
# outside any checkout is the CASE THIS HOOK EXISTS FOR (the operator starts
# sessions in a skills folder), so with no config it falls back to the env
# overrides alone and only goes quiet when those are unset too.
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
[ -f "$_cfg" ] && eval "$(jq -r '"CFG_STATE_DIR=\(.stateDir // "" | @sh) CFG_LEGACY_PREFIX=\(.legacyEnvPrefix // "" | @sh)"' "$_cfg" 2>/dev/null)"
# A project may declare legacyEnvPrefix in harness.json (or HARNESS_LEGACY_ENV_PREFIX)
# so an older env prefix its fixtures pin still counts; the kit names none itself.
_lp="${HARNESS_LEGACY_ENV_PREFIX:-${CFG_LEGACY_PREFIX:-}}"; _lv=""
[ -n "$_lp" ] && { _n="${_lp}_STATE_DIR"; _lv="${!_n:-}"; }
STATE_DIR="${HARNESS_STATE_DIR:-${_lv:-${CFG_STATE_DIR:-}}}"
[ -n "$STATE_DIR" ] || STATE_DIR=$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null || true)   # the resolver's last-seen value
STATE_DIR="${STATE_DIR/#\~/$HOME}"
[ -n "$STATE_DIR" ] || { say "exit0 no-state-dir"; exit 0; }
LABEL_FILE="$STATE_DIR/.session-label"
[ -f "$LABEL_FILE" ] || { say "exit0 no-label-file"; exit 0; }
LAGE=$(( $(date +%s) - $(stat -c %Y "$LABEL_FILE" 2>/dev/null || stat -f %m "$LABEL_FILE" 2>/dev/null || echo 0) ))
[ "$LAGE" -gt 21600 ] && { say "exit0 label-stale ${LAGE}s"; exit 0; }
SCOPE=$(cut -f1 < "$LABEL_FILE" | head -1)
[ -n "$SCOPE" ] || { say "exit0 empty-scope"; exit 0; }

# 4. Is this scope even ours? .session-label is ONE global slot written by every
#    work flow across every concurrent agent, so the scope it holds belongs to
#    the last writer, not necessarily to this session. Demanding a banner for a
#    peer's scope produces a WRONG banner, and agent-signoff.md is explicit that
#    a stale roster is worse than none — it is the one fact the operator acts on.
#    Measured 2026-09-18: this hook made one session print another session's
#    area three times.
#
#    Unowned or stale-owned falls through, so a solo session is unaffected.
# shellcheck source=lib/claude-session.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/claude-session.sh" 2>/dev/null || say "warn no-session-lib"
if declare -F scope_owned_by_peer >/dev/null 2>&1; then
  if PEER=$(scope_owned_by_peer "${LABEL_FILE}.owner"); then
    say "exit0 not-my-scope owner=$PEER scope=$SCOPE"; exit 0
  fi
fi

# 5. The common path — the flow already complied.
LAST=$(printf '%s' "$IN" | jq -r '.last_assistant_message // ""')
printf '%s' "$LAST" | grep -qF '🏷️ Working on:' && { say "exit0 banner-present $SCOPE"; exit 0; }

# Nag. Once.
touch "$MARK"
say "exit2 nagging scope=$SCOPE session=$SID"
cat >&2 <<EOF
You ended a turn without the sign-off banner, and there is live work under the
scope "$SCOPE".

Print the banner now — read "$KIT/shared/agent-signoff.md" for the rules, and
read the live claims in THIS turn rather than from memory:

  "$KIT/scripts/claim-lock.sh" list --json

The first line must begin with the literal string "🏷️ Working on:". Add nothing
else — no apology, no explanation of this message, no re-doing the work.
EOF
exit 2
