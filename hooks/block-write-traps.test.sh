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
