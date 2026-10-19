#!/usr/bin/env bash
# needsme-watch.test.sh — the shell half of `/agent-harness:needsme --watch` and the
# batch rule under it: green apart from the hold, five to a batch, nothing asked
# twice across restarts, the watcher wakes only on something new, and the card
# shows the evidence for the PR it names.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
W="$HERE/needsme-watch.sh"
SB="$HERE/signoff-batch.sh"
C="$STATE/coordinator"
mkdir -p "$C"

# gh pr view <n> answers from $FIX/gh/pr-<n>.json; everything else goes to the fixture's gh.
cat > "$BIN/ghv" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "pr view" ]; then
  echo "\$*" >> "$FIX/gh.log"
  f="$FIX/gh/pr-\$3.json"; [ -f "\$f" ] || exit 1; cat "\$f"; exit 0
fi
exec "$BIN/gh" "\$@"
SH
cat > "$BIN/opener" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/opened.log"
SH
cat > "$BIN/curlok" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$BIN/ghv" "$BIN/opener" "$BIN/curlok"
export SWARM_GH="$BIN/ghv" NEEDSME_OPEN_CMD="$BIN/opener" NEEDSME_CURL="$BIN/curlok"

pr() { # <n> [conclusion] [mergeState] [label] — the hold's own gate is red while held
  jq -n --argjson n "$1" --arg c "${2:-SUCCESS}" --arg m "${3:-CLEAN}" --arg l "${4:-needs:human-approval}" \
    '{number:$n, headRefName:("tkt-\($n)-x"), headRefOid:("sha\($n)abcdef"), isDraft:false, mergeStateStatus:$m,
      labels:(if $l == "-" then [] else [{name:$l}] end),
      statusCheckRollup:[{name:"build", status:"COMPLETED", conclusion:$c},
        {name:"approval-gate", status:"COMPLETED", conclusion:"FAILURE"},
        {name:"approval-gate — waiting for sign-off", status:"COMPLETED", conclusion:"ACTION_REQUIRED"}]}'
}
prs() { local a=(); for n in "$@"; do a+=("$(pr "$n")"); done; printf '%s\n' "${a[@]}" | jq -s . > "$FIX/gh/prs-all.json"; }
fresh() { rm -rf "$C"; mkdir -p "$C"; printf '[]\n' > "$FIX/gh/prs-all.json"; : > "$FIX/opened.log"; }

echo "--- green apart from the hold ---"
fresh
jq -s . <(pr 1) <(pr 2 FAILURE) <(pr 3 SUCCESS DIRTY) <(pr 4 SUCCESS CLEAN -) > "$FIX/gh/prs-all.json"
want "the hold's own red gate does not count; a red build, a clash and no hold do" \
  "1	sha1abc" "$(bash "$SB" green < "$FIX/gh/prs-all.json")"
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"
jq '.gates = {requiredChecks: ["build", "lint"]}' "$FIX/cfg.bak" > "$FIX/cfg.req"; cp "$FIX/cfg.req" "$HARNESS_CFG_PATH"
want "with required checks named, one missing is not green" "" "$(bash "$SB" green < "$FIX/gh/prs-all.json")"
jq '.[0].statusCheckRollup += [{name:"lint", status:"COMPLETED", conclusion:"FAILURE"}, {name:"lint", status:"COMPLETED", conclusion:"SUCCESS"}]' \
  "$FIX/gh/prs-all.json" > "$FIX/p.json"
want "the newest run of a required check decides" "1	sha1abc" "$(bash "$SB" green < "$FIX/p.json")"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- batches of five, keyed on the set ---"
fresh; prs 9 3 5 1 7 2
: > "$C/done"
want "one full batch, lowest numbers first" \
  "signoff-batch:1@sha1abc,2@sha2abc,3@sha3abc,5@sha5abc,7@sha7abc	1 2 3 5 7" "$(bash "$SB" batches "$C/done" < "$FIX/gh/prs-all.json")"
printf 'pr:1:sha1abc\n' > "$C/done"
want "a PR already sent is not batched again" "9" "$(bash "$SB" batches "$C/done" < "$FIX/gh/prs-all.json" | cut -f2 | awk '{print $NF}')"
prs 1 2 3 4
want "four is not a batch"                 "" "$(bash "$SB" batches /dev/null < "$FIX/gh/prs-all.json")"

