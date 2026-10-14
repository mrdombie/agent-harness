#!/usr/bin/env bash
# SessionStart — put the kit's standing rules in front of every session.
#
# WHY A HOOK AND NOT A FILE
#   Claude Code loads CLAUDE.md from a machine's ~/.claude and from the repo. A
#   plugin has no such slot, so rules that ship with the plugin reach a session
#   only by being injected. Measured 2026-09-28, the reason this matters: a
#   second machine started running agents against the same project and inherited
#   none of the first machine's ~/.claude — same repo, same plugin, different
#   behaviour, and nothing said so.
#
#   Injecting them makes the plugin the thing that carries them, so installing
#   it is the whole setup.
#
# WHAT IT EMITS
#   rules/standing-rules.md, verbatim. A project's own rules are NOT emitted
#   here: Claude Code already loads the repo's CLAUDE.md / AGENTS.md, and
#   emitting them twice is the duplication this ticket exists to remove.
#
#   One project fact is appended: `preApprovedWrites` in .claude/harness.json,
#   the environments whose writes the operator approved in advance. The rules
#   file says a general policy is not a yes; this is the one written exception,
#   and an agent can only honour it if it reaches the session. Absent: nothing
#   appended. Malformed: a line saying nothing is pre-approved (fails closed).
#
# Self-test: hooks/standing-rules.test.sh
set -u
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$KIT/rules/standing-rules.md"
[ -f "$F" ] || exit 0
command -v jq >/dev/null || exit 0
_cfg="${HARNESS_CFG_PATH:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}/.claude/harness.json}"
_pre=""
if [ -f "$_cfg" ]; then
  # Exit 3 = key absent; any other failure = present but unreadable as the shape.
  _pre=$(jq -r '
    if has("preApprovedWrites") | not then halt_error(3) else .preApprovedWrites end
    | if type == "object" and (.environments | type) == "array"
         and (.environments | length) > 0
         and all(.environments[]; type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
      then "\(.environments | join(", "))\t\(.decided // "" | tostring)"
      else error("shape") end
  ' "$_cfg" 2>/dev/null); _rc=$?
  if [ $_rc -eq 3 ]; then _pre=""
  elif [ $_rc -ne 0 ] || [ -z "$_pre" ]; then _pre="MALFORMED"
  fi
fi
{
  cat "$F"
  if [ "$_pre" = MALFORMED ]; then
    printf '\n## Writes this project'"'"'s operator pre-approved\n\n'
    printf '%s\n' "\`.claude/harness.json\` carries \`preApprovedWrites\`, but not in the shape \`{\"environments\": [\"<name>\", ...]}\`, so nothing is pre-approved. Every write still needs the operator's own yes."
  elif [ -n "$_pre" ]; then
    _envs="${_pre%%$'\t'*}"; _by="${_pre#*$'\t'}"
    printf '\n## Writes this project'"'"'s operator pre-approved\n\n'
    printf '%s\n' "The operator has approved, in advance, writes against: **$_envs**${_by:+ (decided: $_by)}. Source: \`preApprovedWrites\` in \`.claude/harness.json\`. In those environments a write (a back-fill, a one-off script, a data fix) may run without asking first, in a subagent too. This is the only general policy that counts as a yes, and only for the environments named."
    printf '\n%s\n' "It never covers:"
    printf '%s\n' "- **An outward-facing action, in any environment, these included:** publishing to a real account, sending email or messages, anything a person outside the team receives or sees. Each one still needs the operator's own yes, every time."
    printf '%s\n' "- **Any environment not named above**, production above all."
    printf '%s\n' "- **A command refused at a permission prompt.** A refusal is still final."
    printf '%s\n' "- **Changing this key.** Only the operator adds or widens it. An agent that edits it has approved itself."
  fi
} | jq -Rsc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}'
exit 0
