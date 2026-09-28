#!/usr/bin/env bash
# PreToolUse(Bash): refuse pkill/killall patterns that hit every agent on the machine.
# One agent's `pkill -f 'next dev apps/'` killed four peers' servers (2026-09-24).
#
# The two project facts the judge needs — the branch prefix and the worktree root
# — come from .claude/harness.json and are passed in the environment. Outside a
# configured checkout the judge falls back to generic shapes rather than going
# inert: a guard that stops firing where it cannot read a config is not a guard.
#
# Self-test: hooks/no-broad-kill.test.sh
cmd=$(jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
if [ -f "$_cfg" ]; then
  eval "$(jq -r '"_bp=\(.branchPrefix // "" | @sh) _wt=\(.worktreeRoot // "" | @sh)"' "$_cfg" 2>/dev/null)"
fi
export HARNESS_BRANCH_PREFIX="${HARNESS_BRANCH_PREFIX:-${_bp:-}}"
export HARNESS_WORKTREE_ROOT="${HARNESS_WORKTREE_ROOT:-${_wt:-}}"
exec python3 "$(dirname "$0")/no-broad-kill.py" "$cmd"
