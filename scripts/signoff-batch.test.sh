#!/usr/bin/env bash
# signoff-batch.test.sh — a held PR reaches the owner's batch only when it is green
# apart from the hold AND every reviewer's recorded verdict is on its head: the
# owner signs last. A verdict below a later change, a SPIT-BACK, a trailer the
# recorder did not write, a missing reviewer, a head that moved and a read that
# failed each keep it out; empty commits, every CI evidence commit and a merge that
# only brings the trunk in do not. The last section runs the rule on the commit
# shapes of 25 real PRs.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX"'
SB="$HERE/signoff-batch.sh"
jq '.review = {attest: {"ui-gate": {owed: "true"}, "design-critic": {owed: "true", trailer: "Design-Critic"}}}' \
  "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
# A merge is a trunk-only merge unless its oid is listed in $FIX/dirty.
cat > "$FIX/kept.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/kept.log"
[ "$1" = check ] || exit 2
grep -qxF "$3" "$FIX/dirty" 2>/dev/null && exit 1; exit 0
SH
chmod +x "$FIX/kept.sh"; : > "$FIX/dirty"
export SIGNOFF_APPROVAL_KEPT="$FIX/kept.sh"

pr() { # <n> [head] — held, green apart from the hold's own gate
  jq -n --argjson n "$1" --arg h "${2:-}" '{number:$n, headRefName:("tkt-\($n)-x"),
    headRefOid:(if $h == "" then ("h\($n)" + ("0" * 38)) else $h end), isDraft:false,
    mergeStateStatus:"CLEAN", labels:[{name:"needs:human-approval"}],
    statusCheckRollup:[{name:"build", status:"COMPLETED", conclusion:"SUCCESS"},
      {name:"approval-gate", status:"COMPLETED", conclusion:"FAILURE"}]}'
}
prs() { local a=(); for n in "$@"; do a+=("$(pr "$n")"); done; printf '%s\n' "${a[@]}" | jq -s . > "$FIX/prs.json"; }
# commits <n> <oid:files:parents:message>… — oldest first; the last oid is the head.
commits() {
  local n="$1" c nodes='[]' oid files par msg prev="base"; shift
  for c in "$@"; do
    oid=${c%%:*}; c=${c#*:}; files=${c%%:*}; c=${c#*:}; par=${c%%:*}; msg=${c#*:}
    nodes=$(jq -c --arg o "$oid" --arg f "$files" --argjson p "$par" --arg m "$msg" --arg prev "$prev" \
      '. + [{commit: {oid: $o, message: $m, changedFilesIfAvailable: (if $f == "?" then null else ($f | tonumber) end),
             parents: {totalCount: $p, nodes: ([{oid: $prev}] + (if $p > 1 then [{oid: "trunk"}] else [] end))}}}]' <<<"$nodes")
    prev=$oid
  done
  jq -n --argjson n "$nodes" '{headRefOid: ($n | last | .commit.oid), commits: {nodes: $n}}' > "$FIX/gh/pr-commits-$n.json"
}
H() { printf 'h%s%s' "$1" "$(printf '0%.0s' $(seq 38))"; }
UI=$'chore: ui-gate\n\nUI-Gate: SHIP (agent) c4c9c643184f'
DC=$'chore: design-critic\n\nDesign-Critic: SHIP (agent) c4c9c643184f'
EV='chore(evidence): screenshots captured by ci'
both() { commits "$1" "c$1:3:1:feat: the page" "t$1:0:1:$UI" "$(H "$1"):0:1:$DC"; }
green() { bash "$SB" green < "$FIX/prs.json" 2>"$FIX/err"; }

echo "--- both verdicts on the head: counted ---"
prs 1; both 1
want "an empty recorded-verdict commit for each reviewer" "1	h100000" "$(green)"
commits 1 "c1:3:1:feat: the page" "e1:4:1:$EV" "t1:0:1:$UI" "e2:4:1:$EV" "$(H 1):0:1:$DC"
want "every CI evidence commit is carried over, not only the newest" "1	h100000" "$(green)"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "d1:0:1:$DC" "m1:40:2:Merge develop" "$(H 1):2:1:$EV"
want "a merge that only brings the trunk in is carried over" "1	h100000" "$(green)"
want_in "judged by approval-kept from its first parent" '^check d1 m1$' "$(cat "$FIX/kept.log")"

