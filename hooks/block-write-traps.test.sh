#!/usr/bin/env bash
# Self-test for block-write-traps.sh — all four traps.
#
# The old version tested trap 4 only, and ran against the copy in a machine's
# ~/.claude rather than the one beside it. Both are fixed here: the subject is
# this directory's hook, and every trap has a deny case AND the allow case that
# proves the deny is not firing on everything.
H="$(cd "$(dirname "$0")" && pwd)/block-write-traps.sh"; fail=0
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
run(){ printf '{"tool_input":{"file_path":%s,"content":%s}}' \
         "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "${2:-x}" '$v')" \
       | env -u HARNESS_MAIN_REPO HOME="$HOME" HARNESS_MAIN_REPO="${MAIN:-}" bash "$H"; }
deny(){ o=$(run "$1" "${3:-x}"); if printf '%s' "$o" | grep -q '"deny"'; then echo "ok   deny  $2"; else echo "FAIL deny  $2"; fail=1; fi; }
allow(){ o=$(run "$1" "${3:-x}"); if [ -z "$o" ]; then echo "ok   allow $2"; else echo "FAIL allow $2"; fail=1; fi; }

# 1. phantom worktree path
deny  "/tmp/sh-99999-nope-abcdef/src/a.ts"          "a worktree path that does not exist"
mkdir -p "$TMP/real"; allow "$TMP/real/a.ts"        "a path whose directory exists"

# 2. main-clone edit — needs MAIN to be set, which is the point
MAIN="$TMP/clone"; mkdir -p "$MAIN/src" "$MAIN/.claude"
deny  "$MAIN/src/a.ts"                              "a source edit in the shared clone"
allow "$MAIN/.claude/skills/x/SKILL.md"             "the tooling tree in the shared clone"
MAIN=""
allow "$TMP/clone/src/a.ts"                         "no clone configured — trap 2 stands down"

# 2b. the SAME trap, DERIVED from the checkout rather than from any config.
# HARNESS_MAIN_REPO is only ever exported inside a skill's own subshell, so it
# does not reach a hook process; a clone path cannot be written into a config
# because it differs per machine. The path that actually runs is this one, and
# it was never exercised — `_cfg` was assigned and unused.
CLONE="$TMP/derived"; git init -q "$CLONE" 2>/dev/null
mkdir -p "$CLONE/src" "$CLONE/.claude"
WT="$TMP/derived-wt"
( cd "$CLONE" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x \
  && git worktree add -q "$WT" -b wt HEAD ) 2>/dev/null
drun(){ printf '{"tool_input":{"file_path":%s,"content":"x"}}' "$(jq -Rn --arg v "$1" '$v')" \
  | ( cd "${2:-$WT}" && env -u HARNESS_MAIN_REPO CLAUDE_PROJECT_DIR="${2:-$WT}" bash "$H" ); }
o=$(drun "$CLONE/src/b.ts")
printf '%s' "$o" | grep -q '"deny"' && echo "ok   deny  a source edit in the clone a worktree points at" \
  || { echo "FAIL deny  the clone was not derived from the checkout"; fail=1; }
o=$(drun "$CLONE/.claude/x.md")
[ -z "$o" ] && echo "ok   allow the tooling tree, same derivation" \
  || { echo "FAIL allow the tooling tree was denied"; fail=1; }
mkdir -p "$WT/src"
o=$(drun "$WT/src/b.ts")
[ -z "$o" ] && echo "ok   allow an edit in the WORKTREE, which is the point" \
  || { echo "FAIL allow editing your own worktree was denied"; fail=1; }

# 2c. THE BLAST-RADIUS CASES. The derivation returns the repo's own .git when
# you stand in a plain checkout, so the first version denied every source edit
# in any checkout that was not itself a worktree — and a relative $_main left
# the pattern as a bare `/*`, denying every absolute path on the machine. Both
# were invisible because every case above runs from inside a worktree with an
# absolute clone.
git init -q "$TMP/plain" 2>/dev/null; mkdir -p "$TMP/plain/src"
o=$(printf '{"tool_input":{"file_path":%s,"content":"x"}}' "$(jq -Rn --arg v "$TMP/plain/src/a.ts" '$v')" \
    | ( cd "$TMP/plain" && env -u HARNESS_MAIN_REPO CLAUDE_PROJECT_DIR="$TMP/plain" bash "$H" ))
[ -z "$o" ] && echo "ok   allow an edit in the ordinary clone you are standing in" \
  || { echo "FAIL allow a plain checkout was treated as somebody else's clone"; fail=1; }
for bad_main in "some/relative/path" "." ".." ""; do
  o=$(printf '{"tool_input":{"file_path":"/Users/somebody/unrelated.ts","content":"y"}}' \
      | HARNESS_MAIN_REPO="$bad_main" bash "$H")
  [ -z "$o" ] && echo "ok   allow an unrelated path, with _main='$bad_main'" \
    || { echo "FAIL allow _main='$bad_main' widened the pattern to everything"; fail=1; }
done

# 4. new tooling outside the kit
deny  "$HOME/.claude/commands/brand-new-$$.md"      "a new personal command"
deny  "$HOME/.claude/skills/brand-new-$$/SKILL.md"  "a new personal skill"
MAIN="$TMP/clone"; mkdir -p "$HOME/.claude/commands"
allow "$MAIN/.claude/skills/x/SKILL.md"             "a skill inside the configured repo"
MAIN=""

# 3. credential in memory
deny  "$TMP/real/memory/x.md" "a secret" "token: ghp_$(printf 'a%.0s' $(seq 32))"
mkdir -p "$TMP/real/memory"
allow "$TMP/real/memory/x.md" "ordinary memory content" "Dom prefers short replies."

[ "$fail" -eq 0 ] && echo "block-write-traps: all cases pass"
exit $fail