echo "--- pending: new needs-you lines and live batches, each asked once ---"
fresh; prs 1 2 3
printf -- '- [ ] 2026-10-15T10:00Z — Ship the export without CSV? <!-- key:decision:77:csv -->\n' > "$C/needs-you.md"
printf -- '- [x] 2026-10-15T09:00Z — old <!-- key:decision:1:old -->\n' >> "$C/needs-you.md"
printf -- '- [ ] 2026-10-14T09:00Z — a line from before keys\n' >> "$C/needs-you.md"
out=$(bash "$W" pending)
want "two unticked lines, no batch under five" "2" "$(grep -c . <<<"$out")"
want_in "the decision row"                 $'^decision:77:csv\tdecision\tShip the export' "$out"
want_in "a keyless line gets a key from its text" $'^line:[0-9]+\tline\ta line from before keys' "$out"
bash "$W" done decision:77:csv "$(grep '^line:' <<<"$out" | cut -f1)"
want "answered rows are not offered again" "" "$(bash "$W" pending)"
want "and their lines are ticked"          "0" "$(grep -c '^- \[ \]' "$C/needs-you.md")"
want "the asked file survives a restart"   "yes" "$( [ -s "$C/asked.keys" ] && echo yes)"
prs 1 2 3 4 5 6
out=$(bash "$W" pending)
want_in "five green held PRs make a batch row" $'^signoff-batch:1@sha1abc,2@sha2abc,3@sha3abc,4@sha4abc,5@sha5abc\tsignoff-batch\tSign off: PR #1, #2, #3, #4, #5$' "$out"
want "without the forge, no batch is read" "" "$(bash "$W" pending --no-forge)"
bash "$W" done pr:1:sha1abc pr:2:sha2abc
want "two answered leave four: no live batch" "" "$(bash "$W" pending)"
printf -- '- [ ] t — 5 screens <!-- key:signoff-batch:1@sha1abc,2@sha2abc,3@sha3abc,4@sha4abc,5@sha5abc -->\n' > "$C/needs-you.md"
want_in "a written batch drops its answered members" 'Sign off: PR #3, #4, #5$' "$(bash "$W" pending --no-forge)"
bash "$W" done "$(bash "$W" pending --no-forge | cut -f1)"
want "a done batch is never offered again" "" "$(bash "$W" pending)"
want "and its line is ticked"              "0" "$(grep -c '^- \[ \]' "$C/needs-you.md")"

echo "--- the tick's batch and the watcher's are one row, not two ---"
fresh; prs 1 2 3 4 5
printf -- '- [ ] t — 5 screens <!-- key:signoff-batch:1@sha1abc,2@sha2abc,3@sha3abc,4@sha4abc,5@sha5abc -->\n' > "$C/needs-you.md"
want "one row for the five"                "1" "$(bash "$W" pending | grep -c .)"

echo "--- wait: sleeps on nothing new, wakes on a new key ---"
fresh
NEEDSME_WATCH_MAX_LOOPS=2 bash "$W" wait --every 0 >/dev/null 2>&1
want "nothing new: it never wakes"         "4" "$?"
printf -- '- [ ] t — Pick a name <!-- key:decision:5:name -->\n' > "$C/needs-you.md"
out=$(NEEDSME_WATCH_MAX_LOOPS=2 bash "$W" wait --every 0); rc=$?
want "a new key wakes it"                  "0" "$rc"
want_in "and it prints the new row"        '^decision:5:name' "$out"
bash "$W" done decision:5:name
gh_before=$(grep -c 'OpenPullRequests' "$FIX/gh.log")
NEEDSME_WATCH_MAX_LOOPS=5 bash "$W" wait --every 0 --forge-every 3600 >/dev/null 2>&1
want "the forge is read once per forge interval, not every loop" "1" "$(( $(grep -c 'OpenPullRequests' "$FIX/gh.log") - gh_before ))"
prs 1 2 3 4 5
out=$(NEEDSME_WATCH_MAX_LOOPS=2 bash "$W" wait --every 0)
want_in "a fifth green held PR wakes it"   '^signoff-batch:1@' "$out"
mkdir -p "$C/watch.lock"; echo "$$" > "$C/watch.lock/pid"
LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | tr -s ' ' | sed 's/^ *//;s/ *$//' > "$C/watch.lock/started"
out=$(NEEDSME_WATCH_MAX_LOOPS=1 bash "$W" wait --every 0); rc=$?
want "a second watcher stands down"        "3" "$rc"
want_in "and names the first"              "pid $$" "$out"
rm -rf "$C/watch.lock"

