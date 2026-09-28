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
# Self-test: hooks/standing-rules.test.sh
set -u
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
F="$KIT/rules/standing-rules.md"
[ -f "$F" ] || exit 0
command -v jq >/dev/null || exit 0
jq -Rsc '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:.}}' < "$F"
exit 0
