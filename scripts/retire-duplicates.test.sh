#!/usr/bin/env bash
# Self-test for retire-duplicates.sh and check-single-source.sh, against a fake
# CLAUDE_CONFIG_DIR — nothing real is read or moved.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
D="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$D/.." && pwd)"; fail=0
ok(){ echo "ok   $1"; }; bad(){ echo "FAIL $1"; fail=1; }
C=$(mktemp -d); REPO=$(mktemp -d); on_exit_keep_status 'rm -rf "$C" "$REPO"'
export CLAUDE_CONFIG_DIR="$C" CLAUDE_PLUGIN_ROOT="$KIT"

mkdir -p "$C/commands" "$C/agents" "$C/hooks/lib"
: > "$C/commands/claim.md"                 # the plugin ships /claim
: > "$C/commands/my-own-thing.md"          # it does not ship this
: > "$C/agents/gate-runner.md"
: > "$C/hooks/keep-working.sh"; : > "$C/hooks/keep-working.test.sh"
: > "$C/hooks/no-repo-wide-format.sh"; : > "$C/hooks/no-repo-wide-format.py"
: > "$C/hooks/lib/claude-session.sh"
# The old local name of the plugin's flows skill, edited on this machine.
mkdir -p "$C/skills/screen-flow-audit/references"
echo "local edit" > "$C/skills/screen-flow-audit/SKILL.md"
echo "rows" > "$C/skills/screen-flow-audit/references/rows.md"
echo "old flows command" > "$C/commands/flows.md"
cat > "$C/settings.json" <<'S'
{"model":"opus","hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/keep-working.sh"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[
     {"type":"command","command":"bash ~/.claude/hooks/no-repo-wide-format.sh"},
     {"type":"command","command":"bash ~/.claude/hooks/something-of-my-own.sh"}]}]}}
S

# The installed plugin must already register the hooks we are about to remove,
# or the apply path refuses. Every case below wants the apply path, so plant an
# install that DOES register them; the refusal itself is a case at the end.
mkdir -p "$C/plugins" "$C/fakeinstall"
cp -R "$KIT/hooks" "$C/fakeinstall/hooks"
cat > "$C/plugins/installed_plugins.json" <<INST
{ "plugins": { "agent-harness@agent-harness": [
    { "scope": "user", "installPath": "$C/fakeinstall" } ] } }
INST

