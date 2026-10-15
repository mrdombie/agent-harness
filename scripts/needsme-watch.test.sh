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
gh_before=$(grep -c 'pr list' "$FIX/gh.log")
NEEDSME_WATCH_MAX_LOOPS=5 bash "$W" wait --every 0 --forge-every 3600 >/dev/null 2>&1
want "the forge is read once per forge interval, not every loop" "1" "$(( $(grep -c 'pr list' "$FIX/gh.log") - gh_before ))"
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
bash "$W" open 12 >/dev/null
want_in "the preview opens first"          '^https://web-pr-12' "$(head -1 "$FIX/opened.log")"
want_in "then before and after"            'before\.png' "$(sed -n 2p "$FIX/opened.log")"
: > "$FIX/opened.log"
NEEDSME_CURL=false bash "$W" open 12 >/dev/null
want "a preview that does not answer is not opened" "2" "$(grep -c . "$FIX/opened.log")"
jq '.labels = []' "$FIX/gh/pr-12.json" > "$FIX/p.json" && mv "$FIX/p.json" "$FIX/gh/pr-12.json"
want_in "a cleared hold shows on the card" $'^held\tno$' "$(bash "$W" card 12)"
bash "$W" card 99 >/dev/null 2>&1
want "an unreadable PR is an error, not an empty card" "1" "$?"

exit $FAILED