echo "--- card and open: the evidence for the PR named ---"
fresh
jq -n '{number:12, title:"Calmer inbox", url:"https://github.com/acme/widgets/pull/12", headRefOid:"abcdef0123",
        labels:[{name:"needs:human-approval"}],
        body:"## Evidence\n<!-- preview:begin -->\nhttps://web-pr-12.up.example.app\n<!-- preview:end -->\nBefore: https://github.com/acme/widgets/blob/abcdef0/docs/evidence/12/before.png\nAfter: https://github.com/acme/widgets/blob/abcdef0/docs/evidence/12/after.png\nhttps://github.com/acme/widgets/blob/abcdef0/docs/evidence/12/after.png\nBranch-pinned: https://github.com/acme/widgets/blob/tkt-12/x.png"}' > "$FIX/gh/pr-12.json"
out=$(bash "$W" card 12)
want_in "the card says the hold is live"   $'^held\tyes$' "$out"
want "before, after and the live preview, once each, no branch-pinned link" "3" "$(grep -c '^evidence' <<<"$out")"
shot() { printf 'PNG-%s\n' "$2" > "$FIX/gh/api-$(printf 'repos/acme/widgets/contents/%s?ref=%s' "$2" "$1" | tr '/?&=' '____').json"; }
shot abcdef0 docs/evidence/12/before.png; shot abcdef0 docs/evidence/12/after.png
page() { sed -n 's#^opened 1 page for .*: file://##p' <<<"$1"; }
out=$(bash "$W" open 12); P=$(page "$out")
want "one PR, one tab"                     "1" "$(grep -c . "$FIX/opened.log")"
want_in "and it is the review page"        '^file:///.*/index\.html$' "$(cat "$FIX/opened.log")"
want_in "the preview is a link on the page, first" 'href="https://web-pr-12.up.example.app"' "$(sed -n '/pr-12/,$p' "$P" | head -3)"
want "before and after, fetched to the page" "2" "$(grep -c '<img ' "$P")"
want_in "before first"                     'before\.png' "$(grep -m1 '<figcaption>' "$P")"
NEEDSME_CURL=false bash "$W" open 12 > "$FIX/o.out"
want_not_in "a preview that does not answer is not on the page" 'web-pr-12' "$(cat "$(page "$(cat "$FIX/o.out")")")"
jq '.labels = []' "$FIX/gh/pr-12.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/pr-12.json"
want_in "a cleared hold shows on the card" $'^held\tno$' "$(bash "$W" card 12)"
bash "$W" card 99 >/dev/null 2>&1
want "an unreadable PR is an error, not an empty card" "1" "$?"

echo "--- a part of a screen: card N of M, the region first, the picture at its anchor ---"
fresh
jq -n '{number:30, title:"Team bars", url:"https://github.com/acme/widgets/pull/30", headRefOid:"abcdef0123",
        labels:[{name:"needs:human-approval"}],
        body:"## Part of a screen\n<!-- part:begin -->\nScreen: Home\nPart: 3 of 8\nRegion: Team card\nAnchor: team\nPicture: https://claude.ai/artifact/home-v3\nSiblings: #101 #102\nRegion shot: https://github.com/acme/widgets/blob/abcdef0/docs/evidence/30/home-team.png\n<!-- part:end -->\n\n## Evidence\n<!-- preview:begin -->\nhttps://web-pr-30.up.example.app/home\n<!-- preview:end -->\nFull page: https://github.com/acme/widgets/blob/abcdef0/docs/evidence/30/home.png"}' > "$FIX/gh/pr-30.json"
printf '{"state":"CLOSED","title":"Pipeline card"}\n' > "$FIX/gh/issue-101.json"
printf '{"state":"OPEN","title":"Diary card"}\n'     > "$FIX/gh/issue-102.json"
out=$(bash "$W" card 30)
want_in "the card says which card of how many, and that the rest is old" \
  $'^banner\tcard 3 of 8 of the new Home; the rest of the page is the old version. Compare only the Team card$' "$out"
