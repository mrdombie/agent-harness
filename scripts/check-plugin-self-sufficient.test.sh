#!/usr/bin/env bash
# Does installing the PLUGIN ALONE give a machine the standing rules and the
# guards? Run against a clean HOME, so nothing a developer's own ~/.claude
# happens to carry can make this pass.
#
# WHY IT IS A TEST AND NOT A CHECKLIST
#   A second machine started running agents against the same project on
#   2026-09-28 and inherited none of the first machine's ~/.claude. "Both
#   machines load one identical set" is only true if something asserts it, and
#   the thing that asserts it has to fail when a rule or a hook is dropped from
#   the plugin — which is exactly the case a human eyeballing a diff misses.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok(){ echo "ok   $1"; }; bad(){ echo "FAIL $1"; fail=1; }
H=$(mktemp -d)/clean-home; mkdir -p "$H"
PROJ=$(mktemp -d); mkdir -p "$PROJ/.claude"
trap 'rm -rf "$H" "$PROJ"' EXIT
cat > "$PROJ/.claude/harness.json" <<'CFG'
{ "repo": "owner/repo", "integrationBranch": "trunk", "branchPrefix": "t-",
  "stateDir": "/tmp/nonexistent-state",
  "gates": { "changed": ["just check"] },
  "worktreeRoot": "/tmp/nonexistent-wt" }
CFG
export HARNESS_CFG_PATH="$PROJ/.claude/harness.json"

echo "--- the standing rules reach a session, from the plugin alone ---"
ctx=$(HOME="$H" CLAUDE_PLUGIN_ROOT="$KIT" bash "$KIT/hooks/standing-rules.sh" \
      | jq -r '.hookSpecificOutput.additionalContext')
# One phrase per rule the ticket names. Drop a rule from the file and this fails.
for phrase in "Picture first" "Every finding carries a grade" "Finish before you start" \
              "Run only what the change touches" "nothing later" "Two rounds, then it ships" \
              "Name the proxy" "Where tooling lives"; do
  printf '%s' "$ctx" | grep -q "$phrase" && ok "carries: $phrase" || bad "the rules do not carry: $phrase"
done
[ "${#ctx}" -gt 2000 ] && ok "the rules are non-empty (${#ctx} chars)" \
                       || bad "the rules came back nearly empty (${#ctx} chars)"

echo "--- every registered hook is present, executable, and in the plugin ---"
while read -r n; do
  [ -n "$n" ] || continue
  if [ -x "$KIT/hooks/$n" ]; then ok "registered and present: $n"
  else bad "registered but missing or not executable: $n"; fi
done < <(jq -r '[.hooks[][].hooks[].command] | .[] | capture("hooks/(?<n>[A-Za-z0-9._-]+)").n' \
           "$KIT/hooks/hooks.json" | sort -u)
# EVERY command, not "the string appears somewhere". One surviving occurrence
# satisfied a grep, so rewriting a single command to an absolute machine path —
# the exact duplication this release removes — passed.
notrooted=$(jq -r '[.hooks[][].hooks[].command] | .[] | select(contains("${CLAUDE_PLUGIN_ROOT}") | not)' \
              "$KIT/hooks/hooks.json")
[ -z "$notrooted" ] && ok "every command is addressed from the plugin root" \
  || bad "a hook command is not addressed from the plugin root: $notrooted"

# AND THE OTHER DIRECTION, which is the one that hides. A hook file that ships
# but is registered nowhere never runs, and a hook that never runs is
# indistinguishable from a hook that found nothing. Dropping no-broad-kill from
# hooks.json left every case above green until this was added.
reg=$(jq -r '[.hooks[][].hooks[].command] | .[] | capture("hooks/(?<n>[A-Za-z0-9._-]+)").n' \
        "$KIT/hooks/hooks.json" | sort -u)
for f in "$KIT"/hooks/*.sh; do
  n=$(basename "$f")
  case "$n" in *.test.sh) continue ;; esac
  printf '%s\n' "$reg" | grep -qx "$n" && continue
  bad "hooks/$n ships but hooks.json registers it nowhere — it can never fire"
done
ok "every shipped hook is registered"


echo "--- the guards fire under a clean HOME ---"
# CLAIM_RUN_LOG is UNSET unless a case asks for it. This suite is itself often
# run from inside a spawned claim, which exports it — so inheriting it silently
# turned the "an interactive session is not refused" case into a second copy of
# the case above it, and it reported the guard as broken when it was correct.
bash_rc(){ printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$1" '$c')" \
             | HOME="$H" env -u CLAIM_RUN_LOG "${3:-IGNORE=1}" bash "$KIT/hooks/$2" >/dev/null 2>&1; echo $?; }
[ "$(bash_rc "pkill -f 'next dev'" no-broad-kill.sh)" = 2 ] \
  && ok "no-broad-kill refuses a pattern that would hit a peer" || bad "no-broad-kill did not fire"
[ "$(bash_rc "npx prettier --write src/" no-repo-wide-format.sh)" = 2 ] \
  && ok "no-repo-wide-format refuses a whole folder" || bad "no-repo-wide-format did not fire"
[ "$(bash_rc "npm run typecheck" no-repo-wide-format.sh CLAIM_RUN_LOG=/tmp/f)" = 2 ] \
  && ok "an unattended agent is refused a whole-app typecheck" || bad "the whole-app typecheck was allowed"
[ "$(bash_rc "npm run typecheck" no-repo-wide-format.sh)" = 0 ] \
  && ok "and an interactive session is not" || bad "an interactive whole-app typecheck was refused"
d=$(printf '{"tool_input":{"command":"git push --no-verify"}}' | HOME="$H" bash "$KIT/hooks/block-push-no-verify.sh" \
    | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[ "$d" = deny ] && ok "block-push-no-verify refuses --no-verify" || bad "push --no-verify was allowed"
d=$(printf '{"tool_input":{"file_path":"%s/.claude/commands/brand-new.md","content":"x"}}' "$H" \
    | HOME="$H" bash "$KIT/hooks/block-write-traps.sh" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')
[ "$d" = deny ] && ok "block-write-traps refuses a command born outside the kit" || bad "a new personal command was allowed"

echo "--- the changed-only commands come from the project, not the kit ---"
out=$(printf '{"tool_input":{"command":"npm run typecheck"}}' \
      | HOME="$H" CLAIM_RUN_LOG=/tmp/f bash "$KIT/hooks/no-repo-wide-format.sh" 2>&1 >/dev/null)
printf '%s' "$out" | grep -q 'just check' \
  && ok "the refusal quotes gates.changed from the project's config" \
  || bad "the refusal did not read gates.changed"
# The SHIPPED hooks, not their self-tests: a test feeds those strings to a judge
# as INPUT, which is the opposite of a hook telling an agent to run them.
hardcoded=$(grep -lE 'npm run (lint|typecheck|test|format):changed' \
              "$KIT/hooks/"*.py "$KIT/hooks/"*.sh 2>/dev/null | grep -v '\.test\.sh$')
[ -z "$hardcoded" ] && ok "no shipped hook hardcodes a project's script names" \
  || bad "a shipped hook hardcodes one project's script names: $hardcoded"

echo
[ "$fail" -eq 0 ] && echo "plugin-self-sufficient: the plugin alone supplies the rules and the guards" \
                  || echo "plugin-self-sufficient: FAILURES"
exit $fail
