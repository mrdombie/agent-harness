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

# 6. a glob over a state directory as arguments (2026-11-11: `ls -t <glob>` never ran at 13,616 logs)
deny  "$TMP/repo/scripts/a.sh"      "ls over the logs folder"            'ls $STATE_DIR/logs/*.log'
deny  "$TMP/repo/swarm/a.sh"        "the listing that went blind"        'newest=$(ls -t "$SWARM_LOGS"/claim-*.log 2>/dev/null | head -1)'
deny  "$TMP/repo/driver/build-ticket" "cat over the run records"         'n=$(cat "$RUNS_DIR"/*.json | wc -l)'
allow "$TMP/repo/scripts/a.sh"      "a for loop over the same glob"      'for f in "$STATE_DIR"/logs/*.log; do :; done'
allow "$TMP/repo/scripts/a.sh"      "the kit's listing"                  'newest=$(swarm_newest_logs 1 "$SWARM_LOGS"/claim-*.log)'
allow "$TMP/repo/scripts/a.sh"      "a list marked bounded"              'ls "$RUNS_DIR"/claim-"$t"-*.json   # argv-bounded: one ticket'
allow "$TMP/repo/scripts/a.test.sh" "a test listing its own fixture"     'ls $STATE_DIR/logs/*.log'
allow "$TMP/repo/src/a.ts"          "a file that is no shell script"     'ls $STATE_DIR/logs/*.log'
# An Edit carries new_string, not content.
o=$(printf '{"tool_input":{"file_path":"%s","old_string":"x","new_string":"cat \\"$RUNS_DIR\\"/*.json"}}' "$TMP/repo/scripts/a.sh" | bash "$H")
if printf '%s' "$o" | grep -q '"deny"'; then echo "ok   deny  an Edit that adds the glob"; else echo "FAIL deny  an Edit that adds the glob"; fail=1; fi
# Planted: the trap's refusal deleted, and the same write goes through.
mkdir -p "$TMP/kit/hooks" "$TMP/kit/scripts"; cp "$(dirname "$H")/../scripts/check-argv-json.sh" "$TMP/kit/scripts/"
grep -v '\[ -z "\$_hits" \] || deny ' "$H" > "$TMP/kit/hooks/block-write-traps.sh"
if [ "$(grep -c '_hits" \] || deny ' "$H")" = 1 ] && [ "$(grep -c '_hits" \] || deny ' "$TMP/kit/hooks/block-write-traps.sh")" = 0 ]; then
  REAL="$H"; H="$TMP/kit/hooks/block-write-traps.sh"
  o=$(run "$TMP/repo/scripts/a.sh" 'ls $STATE_DIR/logs/*.log'); H="$REAL"
  if [ -z "$o" ]; then echo "ok   planted: the refusal deleted, the glob is written"; else echo "FAIL planted: still refused with the refusal deleted"; fail=1; fi
else echo "FAIL the plant did not land"; fail=1; fi

[ "$fail" -eq 0 ] && echo "block-write-traps: all cases pass"
suite_end "$fail"