want_in "a shipped sibling is live"        $'^sibling\t#101\tlive\tPipeline card$' "$out"
want_in "an open sibling is pending"       $'^sibling\t#102\tpending\tDiary card$' "$out"
want_in "the approved picture opens at the region" $'^picture\thttps://claude.ai/artifact/home-v3#team$' "$out"
want_in "the region's own shot comes first" 'home-team\.png$' "$(grep '^evidence' <<<"$out" | head -1)"
want_in "the full page comes last"         'home\.png$' "$(grep '^evidence' <<<"$out" | tail -1)"
want "the region shot is not listed twice" "1" "$(grep -c 'home-team' <<<"$out")"
shot abcdef0 docs/evidence/30/home-team.png; shot abcdef0 docs/evidence/30/home.png
P=$(page "$(bash "$W" open 30)")
want_in "open: the region shot first"      'home-team\.png' "$(grep -m1 '<figcaption>' "$P")"
want_in "and the full page last"           'home\.png<' "$(grep '<figcaption>' "$P" | tail -1)"
want_in "the preview at the region is on the page" 'href="https://web-pr-30.up.example.app/home#team"' "$(cat "$P")"
want_in "and the picture at the region"    'href="https://claude.ai/artifact/home-v3#team"' "$(cat "$P")"
out=$(bash "$W" card 12)
want_in "a whole-screen PR still has its card" $'^pr\t12$' "$out"
want "and carries no banner"               "0" "$(grep -c '^banner' <<<"$out")"

echo "--- a batch: one page, one tab, numbered; every shot the body pins at its newest pinned commit ---"
# Each evidence link of every commit opened as its own tab: 24, 35, 108 and 60 tabs
# for one PR each on 2026-10-17, older commits' shots among them.
fresh
mkpr() { # <n> <head> <commits csv> <body>
  jq -n --argjson n "$1" --arg h "$2" --arg c "$3" --arg b "$4" \
    '{number:$n, title:"PR \($n)", url:"https://github.com/acme/widgets/pull/\($n)", headRefOid:$h, labels:[], body:$b,
      commits:[$c | split(",")[] | {oid:.}]}' > "$FIX/gh/pr-$1.json"
}
L() { printf 'https://github.com/acme/widgets/blob/%s/%s' "$1" "$2"; }
# 12: an older commit's shots are linked too; only the newest pinned commit's show.
mkpr 12 abcdef0123 "1111111aaa,abcdef0123" "Old: $(L 1111111 docs/evidence/12/old.png)
Before: $(L abcdef0 docs/evidence/12/before.png)
After: $(L abcdef0 docs/evidence/12/after.png)"
shot 1111111 docs/evidence/12/old.png
# 50: evidence, then an empty review-stamp commit on top as the head.
mkpr 50 fff5000000 "aaa5000000,fff5000000" "$(L aaa5000 docs/evidence/50/inbox.png)
$(L aaa5000 docs/evidence/50/inbox-dark.png)"
shot aaa5000 docs/evidence/50/inbox.png; shot aaa5000 docs/evidence/50/inbox-dark.png
# 60 and 61: the head is a merge from the trunk, which carries another ticket's evidence.
mkpr 60 m600000000 "c600000000,m600000000" "$(L c600000 docs/evidence/60/feed.png)"
shot c600000 docs/evidence/60/feed.png
mkpr 61 m610000000 "c610000000,m610000000" "No pictures yet."
for h in m600000000 m610000000; do
  jq -n '{files: [range(5) | {filename: "docs/evidence/12736/other-\(.).png", status: "added"}]}' > "$FIX/gh/api-repos_acme_widgets_commits_$h.json"
  for k in 0 1 2 3 4; do shot "$h" "docs/evidence/12736/other-$k.png"; done
done
# 70: 49 shots across viewports and themes, none dropped.
body=""; for k in $(seq 1 49); do
  case $((k % 4)) in 0) v=phone-dark ;; 1) v=laptop-light ;; 2) v=phone ;; 3) v=laptop-dark ;; esac
  body="$body$(L e700000 "docs/evidence/70/s$k-$v.png")"$'\n'; shot e700000 "docs/evidence/70/s$k-$v.png"
