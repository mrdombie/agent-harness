#!/usr/bin/env bash
# pr-proof.test.sh — every pull request the driver opens carries its proof.
#
# WHY (after the Claude Code team's review system)
#   A reviewer, human or not, should not have to take the builder's word. The body
#   carries the commands the driver ran with what they printed, and two lines: how it
#   was tested and how to undo it. compose writes them from the run's records; check
#   refuses a body without them, so ship can refuse to open or rewrite such a PR.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
SUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-proof.sh"
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
export GIT_CONFIG_NOSYSTEM=1
SB=$(mktemp -d "${TMPDIR:-/tmp}/pr-proof-XXXXXX")
on_exit_keep_status 'rm -rf "$SB"'
FAILED=0
ok()      { printf 'OK       %s\n' "$1"; }
bad()     { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
want()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — wanted '$2', got '$3'"; fi; }
want_in() { if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 — no /$2/ in: $(printf '%s' "$3" | tr '\n' '|')"; fi; }
want_not_in() { if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 — found /$2/"; else ok "$1"; fi; }

# A run's records, as build and self-check leave them.
S="$SB/steps"; mkdir -p "$S"
jq -n '{title: "the widget counts", merged: false,
        proof: {command: "bash widget.test.sh", testFile: "widget.test.sh", line: "widget.test.sh: red (exit 1) at aaaaaaaa, then green at bbbbbbbb",
                red: {exit: 1, at: "aaaaaaaa", output: "checking\nWIDGET-RED\n```\nnot a fence"},
                green: {exit: 0, at: "bbbbbbbb", output: "WIDGET-GREEN"}}}' > "$S/build-task-1.proved"
jq -n '{title: "merged into task 1", merged: true, proof: null}' > "$S/build-task-2.proved"
printf '%s\n' '{"gate":"lint","command":"npm run lint","exit":0,"output":"lint: 0 problems"}' \
               '{"gate":"types","command":"npm run typecheck","exit":0,"output":"tsc: ok"}' > "$S/self-check.gates.jsonl"

# A repo whose branch adds a migration, for the undo line.
R="$SB/repo"; mkdir -p "$R"
git -C "$R" -c init.defaultBranch=main init -q
echo a > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm root
git -C "$R" checkout -qb work
echo b > "$R/a.txt"; git -C "$R" commit -qam change

echo "--- compose writes the proof from the run's records ---"
body=$(bash "$SUT" compose --steps "$S" --repo "$R" --base main 2>&1); rc=$?
want "it composes"                          "0" "$rc"
want_in "a Proof section"                   '^## Proof$' "$body"
want_in "the test's command"                '`bash widget.test.sh`' "$body"
want_in "its red output"                    'WIDGET-RED' "$body"
want_in "its red exit and where"            'exit 1.*aaaaaaaa|aaaaaaaa.*exit 1' "$body"
want_in "its green output"                  'WIDGET-GREEN' "$body"
want_in "each gate's command"               '`npm run lint`' "$body"
want_in "and what it printed"               'tsc: ok' "$body"
want_in "how it was tested"                 '^How it was tested: 1 test .*red without the change and green with it.*widget\.test\.sh.*2 gate' "$body"
want_in "how to undo it"                    '^How to undo it: revert .*squash commit' "$body"
want_not_in "no migration warning when none" 'migration' "$body"
want "a fence in the output is pushed past the closing indent" "1" "$(printf '%s\n' "$body" | grep -cE '^ {4,}```$' || true)"
want "so only the blocks' own fences open and close" "8" "$(printf '%s\n' "$body" | grep -cE '^ {0,3}```' || true)"

echo "--- what compose writes passes check ---"
rc=0; printf '%s\n' "$body" | bash "$SUT" check --body-file - >/dev/null 2>&1 || rc=$?
want "check passes it"                      "0" "$rc"

echo "--- a migration is named in the undo line ---"
mkdir -p "$R/prisma/migrations/20261102_x"; echo "ALTER TABLE t ADD c int;" > "$R/prisma/migrations/20261102_x/migration.sql"
git -C "$R" add -A; git -C "$R" commit -qm "migration"
body2=$(bash "$SUT" compose --steps "$S" --repo "$R" --base main --after-merge 2>&1)
want_in "the migration is named"            '^How to undo it: .*prisma/migrations/20261102_x/migration\.sql' "$body2"
want_in "and that a revert leaves it applied" 'reverses it' "$body2"
want_in "settings the PM made are named"    'After merge' "$body2"

echo "--- a screen change says where its shots are ---"
body3=$(bash "$SUT" compose --steps "$S" --tier screen 2>&1)
want_in "a Screens line"                    "^Screens: CI's shots" "$body3"
rc=0; printf '%s\n' "$body3" | bash "$SUT" check --tier screen --body-file - >/dev/null 2>&1 || rc=$?
want "check passes it as a screen"          "0" "$rc"
rc=0; printf '%s\n' "$body" | bash "$SUT" check --tier screen --body-file - >/dev/null 2>&1 || rc=$?
want "a screen body with no Screens line is refused" "1" "$rc"

echo "--- check refuses a body without each part ---"
chk() { local o r=0; o=$(printf '%s\n' "$1" | bash "$SUT" check --body-file - 2>&1) || r=$?; printf '%s\t%s' "$r" "$o"; }
out=$(chk "$(printf '%s\n' "$body" | grep -v '^How it was tested:')")
want "no tested line: refused"              "1" "${out%%	*}"
want_in "and it says which"                 'How it was tested' "$out"
out=$(chk "$(printf '%s\n' "$body" | grep -v '^How to undo it:')")
want "no undo line: refused"                "1" "${out%%	*}"
want_in "and it says which"                 'How to undo it' "$out"
out=$(chk "$(printf '%s\n' "$body" | sed 's/^## Proof$/## Notes/')")
want "no Proof section: refused"            "1" "${out%%	*}"
out=$(chk "$(printf '## Proof\nI ran the tests and they passed.\n\nHow it was tested: by hand\nHow to undo it: revert\n')")
want "a Proof that names no command run: refused" "1" "${out%%	*}"
want_in "and it says so"                    'no command' "$out"
out=$(chk "$(printf '## Proof\n- `npm test`: exit 0\n\nHow it was tested:\nHow to undo it: revert\n')")
want "an empty tested line: refused"        "1" "${out%%	*}"
out=$(chk "$(printf '## Proof\n- `npm test`: exit 0\n\n```\nHow it was tested: x\nHow to undo it: y\n```\n')")
want "the lines inside a code block do not count" "1" "${out%%	*}"
out=$(chk "$(printf '## Proof\n- `npm test`: exit 0\n\n**How it was tested:** npm test\n**How to undo it:** revert\n')")
want "bold labels are the same lines"       "0" "${out%%	*}"

echo "--- a run that kept nothing composes a body check refuses ---"
E="$SB/empty"; mkdir -p "$E"
body4=$(bash "$SUT" compose --steps "$E" 2>&1)
rc=0; printf '%s\n' "$body4" | bash "$SUT" check --body-file - >/dev/null 2>&1 || rc=$?
want "nothing kept is not a proof"          "1" "$rc"

echo "--- usage ---"
rc=0; bash "$SUT" nonsense >/dev/null 2>&1 || rc=$?
want "an unknown command is a usage error"  "2" "$rc"

suite_end "$FAILED"
