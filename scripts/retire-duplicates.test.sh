#!/usr/bin/env bash
# Self-test for retire-duplicates.sh and check-single-source.sh, against a fake
# CLAUDE_CONFIG_DIR — nothing real is read or moved.
D="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$D/.." && pwd)"; fail=0
ok(){ echo "ok   $1"; }; bad(){ echo "FAIL $1"; fail=1; }
C=$(mktemp -d); REPO=$(mktemp -d); trap 'rm -rf "$C" "$REPO"' EXIT
export CLAUDE_CONFIG_DIR="$C" CLAUDE_PLUGIN_ROOT="$KIT"

mkdir -p "$C/commands" "$C/agents" "$C/hooks/lib"
: > "$C/commands/claim.md"                 # the plugin ships /claim
: > "$C/commands/my-own-thing.md"          # it does not ship this
: > "$C/agents/gate-runner.md"
: > "$C/hooks/keep-working.sh"; : > "$C/hooks/keep-working.test.sh"
: > "$C/hooks/no-broad-kill.sh"; : > "$C/hooks/no-broad-kill.py"; : > "$C/hooks/no-broad-kill.cases.tsv"
: > "$C/hooks/lib/claude-session.sh"
cat > "$C/settings.json" <<'S'
{"model":"opus","hooks":{
  "Stop":[{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/keep-working.sh"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[
     {"type":"command","command":"bash ~/.claude/hooks/no-broad-kill.sh"},
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
printf '%s' "$out" | grep -q 'no-broad-kill.py' && ok "the python judge goes with its wrapper" \
  || bad "the python judge was not listed"

echo "--- apply ---"
bash "$D/retire-duplicates.sh" >/dev/null 2>&1
A="$C/retired-$(date +%Y-%m-%d)"
[ ! -e "$C/commands/claim.md" ] && [ -f "$A/commands/claim.md" ] && ok "the duplicate command was moved, not deleted" || bad "commands/claim.md"
[ -f "$C/commands/my-own-thing.md" ] && ok "the unshipped command was left alone" || bad "an unshipped command was moved"
[ -f "$A/hooks/no-broad-kill.cases.tsv" ] && ok "the case table went with it" || bad "cases.tsv left behind"
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

[ "$fail" -eq 0 ] && echo "retire-duplicates: all cases pass"
exit $fail
