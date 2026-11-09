#!/usr/bin/env bash
# Self-test for block-write-traps.sh — both traps.
#
# The old version tested trap 4 only, and ran against the copy in a machine's
# ~/.claude rather than the one beside it. Both are fixed here: the subject is
# this directory's hook, and every trap has a deny case AND the allow case that
# proves the deny is not firing on everything.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
H="$(cd "$(dirname "$0")" && pwd)/block-write-traps.sh"; fail=0
TMP=$(mktemp -d); on_exit_keep_status 'rm -rf "$TMP"'
run(){ printf '{"tool_input":{"file_path":%s,"content":%s}}' \
         "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "${2:-x}" '$v')" \
       | env -u HARNESS_MAIN_REPO HOME="$HOME" HARNESS_MAIN_REPO="${MAIN:-}" bash "$H"; }
deny(){ o=$(run "$1" "${3:-x}"); if printf '%s' "$o" | grep -q '"deny"'; then echo "ok   deny  $2"; else echo "FAIL deny  $2"; fail=1; fi; }
allow(){ o=$(run "$1" "${3:-x}"); if [ -z "$o" ]; then echo "ok   allow $2"; else echo "FAIL allow $2"; fail=1; fi; }

mkdir -p "$TMP/real"
# Traps 1 and 2 are gone (each builder has its own tree): a path in a temp dir that does
# not exist, and a source edit in the shared clone, are both ordinary writes now.
allow "/tmp/sh-99999-nope-abcdef/src/a.ts"          "a temp path whose directory does not exist"
MAIN="$TMP/clone"; mkdir -p "$MAIN/src" "$MAIN/.claude"
allow "$MAIN/src/a.ts"                              "a source edit in the shared clone"
MAIN=""

# 4. new tooling outside the kit
deny  "$HOME/.claude/commands/brand-new-$$.md"      "a new personal command"
deny  "$HOME/.claude/skills/brand-new-$$/SKILL.md"  "a new personal skill"
MAIN="$TMP/clone"; mkdir -p "$HOME/.claude/commands"
allow "$MAIN/.claude/skills/x/SKILL.md"             "a skill inside the configured repo"
MAIN=""

# 5. a new check script starts as a lint rule
mkdir -p "$TMP/repo/scripts/check-old"; : > "$TMP/repo/scripts/check-old/index.ts"
deny  "$TMP/repo/scripts/check-new-$$/index.ts"     "a new check script with no reason"
deny  "$TMP/repo/scripts/check-new-$$.sh"           "a new shell check with no reason"
deny  "$TMP/repo/scripts/check-new-$$/index.ts"     "an empty reason" "// needs-outside-data:"
allow "$TMP/repo/scripts/check-new-$$/index.ts"     "a new check that names its outside data" "// needs-outside-data: Railway variables"
allow "$TMP/repo/scripts/check-old/index.ts"        "an edit to an existing check"
allow "$TMP/repo/scripts/check-new-$$/index.test.ts" "a checker's test"
allow "$TMP/repo/scripts/build-thing.ts"            "a script that is not a check"

# 3. credential in memory
deny  "$TMP/real/memory/x.md" "a secret" "token: ghp_$(printf 'a%.0s' $(seq 32))"
# Long content is read whole: a pipe into grep -q under pipefail read an early secret as none.
long=$(i=0; while [ "$i" -lt 2000 ]; do echo "padding-padding-padding-padding-padding-$i"; i=$((i + 1)); done)
deny  "$TMP/real/memory/x.md" "a secret at the top of ~85 KB" "token: ghp_$(printf 'a%.0s' $(seq 32))
$long"
mkdir -p "$TMP/real/memory"
allow "$TMP/real/memory/x.md" "ordinary memory content" "Dom prefers short replies."

[ "$fail" -eq 0 ] && echo "block-write-traps: all cases pass"
suite_end "$fail"
