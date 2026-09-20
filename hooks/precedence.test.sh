#!/usr/bin/env bash
# precedence.sh: one line per kit skill the repo shadows; silent when none.
H="$(cd "$(dirname "$0")" && pwd)/precedence.sh"; KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
T=$(mktemp -d); mkdir -p "$T/.claude/skills/claim" "$T/.claude/skills/design"; touch "$T/.claude/skills/claim/SKILL.md" "$T/.claude/skills/design/SKILL.md"
out=$(CLAUDE_PLUGIN_ROOT="$KIT" CLAUDE_PROJECT_DIR="$T" bash "$H")
ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
n=$(printf '%s' "$ctx" | grep -c 'agent-harness: /claim is this repo')
[ "$n" = 1 ] && echo "OK   shadowed /claim named once" || { echo "FAIL shadowed /claim named $n times"; fail=1; }
printf '%s' "$ctx" | grep -q '/design' && { echo "FAIL /design is not a kit skill and must not be listed"; fail=1; } || echo "OK   non-kit skill ignored"
rm -rf "$T/.claude/skills/claim"
out=$(CLAUDE_PLUGIN_ROOT="$KIT" CLAUDE_PROJECT_DIR="$T" bash "$H")
[ -z "$out" ] && echo "OK   silent when nothing is shadowed" || { echo "FAIL printed with nothing shadowed: $out"; fail=1; }
rm -rf "$T"; exit $fail
