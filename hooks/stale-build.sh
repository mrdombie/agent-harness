#!/usr/bin/env bash
# SessionStart — warn when this session loaded an older kit than the newest one
# installed beside it. A session keeps the build it opened with: on 2026-10-16 a
# /loop session ran 0.7.40, which had no coordinator, while 0.7.46 was installed,
# and built four tickets in the chat because of it.
#
# The installed builds are the version directories beside this one (the plugin
# cache keeps one per version). Nothing to compare, nothing said.
# Self-test: hooks/stale-build.test.sh
set -u
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
mine=$(jq -r '.version // empty' "$KIT/.claude-plugin/plugin.json" 2>/dev/null)
[ -n "$mine" ] || exit 0
newest=$(for d in "$(dirname "$KIT")"/*/; do
           jq -r '.version // empty' "$d.claude-plugin/plugin.json" 2>/dev/null
         done | awk 'NF' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
[ -n "$newest" ] && [ "$newest" != "$mine" ] || exit 0
msg="agent-harness: this session runs the kit at $mine, but $newest is installed. A session keeps the build it started with, so restart it to pick up $newest (the coordinator routing, guards and fixes since $mine). Say this to the operator."
jq -nc --arg c "$msg" '{systemMessage:$c, hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
exit 0
