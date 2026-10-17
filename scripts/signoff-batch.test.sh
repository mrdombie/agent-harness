#!/usr/bin/env bash
# signoff-batch.test.sh — a held PR reaches the owner's batch only when it is green
# apart from the hold AND every reviewer's verdict is on its head: the owner signs
# last. A verdict below a later change, a SPIT-BACK, a missing reviewer, a head
# that moved and a read that failed each keep it out; an empty trailer commit and
# CI's evidence commit above a verdict do not.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
SB="$HERE/signoff-batch.sh"
jq '.review = {attest: {"ui-gate": {owed: "true"}, "design-critic": {owed: "true", trailer: "Design-Critic"}}}' \
  "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"

pr() { # <n> — held, green apart from the hold's own gate
  jq -n --argjson n "$1" '{number:$n, headRefName:("tkt-\($n)-x"), headRefOid:("h\($n)" + ("0" * 38)), isDraft:false,
    mergeStateStatus:"CLEAN", labels:[{name:"needs:human-approval"}],
    statusCheckRollup:[{name:"build", status:"COMPLETED", conclusion:"SUCCESS"},
      {name:"approval-gate", status:"COMPLETED", conclusion:"FAILURE"}]}'
}
prs() { local a=(); for n in "$@"; do a+=("$(pr "$n")"); done; printf '%s\n' "${a[@]}" | jq -s . > "$FIX/prs.json"; }
# commits <n> <body> <oid:files:message>… — oldest first; the last oid is the head.
commits() {
  local n="$1" body="$2" c nodes='[]' oid files msg; shift 2
  for c in "$@"; do
    oid=${c%%:*}; c=${c#*:}; files=${c%%:*}; msg=${c#*:}
    nodes=$(jq -c --arg o "$oid" --arg f "$files" --arg m "$msg" \
      '. + [{commit: {oid: $o, message: $m, changedFilesIfAvailable: (if $f == "?" then null else ($f | tonumber) end), parents: {totalCount: 1}}}]' <<<"$nodes")
  done
  jq -n --arg b "$body" --argjson n "$nodes" '{headRefOid: ($n | last | .commit.oid), body: $b, commits: {nodes: $n}}' > "$FIX/gh/pr-commits-$n.json"
}
H() { printf 'h%s%s' "$1" "$(printf '0%.0s' $(seq 38))"; }
UI=$'chore: ui-gate\n\nUI-Gate: SHIP (agent) fp1'
DC=$'chore: design-critic\n\nDesign-Critic: SHIP (agent) fp1'
both() { commits "$1" "" "c$1:3:feat: the page" "t$1:0:$UI" "$(H "$1"):0:$DC"; }
green() { bash "$SB" green < "$FIX/prs.json" 2>"$FIX/err"; }

echo "--- both verdicts on the head: counted ---"
prs 1; both 1
want "an empty trailer commit for each reviewer" "1	h100000" "$(green)"
commits 1 "<!-- ci-evidence-head:e1e1e1e -->" "c1:3:feat: the page" "t1:0:$UI" "e1e1e1e:4:chore(evidence): shots" "$(H 1):0:$DC"
want "CI's evidence commit, named in the body, is carried over" "1	h100000" "$(green)"
commits 1 "" "c1:3:feat: the page"$'\n\nUI-Gate: SHIP (agent) fp1\nDesign-Critic: SHIP (agent) fp1'
sed -i '' "s/\"c1\"/\"$(H 1)\"/" "$FIX/gh/pr-commits-1.json" 2>/dev/null || sed -i "s/\"c1\"/\"$(H 1)\"/" "$FIX/gh/pr-commits-1.json"
want "trailers on the head commit itself" "1	h100000" "$(green)"

echo "--- the owner signs last: not counted ---"
commits 1 "" "c1:3:feat: the page" "t1:0:$UI" "$(H 1):1:fix: after the review"
want "a change after the verdicts"             "" "$(green)"
want_in "and it says why"                       '#1 .*no design-critic or ui-gate verdict on its head' "$(cat "$FIX/err")"
commits 1 "" "c1:3:feat: the page" "$(H 1):0:$UI"
want "the design critic not yet recorded"       "" "$(green)"
want_in "named"                                 'no design-critic verdict' "$(cat "$FIX/err")"
commits 1 "" "c1:3:feat: the page" "t1:0:$UI" "$(H 1):0:"$'chore: design-critic\n\nDesign-Critic: SLOP (agent) fp1'
want "a verdict that is not SHIP"               "" "$(green)"
commits 1 "<!-- ci-evidence-head:f0f0f0f -->" "c1:3:feat: the page" "t1:0:$UI" "e1e1e1e:4:chore(evidence): shots" "$(H 1):0:$DC"
want "an evidence commit the body does not name is a change" "" "$(green)"
commits 1 "" "c1:3:feat: the page" "t1:0:$UI" "x1:?:chore: something" "$(H 1):0:$DC"
want "a commit GitHub could not count is a change" "" "$(green)"
commits 1 "" "c1:3:feat: the page" "t1:0:$UI" "zz:0:$DC"
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
commits 3 "" "c3:3:feat: x" "$(H 3):0:$UI"
want "the unreviewed one waits; five that are ready make a batch" \
  "signoff-batch:1@h100000,2@h200000,4@h400000,5@h500000,6@h600000	1 2 4 5 6" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
prs 1 2 3 4; : > "$GH_LOG"
want "fewer than a batch: nothing"              "" "$(bash "$SB" batches /dev/null < "$FIX/prs.json" 2>/dev/null)"
want "and the verdicts are not read for it"     "" "$(grep -c 'pullRequest(number' "$GH_LOG" | grep -v '^0$')"

echo "--- a project that attests no reviewer ---"
jq 'del(.review)' "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"
prs 9; : > "$GH_LOG"
want "green apart from the hold is enough"      "9	h900000" "$(green)"
want "and nothing is read"                      "" "$(cat "$GH_LOG")"

exit "$FAILED"