echo "--- --check reports and changes nothing ---"
out=$(bash "$D/retire-duplicates.sh" --check 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "--check exits non-zero while duplicates exist" || bad "--check exited 0"
[ -f "$C/commands/claim.md" ] && ok "--check moved nothing" || bad "--check moved a file"
printf '%s' "$out" | grep -q 'my-own-thing.md' && ok "a command the kit does not ship is reported, not moved" \
  || bad "the unshipped command was not reported"
printf '%s' "$out" | grep -q 'no-repo-wide-format.py' && ok "the python judge goes with its wrapper" \
  || bad "the python judge was not listed"

printf '%s' "$out" | grep -q 'skills/screen-flow-audit' && ok "--check names the old screen-flow-audit skill" \
  || bad "--check did not name skills/screen-flow-audit"
printf '%s' "$out" | grep -q 'commands/flows.md' && ok "--check names the old flows command" \
  || bad "--check did not name commands/flows.md"
[ -f "$C/skills/screen-flow-audit/SKILL.md" ] && ok "--check left screen-flow-audit in place" || bad "--check moved screen-flow-audit"

echo "--- apply ---"
bash "$D/retire-duplicates.sh" >/dev/null 2>&1
A="$C/retired-$(date +%Y-%m-%d)"
[ ! -e "$C/commands/claim.md" ] && [ -f "$A/commands/claim.md" ] && ok "the duplicate command was moved, not deleted" || bad "commands/claim.md"
[ -f "$C/commands/my-own-thing.md" ] && ok "the unshipped command was left alone" || bad "an unshipped command was moved"
[ -f "$A/hooks/no-repo-wide-format.py" ] && ok "the python judge went with its wrapper" || bad "the .py was left behind"
[ ! -e "$C/skills/screen-flow-audit" ] && [ "$(cat "$A/skills/screen-flow-audit/SKILL.md" 2>/dev/null)" = "local edit" ] \
  && [ "$(cat "$A/skills/screen-flow-audit/references/rows.md" 2>/dev/null)" = "rows" ] \
  && ok "the old screen-flow-audit skill was moved intact, not deleted" || bad "skills/screen-flow-audit"
[ ! -e "$C/commands/flows.md" ] && [ "$(cat "$A/commands/flows.md" 2>/dev/null)" = "old flows command" ] \
  && ok "the old flows command was moved intact" || bad "commands/flows.md"
[ -f "$A/hooks/lib/claude-session.sh" ] && ok "the shared lib went with it" || bad "hooks/lib left behind"

echo "--- settings.json ---"
left=$(jq -r '[.hooks // {} | .[][].hooks[].command] | join(" ")' "$C/settings.json")
printf '%s' "$left" | grep -q 'keep-working' && bad "a plugin hook is still registered" || ok "the plugin's hooks are un-registered"
printf '%s' "$left" | grep -q 'something-of-my-own' && ok "a hook of the machine's own survives" || bad "an unrelated hook was dropped"
[ "$(jq -r '.model' "$C/settings.json")" = opus ] && ok "the rest of settings.json is untouched" || bad "settings.json lost other keys"
[ -f "$C/settings.json.before-$(date +%Y-%m-%d)" ] && ok "the previous settings.json is kept" || bad "no backup of settings.json"
jq -e '.hooks | to_entries[] | .value[] | select((.hooks|length)==0)' "$C/settings.json" >/dev/null 2>&1 \
  && bad "an empty hook group was left behind" || ok "no empty hook group left behind"

echo "--- it is idempotent, and the gate agrees ---"
out=$(bash "$D/retire-duplicates.sh" 2>&1)
printf '%s' "$out" | grep -q 'screen-flow-audit\|commands/flows.md' && bad "a second apply still lists the flows copies" \
  || ok "a second apply has nothing of flows to retire"
bash "$D/retire-duplicates.sh" --check >/dev/null 2>&1 && ok "a second --check is LEVEL" || bad "not idempotent"
HOME="$C" bash "$D/check-single-source.sh" "$REPO" --strict >/dev/null 2>&1 \
  && ok "check-single-source --strict passes afterwards" || bad "the gate still finds duplicates"

echo "--- it refuses to disarm the machine ---"
# The one ordering that loses every guard: remove the hooks and un-register them
# while the INSTALLED plugin does not yet register them. Done for real on
# 2026-09-28 — ten registrations became one and the install registered six of
# the nine.
: > "$C/hooks/keep-working.sh"
cat > "$C/settings.json" <<'S2'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"~/.claude/hooks/keep-working.sh"}]}]}}
S2
python3 - "$C/fakeinstall/hooks/hooks.json" <<'PY2'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for ev in d["hooks"]:
    for grp in d["hooks"][ev]:
        grp["hooks"]=[h for h in grp["hooks"] if "keep-working" not in h["command"]]
    d["hooks"][ev]=[g for g in d["hooks"][ev] if g["hooks"]]
json.dump(d,open(p,"w"))
PY2
out=$(bash "$D/retire-duplicates.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "it refuses when the install would not take over" || bad "it applied anyway (rc $rc)"
printf '%s' "$out" | grep -q 'keep-working.sh' && ok "and names the hook that would be left unguarded" \
  || bad "it did not name the unguarded hook"
[ -f "$C/hooks/keep-working.sh" ] && ok "and moved nothing" || bad "it moved a file while refusing"
grep -q 'keep-working' "$C/settings.json" && ok "and left the registration alone" || bad "it un-registered while refusing"
rm -rf "$C/fakeinstall" "$C/plugins/installed_plugins.json"
out=$(bash "$D/retire-duplicates.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "no readable install at all also refuses" || bad "it applied with no install to compare against"

echo "--- and the gate can fail ---"
mkdir -p "$REPO/.claude/skills/finish"; : > "$REPO/.claude/skills/finish/SKILL.md"
HOME="$C" bash "$D/check-single-source.sh" "$REPO" >/dev/null 2>&1 \
  && bad "a repo copy of a plugin skill passed the gate" || ok "a repo copy of a plugin skill fails the gate"

echo "--- no kit instruction names a skill this script retires ---"
olds=$(sed -n 's/^REPLACES=(\(.*\))$/\1/p' "$D/retire-duplicates.sh" | tr -d '"' | tr ' ' '\n' | sed -n 's/^[^:]*://p')
[ -n "$olds" ] && ok "read the retired names: $(printf '%s' "$olds" | tr '\n' ' ')" || bad "no REPLACES names read"
for o in $olds; do
  hits=$(cd "$KIT" && git ls-files 'skills/*' 'shared/*' 'agents/*' | xargs grep -n -F -- "$o" 2>/dev/null)
  [ -z "$hits" ] && ok "no kit instruction points at the retired $o" || bad "a kit instruction points at the retired $o: $hits"
done

[ "$fail" -eq 0 ] && echo "retire-duplicates: all cases pass"
suite_end "$fail"