echo "--- the owner signs last: not counted ---"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "$(H 1):1:1:fix: after the review"
want "a change after the verdicts"             "" "$(green)"
want_in "and it says why"                       '#1 .*no design-critic or ui-gate verdict on its head' "$(cat "$FIX/err")"
printf 'm1\n' > "$FIX/dirty"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "d1:0:1:$DC" "m1:40:2:Merge develop" "$(H 1):2:1:$EV"
want "a merge whose resolution changed the PR's own screens" "" "$(green)"
: > "$FIX/dirty"
commits 1 "c1:3:1:feat: the page" "$(H 1):0:1:$UI"
want "the design critic not yet recorded"       "" "$(green)"
want_in "named"                                 'no design-critic verdict' "$(cat "$FIX/err")"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "$(H 1):0:1:"$'chore: design-critic\n\nDesign-Critic: SLOP (agent) c4c9c643184f'
want "a verdict that is not SHIP"               "" "$(green)"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "$(H 1):0:1:"$'chore: design-critic\n\nDesign-Critic: SHIP'
want "a trailer the recorder did not write"     "" "$(green)"
commits 1 "c1:3:1:feat: the page"$'\n\nUI-Gate: SHIP (agent) c4c9c643184f' "$(H 1):0:1:$DC"
want "a verdict on a commit that changes code"  "" "$(green)"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "x1:?:1:chore: something" "$(H 1):0:1:$DC"
want "a commit GitHub could not count is a change" "" "$(green)"
commits 1 "c1:3:1:feat: the page" "t1:0:1:$UI" "zz:0:1:$DC"
want "a head that moved since the list"          "" "$(green)"
want_in "named"                                 'head moved' "$(cat "$FIX/err")"
rm -f "$FIX/gh/pr-commits-1.json"
want "a PR whose commits could not be read"     "" "$(green)"
both 1; touch "$FIX/gh/ratelimit"
want "a read that failed counts none"           "" "$(green)"
want_in "and says so"                           'could not be read' "$(cat "$FIX/err")"
rm -f "$FIX/gh/ratelimit" "$STATE/swarm/gh-backoff"

echo "--- batches ---"
prs 1 2 3 4 5 6; for n in 1 2 3 4 5 6; do both "$n"; done
commits 3 "c3:3:1:feat: x" "$(H 3):0:1:$UI"
: > "$GH_LOG"
want "the unreviewed one waits; five that are ready make a batch" \
  "signoff-batch:1@h100000,2@h200000,4@h400000,5@h500000,6@h600000	1 2 4 5 6" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
want "six PRs are read five to a request"       "2" "$(grep -c 'pullRequest(number' "$GH_LOG")"
prs 1 2 3 4 5 6 7 8 9 10 11; for n in 1 2 3 4 5 6 7 8 9 10 11; do both "$n"; done
touch "$FIX/gh/graphql-fail-11"
want "a failed chunk leaves out only its own PRs" \
  "signoff-batch:1@h100000,2@h200000,3@h300000,4@h400000,5@h500000	1 2 3 4 5
signoff-batch:6@h600000,7@h700000,8@h800000,9@h900000,10@h100000	6 7 8 9 10" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>"$FIX/err")"
want_in "and names them"                         '#11 .*could not be read' "$(cat "$FIX/err")"
rm -f "$FIX/gh/graphql-fail-11"
prs 1 2 3 4; : > "$GH_LOG"
want "fewer than a batch: nothing"              "" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
want "and the verdicts are not read for it"     "0" "$(grep -c 'pullRequest(number' "$GH_LOG")"

echo "--- batches by priority: P0 first, polish last ---"
# pri_pr <n> <label…> — a held green PR wearing those labels
pri_pr() { local n="$1"; shift; pr "$n" | jq --args '.labels += ($ARGS.positional | map({name:.}))' "$@"; }
both_all() { for n in "$@"; do both "$n"; done; }
{ pri_pr 1 P3; pri_pr 2 polish-list; pri_pr 3 P0; pri_pr 4; pri_pr 5 P1; pri_pr 6 P2; pri_pr 7 P3; } | jq -s . > "$FIX/prs.json"
both_all 1 2 3 4 5 6 7
fix_issue 4 OPEN "P0,type:bug"
want "P0 before P3: the PR's own label, else its ticket's; a polish list is P3; P3 and no priority wait" \
  "signoff-batch:3@h300000,4@h400000,5@h500000,6@h600000,1@h100000	3 4 5 6 1" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
rm -f "$FIX/gh/issue-4.json"
want "a ticket that cannot be read sorts last, not first" \
  "signoff-batch:3@h300000,5@h500000,6@h600000,1@h100000,2@h200000	3 5 6 1 2" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