done
mkpr 70 e700000000 "e700000000" "$body"
# 80: linked, but GitHub will not hand them over.
mkpr 80 d800000000 "d800000000" "$(L d800000 docs/evidence/80/a.png)
$(L d800000 docs/evidence/80/b.png)"
# 41: nothing linked at all.
mkpr 41 beef410000 "beef410000" "Quiet footer, no links."
: > "$FIX/opened.log"; : > "$GH_LOG"
out=$(bash "$W" open 12 50 60 61 70 80 41); P=$(page "$out")
row() { grep -E "^[0-9]+	$1	" <<<"$out" | cut -f1,3,4 | tr '\t' ' '; }
sec() { sed -n "/id=\"pr-$1\"/,/<\/section>/p" "$P"; }
want "seven PRs, one tab"                  "1" "$(grep -c . "$FIX/opened.log")"
want "numbered in the order asked"         "1 2 3 4 5 6 7" "$(grep -o '<span class="n">[0-9]*' "$P" | sed 's/.*>//' | tr '\n' ' ' | sed 's/ $//')"
want_not_in "an older pinned commit's shot is not on the page" 'old\.png' "$(sec 12)"
want "the newest pinned commit's shots are" "1 2 0" "$(row 12)"
want "an empty commit on top hides nothing" "2 2 0" "$(row 50)"
want_not_in "and it is not sent back"      'Send it back' "$(sec 50)"
want "a merge head shows only what the body links" "3 1 0" "$(row 60)"
want_not_in "never the trunk's evidence on the page" '12736' "$(cat "$P")"
want_not_in "nor asked for"                '12736|commits/m6' "$(cat "$GH_LOG")"
want "a merge head with no links shows none" "4 0 0" "$(row 61)"
want "every one of 49 shots is shown"      "5 49 0" "$(row 70)"
want "grouped by viewport and theme"       "laptop · dark|laptop · light|phone · dark|phone · light" "$(sec 70 | sed -n 's#.*<h3>\(.*\)</h3>.*#\1#p' | tr '\n' '|' | sed 's/|$//')"
want "a fetch that fails is counted, not lost" "6 0 2" "$(row 80)"
want_in "and said so"                      "Couldn't load 2 shot" "$(sec 80)"
want_not_in "never as no screenshots"      'No screenshots|Send it back' "$(sec 80)"
want "nothing linked: none shown"          "7 0 0" "$(row 41)"
opts() { grep -E "^[0-9]+	$1	" <<<"$out" | cut -f5; }
want "shots shown: approve or change"      "Approve,Change" "$(opts 12)"
want "none linked: send back or skip, never approve" "Send back for shots,Skip" "$(opts 41)"
want "none loaded: skip only"              "Skip" "$(opts 80)"
want_in "and flagged for sending back"     'No screenshots linked' "$(sec 41)"

mkpr 51 fff5100000 "aaa5100000,fff5100000" "$(L aaa5100 docs/evidence/51/a.png)
$(L aaa5100 docs/evidence/51/b.png)"
shot aaa5100 docs/evidence/51/a.png
out=$(bash "$W" open 51)
want "part loaded: change or skip, never approve" "1 1 1 Change,Skip" "$(grep -E "^1	51	" <<<"$out" | cut -f1,3,4,5 | tr '\t' ' ')"

echo "--- under the backoff, a PR that cannot be read is never sent back ---"
printf '%s\t0\t%s\n' $(( $(date +%s) + 600 )) "$(date +%s)" > "$STATE/swarm/gh-backoff"
out=$(bash "$W" open 50); P=$(page "$out")
want "it is a row with nothing loaded"     "1 0 -" "$(grep -E "^1	50	" <<<"$out" | cut -f1,3,4 | tr '\t' ' ')"
want "and only skip is offered"            "Skip" "$(grep -E "^1	50	" <<<"$out" | cut -f5)"
want_not_in "and not a missing shot"       'No screenshots|Send it back' "$(cat "$P")"
rm -f "$STATE/swarm/gh-backoff"

echo "--- paths: a link already encoded is not encoded twice; the page URL is encoded; old pages go ---"
mkpr 90 a900000000 "a900000000" "$(L a900000 'docs/evidence/90/home%20page.png')"
printf 'PNG\n' > "$FIX/gh/api-$(printf 'repos/acme/widgets/contents/docs/evidence/90/home%%20page.png?ref=a900000' | tr '/?&=' '____').json"
: > "$GH_LOG"; mkdir -p "$FIX/re view/old-one" "$FIX/re view/new-one"; touch -t 202601010000 "$FIX/re view/old-one"
out=$(NEEDSME_PAGE_DIR="$FIX/re view" bash "$W" open 90)
want_in "fetched as %20, once"             'contents/docs/evidence/90/home%20page\.png' "$(cat "$GH_LOG")"
want "and shown"                           "1 1 0" "$(grep -E "^1	90	" <<<"$out" | cut -f1,3,4 | tr '\t' ' ')"
want_in "the page URL is encoded"          '^file:///.*/re%20view/.*/index\.html$' "$(tail -1 "$FIX/opened.log")"
want "a page over 7 days old is pruned"    "no" "$([ -d "$FIX/re view/old-one" ] && echo yes || echo no)"
want "a recent one is kept"                "yes" "$([ -d "$FIX/re view/new-one" ] && echo yes || echo no)"

exit $FAILED
