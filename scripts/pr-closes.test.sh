#!/usr/bin/env bash
# pr-closes.test.sh — a ticket's pull request names its ticket in its body, always.
# #5654's repair parked "no open pull request to repair" beside its own PR: the body
# said "Closes ticket 5654", which GitHub links to nothing, and the branch had no prefix.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
. "$HERE/pr-closes.sh"

names() { if printf '%s' "$2" | pr_closes_names "$1"; then echo yes; else echo no; fi; }

echo "--- what counts as naming the ticket ---"
want "Closes #n"                       yes "$(names 5654 $'Body.\n\nCloses #5654')"
want "fixes #n, any case"              yes "$(names 5654 'This fixes #5654.')"
want "Resolved: #n"                    yes "$(names 5654 'Resolved: #5654')"
want "Refs #n (a polish list)"         yes "$(names 5654 'Refs #5654')"
want "Part of #n (an epic slice)"      yes "$(names 5654 'Part of #5654')"
want "'Closes ticket n' is not"        no  "$(names 5654 'Closes ticket 5654.')"
want "a longer number is not"          no  "$(names 5654 'Closes #56540')"
want "another ticket is not"           no  "$(names 5654 'Closes #565')"
want "a bare mention is not"           no  "$(names 5654 'see #5654')"
want "an empty body is not"            no  "$(names 5654 '')"

echo "--- the line is added once, and only when missing ---"
out=$(printf 'A body a person wrote.\n\n## Lesson\n- kept\n' | pr_closes_ensure 5654 Closes)
want_in "it is added"                  '^Closes #5654$' "$out"
want_in "below the body, which is kept" '## Lesson' "$(printf '%s\n' "$out" | head -3)"
want "it ends the body"                "Closes #5654" "$(printf '%s\n' "$out" | tail -1)"
want "a body that has it is unchanged" $'Closes #5654\n\nx' "$(printf 'Closes #5654\n\nx' | pr_closes_ensure 5654 Closes)"
want "a second pass adds nothing"      "$out" "$(printf '%s\n' "$out" | pr_closes_ensure 5654 Closes)"
want "a polish list gets Refs"         "Refs #77" "$(printf 'x\n' | pr_closes_ensure 77 Refs | tail -1)"
want "an empty body becomes the line"  "Closes #9" "$(printf '' | pr_closes_ensure 9 Closes)"

echo "--- the CLI writes it to the PR, and only when missing ---"
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")    cat "$FIX/body.txt" ;;
  "issue view") printf '%s\n' ${FIX_LABELS:-status:in-review} ;;
  "pr edit")    exit 0 ;;
esac
SH
chmod +x "$BIN/gh"
printf 'Built it.\n' > "$FIX/body.txt"; : > "$GH_LOG"
out=$(bash "$HERE/pr-closes.sh" ensure 13611 5654); rc=$?
want "it succeeds"                     0 "$rc"
want_in "and says so"                  'now says Closes #5654' "$out"
want_in "the body is written with it, ending in the line" 'pr edit 13611 .*--body Built it\.  Closes #5654' "$(tr '\n' ' ' < "$GH_LOG")"
printf 'Built it.\n\nCloses #5654\n' > "$FIX/body.txt"; : > "$GH_LOG"
out=$(bash "$HERE/pr-closes.sh" ensure 13611 5654)
want_not_in "a body that has it is not edited" '^pr edit' "$(cat "$GH_LOG")"
printf 'Fixed two.\n' > "$FIX/body.txt"; : > "$GH_LOG"
out=$(FIX_LABELS="polish-list status:in-review" bash "$HERE/pr-closes.sh" ensure 50 900)
want_in "a polish list is named with Refs" 'pr edit 50 .*Refs #900' "$(tr '\n' ' ' < "$GH_LOG")"
want_not_in "never Closes"             'Closes #900' "$(tr '\n' ' ' < "$GH_LOG")"

echo "--- every PR body the kit writes names its ticket ---"
# The sibling: the park's draft and /claim's park wrote a body naming no ticket, and
# /finish's template wrote "Closes ticket \$TICKET", which GitHub links to nothing.
want "/finish never writes 'Closes ticket'" "" "$(grep -rnE '^[[:space:]]*Closes ticket' "$HERE/../skills" 2>/dev/null)"
want_in "the park's draft names it"    'Closes\) #\$t' "$(grep -A5 'pr create' "$HERE/../driver/steps/park.sh")"
want_in "/claim's park names it"       'Closes #\$TICKET_KEY' "$(grep -A3 'gh pr create --draft' "$HERE/../skills/claim/SKILL.md")"
want_in "/finish ensures it after create" 'pr-closes.sh" ensure "\$PR_NUMBER" "\$TICKET_KEY"' "$(cat "$HERE/../skills/finish/SKILL.md")"

exit $FAILED