want "green still lists by number"         "1 2 3 4 5 6 7" "$(bash "$SB" green < "$FIX/prs.json" 2>/dev/null | cut -f1 | tr '\n' ' ' | sed 's/ $//')"

echo "--- 25 real PRs' commit shapes ---"
# Their last twelve commits, messages reduced to subject class and trailers. A
# merge whose message recorded conflicts stands in for one approval-kept voids.
REAL="$HERE/fixtures/signoff-batch/commits.ndjson"
jq -r '.commits[] | select(.conflicts) | .oid' "$REAL" > "$FIX/dirty"
a=()
while IFS= read -r line; do
  n=$(jq -r .n <<<"$line"); a+=("$(pr "$n" "$(jq -r .head <<<"$line")")")
  jq '{headRefOid: .head, commits: {nodes: [.commits as $c | range($c | length) as $i | $c[$i]
        | {commit: {oid, message, changedFilesIfAvailable: .files,
                    parents: {totalCount: .parents, nodes: ([{oid: (if $i > 0 then $c[$i - 1].oid else "base" end)}] + (if .parents > 1 then [{oid: "trunk"}] else [] end))}}}]}}' \
    <<<"$line" > "$FIX/gh/pr-commits-$n.json"
done < "$REAL"
printf '%s\n' "${a[@]}" | jq -s . > "$FIX/prs.json"
got=$(green | cut -f1 | sort -n | tr '\n' ' ')
want "the reviewed ones are counted: evidence commits, trunk merges and conflict merges below the verdicts" \
  "12706 12915 12965 13074 13080 13165 13207 13212 13215 13216 13219 13221 13238 " "$got"
want_in "and the unreviewed ones say why" '#13217 .*no design-critic or ui-gate verdict' "$(cat "$FIX/err")"
# Below its trunk merge, 12914's tip is a 17-file commit carrying old trailers in its
# message: a recorder writes an empty commit, so those are no verdict on this code.
want_in "trailers riding a commit that changes code are not verdicts" '#12914 ' "$(cat "$FIX/err")"

echo "--- a reviewer that judges pictures: the independent critic's status, not a trailer ---"
# needsRenders: nothing writes its trailer (the build cannot record a design verdict);
# critic-judge.sh posts the "Design critic" status, its description led by its prefix.
jq '.review.attest["design-critic"].needsRenders = true' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
jpr() { # <n> <state|-> [description] — held green PR with that Design critic status
  pr "$1" | jq --arg s "$2" --arg d "${3:-}" 'if $s == "-" then . else
    .statusCheckRollup += [{context:"Design critic", state:$s, description:$d}] end' | jq -s . > "$FIX/prs.json"
}
JS='Independent critic: SHIP on shots 1a2b3c4d5e6f (4) at c4c9c6431'
commits 1 "c1:3:1:feat: the page" "$(H 1):0:1:$UI"
jpr 1 SUCCESS "$JS"
want "no Design-Critic trailer, the judge passed it: counted" "1	h100000" "$(green)"
jpr 1 FAILURE 'Independent critic: SLOP on shots 1a2b3c4d5e6f (4) at c4c9c6431 — 2 blocking'
want "the judge failed it"                        "" "$(green)"
jpr 1 PENDING 'Independent critic: waiting for CI to photograph again'
want "the judge has not finished"                 "" "$(green)"
jpr 1 SUCCESS 'Design-Critic: SHIP (agent) c4c9c643184f'
want "a success the judge did not post"           "" "$(green)"
want_in "named"                                   '#1 .*not posted by the independent critic' "$(cat "$FIX/err")"
jpr 1 -
want "no judge status at all"                     "" "$(green)"
want_in "named"                                   '#1 .*no Design critic status' "$(cat "$FIX/err")"
both 1
want "a Design-Critic trailer stands in for nothing" "" "$(green)"
commits 1 "c1:3:1:feat: the page" "$(H 1):1:1:fix: after the review"; jpr 1 SUCCESS "$JS"
want "the other reviewers' trailers are still owed" "" "$(green)"
want_in "named"                                   '#1 .*no ui-gate verdict on its head' "$(cat "$FIX/err")"
want_not_in "and the picture reviewer's trailer is not asked for" 'design-critic' "$(cat "$FIX/err")"

echo "--- a project that attests no reviewer ---"
jq 'del(.review)' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
prs 9; : > "$GH_LOG"
want "green apart from the hold is enough"      "9	h900000" "$(green)"
want "and nothing is read"                      "" "$(cat "$GH_LOG")"

suite_end "$FAILED"
