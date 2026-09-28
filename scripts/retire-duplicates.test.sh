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
: > "$C/hooks/lib/my-own-lib.sh"          # the plugin ships no copy of this
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
# FILE BY FILE. Moving the directory took a machine's own library with it and
# broke every surviving hook that sourced it, silently — the LEFT ALONE report
# only scans commands/.
[ -f "$C/hooks/lib/my-own-lib.sh" ] && ok "a library the plugin does not ship stayed put" \
  || bad "a machine-local library was moved with the directory"

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

echo "--- a name is a path COMPONENT, not a substring ---"
# A machine's own hook whose name merely contains one of ours was silently
# un-registered and reported under the plugin's name, leaving its file behind
# as an orphan nobody is looking for.
C2=$(mktemp -d); mkdir -p "$C2/hooks"
: > "$C2/hooks/my-keep-working.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/my-keep-working.sh"}]}]}}' > "$C2/settings.json"
o=$(CLAUDE_CONFIG_DIR="$C2" bash "$D/retire-duplicates.sh" --check 2>&1)
printf '%s' "$o" | grep -q 'keep-working' && bad "a machine's own my-keep-working.sh was claimed as ours" \
  || ok "a hook whose name merely contains ours is left alone"
o=$(CLAUDE_CONFIG_DIR="$C2" HOME="$C2" CLAUDE_PLUGIN_ROOT="$KIT" bash "$D/check-single-source.sh" /nonexistent 2>&1)
printf '%s' "$o" | grep -q 'REGISTERED' && bad "the gate reported a false duplicate on it" \
  || ok "and the gate does not report it either"
# the control: the plugin's OWN name must still be caught, or the case above
# passes because nothing matches anything.
: > "$C2/hooks/keep-working.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/keep-working.sh"}]}]}}' > "$C2/settings.json"
o=$(CLAUDE_CONFIG_DIR="$C2" HOME="$C2" CLAUDE_PLUGIN_ROOT="$KIT" bash "$D/check-single-source.sh" /nonexistent 2>&1)
printf '%s' "$o" | grep -q 'REGISTERED' && ok "and the plugin's own name IS still caught" \
  || bad "the control failed — nothing matches anything"
rm -rf "$C2"

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

echo "--- a kit that ships no hooks, and one that ships nothing ---"
# Both scripts are written as reusable project-agnostic tools, and hooks are
# optional in a plugin. Ten array expansions were still bare, so an empty
# HOOKS/SKILLS died with the same `unbound variable` the first fix was about.
EK=$(mktemp -d); mkdir -p "$EK/skills" "$EK/hooks" "$EK/.claude-plugin"
echo '{"hooks":{}}' > "$EK/hooks/hooks.json"
cp "$KIT/hooks/registered-hooks.jq" "$EK/hooks/"
echo '{"name":"empty","version":"0"}' > "$EK/.claude-plugin/plugin.json"
EC=$(mktemp -d); mkdir -p "$EC/commands"; : > "$EC/commands/x.md"; echo '{}' > "$EC/settings.json"
CLAUDE_CONFIG_DIR="$EC" CLAUDE_PLUGIN_ROOT="$EK" bash "$D/retire-duplicates.sh" --check >/dev/null 2>&1
[ $? -le 1 ] && ok "the migration runs against a kit with no hooks" || bad "it died on an empty HOOKS array"
CLAUDE_CONFIG_DIR="$EC" CLAUDE_PLUGIN_ROOT="$EK" bash "$D/check-single-source.sh" /nonexistent >/dev/null 2>&1
[ $? -le 1 ] && ok "and so does the gate" || bad "the gate died on an empty HOOKS array"
# A kit with no rule file at all must REFUSE, not report clean: an unreadable
# read answering "nothing is registered" is the silently-inert answer.
NK=$(mktemp -d); mkdir -p "$NK/.claude-plugin"; echo '{"name":"n","version":"0"}' > "$NK/.claude-plugin/plugin.json"
CLAUDE_CONFIG_DIR="$EC" CLAUDE_PLUGIN_ROOT="$NK" bash "$D/check-single-source.sh" /nonexistent >/dev/null 2>&1
[ $? -eq 2 ] && ok "a kit whose rule file is unreadable refuses to report clean" \
  || bad "an unreadable rule file was reported as 'nothing registered'"
rm -rf "$EK" "$EC" "$NK"

echo "--- and the gate can fail ---"
mkdir -p "$REPO/.claude/skills/finish"; : > "$REPO/.claude/skills/finish/SKILL.md"
HOME="$C" bash "$D/check-single-source.sh" "$REPO" >/dev/null 2>&1 \
  && bad "a repo copy of a plugin skill passed the gate" || ok "a repo copy of a plugin skill fails the gate"

[ "$fail" -eq 0 ] && echo "retire-duplicates: all cases pass"
exit $fail
