#!/usr/bin/env bash
# Plant tests for standing-rules.sh: asserts the emitted context, then deletes the rule and expects failure.
H="$(cd "$(dirname "$0")" && pwd)/standing-rules.sh"
KIT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
TDIR=$(mktemp -d); trap 'rm -rf "$TDIR"' EXIT

ok(){ printf 'OK        %s\n' "$1"; }
bad(){ printf 'MISMATCH  %s\n' "$1"; fail=1; }

# The context a session gets from the kit rooted at $1.
context(){ CLAUDE_PLUGIN_ROOT="$1" bash "$H" </dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# The refused-command rule, by the three sentences an agent acts on.
has_rule(){
  grep -qF '"Rejected" is not proof a command did not run.' <<<"$1" &&
    grep -qF 'A refusal is final.' <<<"$1" &&
    grep -qF 'A one-off script against a shared environment ends.' <<<"$1"
}

# 1. The live kit: well-formed SessionStart output carrying the file verbatim.
out=$(CLAUDE_PLUGIN_ROOT="$KIT" bash "$H" </dev/null); rc=$?
[ $rc -eq 0 ] && ok "exits 0" || bad "exit $rc"
[ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" = SessionStart ] &&
  ok "names the SessionStart event" || bad "event name missing or wrong"
ctx=$(context "$KIT")
[ "$ctx" = "$(cat "$KIT/rules/standing-rules.md")" ] &&
  ok "context is the rules file verbatim" || bad "context differs from rules/standing-rules.md"
has_rule "$ctx" && ok "a session receives the refused-command rule" ||
  bad "the refused-command rule does not reach a session"

# 2. Death plant: the rule deleted from a copy of the kit.
mkdir -p "$TDIR/kit/rules"
awk '/^## A refused command, and one that may have run$/{skip=1; next} /^## /{skip=0} !skip' \
  "$KIT/rules/standing-rules.md" > "$TDIR/kit/rules/standing-rules.md"
grep -q '^## A refused command' "$TDIR/kit/rules/standing-rules.md" &&
  bad "plant did not land: section still in the copy"
pctx=$(context "$TDIR/kit")
[ -n "$pctx" ] && ok "planted kit still emits its other rules" || bad "planted kit emitted nothing"
has_rule "$pctx" && bad "rule deleted, yet the check still passes" ||
  ok "rule deleted: the check fails, as it must"

# 3. A kit with no rules file says nothing and does not fail the session.
mkdir -p "$TDIR/empty"
eout=$(CLAUDE_PLUGIN_ROOT="$TDIR/empty" bash "$H" </dev/null); rc=$?
[ $rc -eq 0 ] && [ -z "$eout" ] && ok "no rules file: silent, exit 0" ||
  bad "no rules file: exit $rc, output '${eout:0:60}'"

exit $fail
