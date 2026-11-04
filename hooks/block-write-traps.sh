#!/usr/bin/env bash
# PreToolUse (Write|Edit): two write-time traps.
#
# The phantom-worktree-path and main-clone-edit traps are gone: they stopped one builder
# writing into a tree another used, and every builder now has a tree of its own, cut and
# installed by the driver (scripts/builder-install.sh).
#
# 3. CREDENTIAL IN MEMORY — never store a pasted key/token/secret in a memory
#    file. Deny when the written content matches a secret shape.
# 4. NEW TOOLING OUTSIDE THE KIT — a brand-new command or skill written into a
#    machine's own ~/.claude lives on that machine and nowhere else. It is the
#    duplication this kit exists to remove: two live copies of one thing,
#    silently disagreeing. Editing an EXISTING file stays allowed (the backlog
#    still has to be moved); creating one does not.
#
# The one project fact — where the shared clone lives — comes from the
# environment or the resolver's last-seen value; trap 4 reads it to tell a skill
# inside the project from one in ~/.claude.
#
# Self-test: hooks/block-write-traps.test.sh
set -euo pipefail
payload=$(cat)
f=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null || echo "")
[ -z "$f" ] && exit 0
deny(){ jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

_main="${HARNESS_MAIN_REPO:-}"
[ -n "$_main" ] || _main=$(cat "$HOME/.claude/.harness-last-main-repo" 2>/dev/null || true)

# 4. new tooling outside the kit
case "$f" in
  "$HOME"/.claude/commands/*.md|"$HOME"/.claude/skills/*/SKILL.md)
    _inrepo=0
    [ -n "${_main:-}" ] && case "$f" in "$_main"/*) _inrepo=1 ;; esac
    if [ "$_inrepo" -eq 0 ] && [ ! -e "$f" ]; then
      deny "New commands and skills are not born in ~/.claude — a copy there lives on one machine and nowhere else. Add it to the harness repo (skills/<name>/SKILL.md, reading project facts from .claude/harness.json), open a PR, merge, then update the plugin. If it is one project's own, put it in that repo's .claude/skills through a ticket."
    fi ;;
esac

# 3. credential written into memory
case "$f" in
  */memory/*.md)
    content=$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || echo "")
    # A here-string: under pipefail an early match on long content read as "no match".
    if grep -qE 'sk-ant-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abp]-[A-Za-z0-9-]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|Bearer [A-Za-z0-9._-]{30,}|sk-[A-Za-z0-9]{32,}' <<<"$content"; then
      deny "That looks like a credential. Never store a key, token or secret in memory: treat it as compromised and point to the project's secret store instead."
    fi ;;
esac
exit 0
