#!/usr/bin/env bash
# PreToolUse(Bash): refuse formatter runs over whole folders, and whole-app checks
# from a spawned agent. An agent reflowed 248 files it never touched by formatting
# two whole source folders; the integration branch is only diff-formatted, so they
# nearly got committed into an unrelated PR (2026-09-23). Format what you changed.
#
# Only commands actually run count — the same words inside a quoted string or a
# brief are ignored.
#
# Self-test: hooks/no-repo-wide-format.test.sh
cmd=$(jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
if [ -f "$_cfg" ]; then
  _gc=$(jq -r '(.gates.changed // []) | join(" && ")' "$_cfg" 2>/dev/null)
  _fc=$(jq -r '.gates.formatChanged // ""' "$_cfg" 2>/dev/null)
  [ -n "$_gc" ] && export HARNESS_GATES_CHANGED="$_gc"
  [ -n "$_fc" ] && export HARNESS_FORMAT_CHANGED="$_fc"
fi
. "$(dirname "$0")/lib/python.sh"
harness_python || harness_python_refuse no-repo-wide-format
exec "${HARNESS_PY[@]}" "$(dirname "$0")/no-repo-wide-format.py" "$cmd"
