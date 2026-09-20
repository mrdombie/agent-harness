#!/usr/bin/env bash
# SessionStart — say which kit skills this repo overrides, once, in one line each.
#
# Plugin skills are namespaced by Claude Code (/agent-harness:claim), so a repo's
# own .claude/skills/<name> never collides with the kit's copy: the repo's is
# invoked bare (/claim), the kit's is always /agent-harness:<name>. That makes a
# shadow silent, which is the problem — an operator typing /claim gets the repo's
# version and nothing says so. This prints the fact at session start.
set -u
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$ROOT" ] && [ -d "$ROOT/.claude/skills" ] || exit 0
out=""
for d in "$KIT"/skills/*/; do
  n=$(basename "$d")
  [ -f "$ROOT/.claude/skills/$n/SKILL.md" ] && out="${out}agent-harness: /$n is this repo's own — the kit's copy is /agent-harness:$n
"
done
[ -n "$out" ] || exit 0
jq -nc --arg c "$out" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
