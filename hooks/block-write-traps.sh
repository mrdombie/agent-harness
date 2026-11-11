#!/usr/bin/env bash
# PreToolUse (Write|Edit): the write-time traps.
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
# 5. NEW CHECK SCRIPT — a check is a lint rule, an import rule or knip config unless it
#    needs data no linter can see. A brand-new scripts/check-* file is refused unless it
#    says so on a `needs-outside-data:` line. On the estate this came from, 128 check
#    scripts were added one bug at a time, 8 were lint rules, and their repo-scanning
#    tests cost ~150 s on every change (2026-11-09). Editing an existing check is allowed.
#
# 6. A GLOB OVER A STATE DIRECTORY AS ARGUMENTS — `ls -t "$SWARM_LOGS"/claim-*.log` is not
#    run at all once the names pass ARG_MAX, and with its error discarded the reader sees
#    nothing (2026-11-11: every usage reader, for hours). Refused as it is written into a
#    shell script; scripts/check-argv-json.sh --globs is the rule, and CI runs the same.
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

# 5. new check script
case "$f" in
  */scripts/check-*/index.ts|*/scripts/check-*/index.mjs|*/scripts/check-*/index.js|*/scripts/check-*/index.sh|*/scripts/check-*.sh|*/scripts/check-*.ts|*/scripts/check-*.mjs)
    case "$f" in *.test.*) ;; *)
      if [ ! -e "$f" ]; then
        content=$(printf '%s' "$payload" | jq -r '.tool_input.content // ""' 2>/dev/null || echo "")
        if ! grep -qE 'needs-outside-data:[[:space:]]*[^[:space:]]' <<<"$content"; then
          deny "A new check starts as a lint rule, not a script: an ESLint rule (the editor flags it as it is written), an import rule (no-restricted-imports or dependency-cruiser) for 'only one home for X', or knip config for dead code and orphans. Its test runs on small fixture files, never the real repo. Write a check script only when it needs data no linter can see (a hosting provider's variables, the database, a build's output), and say what on a line: needs-outside-data: <what it reads>."
        fi
      fi ;;
    esac ;;
esac

# 6. a glob over a state directory as arguments
case "$f" in
  *.test.sh|*/tests/*|*/fixtures/*) ;;
  */scripts/*.sh|*/swarm/*.sh|*/driver/*.sh|*/hooks/*.sh|*/driver/build-ticket)
    content=$(printf '%s' "$payload" | jq -r '.tool_input.content // .tool_input.new_string // ""' 2>/dev/null || echo "")
    _chk="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/scripts/check-argv-json.sh"
    if [ -n "$content" ] && [ -f "$_chk" ] && grep -q '\*' <<<"$content"; then
      _t=$(mktemp) && printf '%s\n' "$content" > "$_t"
      _hits=$(bash "$_chk" --globs "$_t" 2>/dev/null | sed "s|^$_t:|line |" | cut -c1-300 | head -5) || true
      rm -f "$_t"
      [ -z "$_hits" ] || deny "A glob over a state directory is being passed to a command as arguments. Past ARG_MAX the command is never run and the reader sees nothing (2026-11-11: 13,616 logs, every usage reader blind). List through swarm_newest_logs, loop with 'for f in <glob>', or use find; a list that is truly bounded says so with '# argv-bounded: <why>' on its line. $_hits"
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
