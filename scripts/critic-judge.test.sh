#!/usr/bin/env bash
# critic-judge.test.sh — the design status is set only by a critic the build did not
# start, judging CI's pinned shots of the head; a builder's verdict trailer counts for
# nothing; a region of the approved picture with no shot fails before any model runs;
# an answer that does not name the shot set it judged is refused.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; on_exit_keep_status 'rm -rf "$FIX" "$HERE/.critic-judge.plant.sh"'
J="$HERE/critic-judge.sh"
pass=0 fail=0
ok()  { pass=$((pass + 1)); echo "  ok  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }

HEAD=$(printf 'h%.0s' {1..40} | tr h 1); EVSHA=$(printf '2%.0s' {1..40})
D="$FIX/d"; mkdir -p "$D/shots"
# A gh that answers from files and records the statuses and comments it is sent.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
D="$FIX/d"
case "$1 $2" in
  "pr view")   cat "$D/pr.json"; exit 0 ;;
  "pr comment") n=$(ls "$D"/comment-* 2>/dev/null | wc -l | tr -d ' ')
               while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$D/comment-$n.md"; shift; done
               echo "https://github.com/acme/widgets/pull/7#issuecomment-$n"; exit 0 ;;
  "pr list")   cat "$D/list.json"; exit 0 ;;
  "issue view") [ -f "$D/ticket-labels" ] && cat "$D/ticket-labels"; exit 0 ;;
esac
if [ "$1" = api ]; then
  case "$*" in
    # The judge never posts the status itself: GitHub reads only the newest status, and a
    # ruleset that takes the check from one app would never see one posted with a user token.
    *"-X POST"*statuses*) printf '%s\n' "$*" >> "$D/raw-statuses"; printf '%s\n' "$*" >> "$FIX/raw-ever"; exit 0 ;;
    # It sends the verdict to the project's relay, which posts it with the Actions token.
    # What the relay would post is kept in $D/statuses, one line a status, as before.
    *"-X POST"*dispatches*)
      printf '%s\n' "$*" >> "$D/dispatches"
      sha=; st=; cx=; ds=; tu=
      for a in "$@"; do case "$a" in
        'client_payload[sha]='*) sha=${a#*=} ;; 'client_payload[state]='*) st=${a#*=} ;;
        'client_payload[context]='*) cx=${a#*=} ;; 'client_payload[description]='*) ds=${a#*=} ;;
        'client_payload[target_url]='*) tu=${a#*=} ;; esac; done
      printf 'relayed statuses/%s state=%s context=%s description=%s%s\n' "$sha" "$st" "$cx" "$ds" "${tu:+ target_url=$tu}" >> "$D/statuses"; exit 0 ;;
    *"commits/"*"/statuses"*) printf '%s\n' "$*" >> "$D/status-reads"
                        if [ -f "$D/head-statuses.json" ]; then cat "$D/head-statuses.json"
                        else echo '[{"context":"Design critic","state":"success","description":"Independent critic: SHIP","creator":{"login":"github-actions[bot]"}}]'; fi; exit 0 ;;
    *pulls/7/files*)    [ -f "$D/files.fail" ] && { echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; }; cat "$D/files.json"; exit 0 ;;
    *pulls/7/commits*)  cat "$D/commits.json"; exit 0 ;;
    *issues/7/comments*) jq -s '[.[] ]' "$D"/posted-*.json 2>/dev/null || echo '[]'; exit 0 ;;
    *issues/12599/comments*) [ -f "$D/comments.fail" ] && { echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; }; cat "$D/ticket-comments.json" 2>/dev/null || echo '[]'; exit 0 ;;
    *contents/.design/voice-mock.html*) cat "$D/mock.html"; exit 0 ;;
    *"commits?path="*)  [ -f "$D/history.fail" ] && { echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest"}'; exit 0; }
                        if [ -s "$D/pic-date" ]; then printf '[{"commit":{"committer":{"date":"%sT09:00:00Z"}}}]' "$(cat "$D/pic-date")"; else echo '[]'; fi; exit 0 ;;
  esac
fi
exit 0
SH
chmod +x "$BIN/gh"
# CI's evidence, stood in for: pinned at EVSHA, its shots fetched from $D/shots.
cat > "$FIX/ev" <<SH
#!/usr/bin/env bash
case "\$1" in
  status) cat "$D/ev-status" ;;
  fetch)  for f in "$D"/shots/*.png; do cp "\$f" "\$3/"; n=\$(basename "\$f" .png); th=light; case "\$n" in *dark*) th=dark ;; esac; printf '%s\t%s\t%s\t%s\n' "\$n" "\$3/\$n.png" "\$th" /settings/voices; done ;;
esac
SH
chmod +x "$FIX/ev"
# The critic, stood in for: it answers what $D/answer holds and keeps its prompt.
cat > "$FIX/claude" <<SH
#!/usr/bin/env bash
cat > "$D/prompt-seen"; printf '%s\n' "\$*" > "$D/argv"; cat "$D/answer"
SH
chmod +x "$FIX/claude"
export CRITIC_JUDGE_EVIDENCE="$FIX/ev" CRITIC_JUDGE_CLAUDE="$FIX/claude" CRITIC_JUDGE_DIR="$FIX/judge" CRITIC_JUDGE_LAUNCHER=coordinator
# Sign-offs, stood in for: $D/signed present means the PR's screens are signed.
printf '#!/usr/bin/env bash\n[ "$1" = signed-head ] && [ -f "%s/signed" ]\n' "$FIX/d" > "$FIX/ak"; chmod +x "$FIX/ak"; export CRITIC_JUDGE_APPROVAL="$FIX/ak"
export CRITIC_JUDGE_FINDINGS="$FIX/sf"; printf '#!/usr/bin/env bash\n[ "$1" = critic ] && printf "major\\t#7\\tnine narration lines on the voices page\\n"; [ "$1" = screens ] && [ -f "%s/d/screen" ] && cat "%s/d/screen"; exit 0\n' "$FIX" "$FIX" > "$FIX/sf"; chmod +x "$FIX/sf"
# Polish lists, stood in for: each add is kept in $D/polish-adds; $D/polish-fail makes it fail.
# Like the real one, a Major is opened as its own ticket (#555) and add says so.
printf '#!/usr/bin/env bash\n[ "$1" = add ] || exit 2\n[ -f "%s/d/polish-fail" ] && exit 2\nshift; printf "%%s\\t%%s\\n" "$1" "$2" >> "%s/d/polish-adds"\ncase "$2" in Major*) echo "#555: graded major, so not polish — its own ticket (P1), not an item on the list: $2" ;; esac\n' "$FIX" "$FIX" > "$FIX/pl"; chmod +x "$FIX/pl"; export CRITIC_JUDGE_POLISH="$FIX/pl"

# The coverage check, stood in for: it prints what $D/gaps holds (kind, file, routes, text).
printf '#!/usr/bin/env bash\n[ "$1" = judge ] && [ -f "%s/gaps" ] && { cat "%s/gaps"; exit 1; }\nexit 0\n' "$FIX/d" "$FIX/d" > "$FIX/cov"; chmod +x "$FIX/cov"
export CRITIC_JUDGE_COVERAGE="$FIX/cov"

reset() {
  rm -f "$D/gaps" "$D/polish-adds" "$D/polish-fail" "$D/screen"
  rm -f "$D"/comment-* "$D"/posted-* "$D/statuses" "$D/dispatches" "$D/raw-statuses" "$D/prompt-seen" "$D"/shots/* "$D/signed" "$D/ticket-comments.json"; rm -rf "$FIX/judge"
  echo 2026-10-20 > "$D/pic-date"   # a picture approved under the region and real-data rules
  jq -n --arg h "$HEAD" '{headRefOid:$h, isDraft:false, state:"OPEN", headRefName:"tkt-12599/share"}' > "$D/pr.json"
  printf 'head=%s\nsha=%s\nshots=2\nstate=pinned\nreason=pinned\n' "$HEAD" "$EVSHA" > "$D/ev-status"
  echo '[{"filename":"apps/web/voices/page.tsx","status":"modified"},{"filename":".design/voice-mock.html","status":"added"}]' > "$D/files.json"
  printf '[{"sha":"%s","commit":{"message":"chore: design-critic\\n\\nDesign-Critic: SHIP (agent) f9ad4e1a738d"}},{"sha":"%s","commit":{"message":"feat: grid"}}]' "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" > "$D/commits.json"
  cat > "$D/mock.html" <<'HTML'
<html data-real-data="duplicate-names longest-names empty scrolled"><body>
<section data-evidence-shot="voice-grid-laptop-light" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="light"></section>
<section data-evidence-shot="voice-menu-phone-dark" data-evidence-route="/settings/voices" data-evidence-viewport="phone" data-evidence-theme="dark"></section>
</body></html>
HTML
  printf 'P1' > "$D/shots/voice-grid-laptop-light.png"; printf 'P2' > "$D/shots/voice-menu-phone-dark.png"
}
set_of() { bash "$J" shotset "$D/shots"; }
answer() { # <verdict> [<live findings, one a line>]
  { echo "SHOTS: $(set_of) at $EVSHA"; echo "JUDGED: $(ls "$D/shots" | sed 's/\.png$//' | tr '\n' ' ')"
    echo "**PARITY: MATCH** — matches."; echo "**VERDICT: $1** — the grid reads at a glance."
    printf 'For: owners sharing voices.\nHappening: the grid lists who can use each voice.\nNext: change a level.\n'
    echo "**Why:** 1. **Minor** → was the stray token; it is gone now."
    echo "Major issues: 0"
    echo "FINDINGS"; [ -n "${2:-}" ] && printf '%s\n' "$2"; echo "END FINDINGS"; } > "$D/answer"
}
status_line() { tail -1 "$D/statuses" 2>/dev/null; }

echo "critic-judge"
# 0 Only the coordinator (or a person) starts it.
reset; answer SHIP
out=$(CRITIC_JUDGE_LAUNCHER= bash "$J" run 7 2>&1); rc=$?
[ $rc -eq 2 ] && [ ! -s "$D/statuses" ] && ok "started by anything but the coordinator, it refuses" || bad "launcher: rc=$rc $out"

# 1 A build run cannot judge.
reset; answer SHIP
out=$(HARNESS_DRIVER_RUN="12599:repair" bash "$J" run 7 2>&1); rc=$?
[ $rc -eq 2 ] && [ ! -s "$D/statuses" ] && printf '%s' "$out" | grep -q 'cannot judge' && ok "a build run is refused and posts no status" || bad "build run: rc=$rc $out"

# 2 A clean SHIP: success on the head, naming the shot set; the builder's trailer named as ignored.
reset; answer SHIP
bash "$J" run 7 >/dev/null 2>&1; rc=$?
s=$(status_line); set=$(set_of)
[ $rc -eq 0 ] && printf '%s' "$s" | grep -q "statuses/$HEAD" && printf '%s' "$s" | grep -q 'state=success' \
  && printf '%s' "$s" | grep -q "shots $set" && printf '%s' "$s" | grep -q 'context=Design critic' \
  && ok "SHIP posts success on the head, its description naming shot set $set" || bad "ship: rc=$rc status=$s"
grep -q "<!-- critic-judge head=$HEAD shots=$set verdict=SHIP -->" "$D/comment-0.md" && ok "the verdict comment carries head, shot set and verdict" || bad "comment marker: $(head -2 "$D/comment-0.md")"
grep -q 'Ignored: design verdicts written on the branch' "$D/comment-0.md" && grep -q 'aaaaaaaaaaaa` chore: design-critic' "$D/comment-0.md" \
  && ok "a Design-Critic trailer the builder committed is named as ignored" || bad "trailer not flagged"
d=$(tail -1 "$D/dispatches" 2>/dev/null)
printf '%s' "$d" | grep -qE 'repos/[^ ]+/dispatches' && printf '%s' "$d" | grep -q 'event_type=design-critic-verdict' \
  && printf '%s' "$d" | grep -q "client_payload\[sha\]=$HEAD" && printf '%s' "$d" | grep -q 'client_payload\[pr\]=7' \
  && [ ! -s "$D/raw-statuses" ] \
  && ok "the verdict goes to the project's relay as a dispatch naming the head and the PR, never as a raw status" || bad "dispatch: $d / raw: $(cat "$D/raw-statuses" 2>/dev/null)"
grep -q 'nine narration lines' "$D/prompt-seen" && grep -q 'voice-mock.html' "$D/prompt-seen" \
  && ok "the critic is handed the open findings for the screen and the approved picture" || bad "prompt lacks findings/picture"

# 3 THE BUG: the picture's phone region was never photographed. Fails without a model call.
reset; answer SHIP; rm "$D/shots/voice-menu-phone-dark.png"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
s=$(status_line)
[ $rc -ne 0 ] && printf '%s' "$s" | grep -q 'state=failure' && [ ! -f "$D/prompt-seen" ] \
  && grep -q 'evidence gap.*voice-menu-phone-dark' "$D/comment-0.md" && ok "a picture region with no pinned shot fails, named, before any model runs" || bad "gap: rc=$rc status=$s"

# 3b THE BUG (#297): the PR changed a drawer and no capture step opens it. Fails without a
# model call, as an evidence-gap finding the repair reads from the judge's record.
reset; answer SHIP
printf 'missing-state\tapps/web/voices/VoiceDrawer.tsx\t/settings/voices\tevidence gap: apps/web/voices/VoiceDrawer.tsx is a drawer that only shows once opened, and no capture-plan shot on /settings/voices has setup steps that open it\n' > "$D/gaps"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && printf '%s' "$(status_line)" | grep -q 'state=failure' && [ ! -f "$D/prompt-seen" ] \
  && grep -q '^- Major · evidence gap: apps/web/voices/VoiceDrawer.tsx is a drawer' "$D/comment-0.md" \
  && grep -q 'VoiceDrawer.tsx' "$FIX/judge/findings-7.txt" \
  && ok "a changed drawer no capture step opens fails as an evidence gap, before any model runs" || bad "coverage gap: rc=$rc $(status_line)"
printf '%s' "$(CRITIC_JUDGE_DIR="$FIX/judge" bash "$HERE/screen-findings.sh" critic 7 | cut -f3 | python3 -I "$HERE/evidence-gaps.py" classify)" | grep -q 'VoiceDrawer' \
  && ok "and the repair's evidence tasks pick that finding up" || bad "the gap finding is not read as an evidence task"

# 4 SHIP beside a Minor is not a pass (Minors block).
reset; answer SHIP "- Minor · the lock icon sits 2px low → fix: align to the baseline"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && grep -q '^- Minor · the lock icon' "$D/comment-0.md" \
  && ok "a SHIP that lists a Minor fails, and the Minor is a finding" || bad "minor passed: $(status_line)"

# 4b Resolved findings and counts in the prose are not findings: only the FINDINGS block is read.
reset; answer SHIP
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && ok "a resolved Minor and 'Major issues: 0' in the prose do not block" || bad "resolved read as live: $(status_line)"

# 4c An answer without the FINDINGS block, or that does not say it judged every shot, is refused.
reset; answer SHIP; sed -i.b '/FINDINGS/d' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1; [ ! -s "$D/statuses" ] && ok "an answer with no FINDINGS block is refused" || bad "no block: $(status_line)"
reset; answer SHIP; sed -i.b 's/^JUDGED: .*/JUDGED: voice-grid-laptop-light/' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1; [ ! -s "$D/statuses" ] && ok "an answer that does not name every shot it judged is refused" || bad "partial judged: $(status_line)"

# 4d The same pixels at a new head (a develop merge that changed no screen): the same verdict, no model.
reset; answer SHIP; bash "$J" run 7 >/dev/null 2>&1
NEW=$(printf '3%.0s' {1..40}); jq --arg h "$NEW" '.headRefOid = $h' "$D/pr.json" > "$D/pr2" && mv "$D/pr2" "$D/pr.json"
rm -f "$D/prompt-seen"; bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q "statuses/$NEW.*state=success" && [ ! -f "$D/prompt-seen" ] \
  && ok "carried shots get the ledger's verdict again at the new head, with no model call" || bad "re-judged: $(status_line)"

# 4e A forged comment carrying the judge's marker is not a verdict.
reset; answer SLOP "- Major · x"
jq -n --arg h "$HEAD" --arg s "$(set_of)" '{body:("<!-- critic-judge head=" + $h + " shots=" + $s + " verdict=SHIP -->"), html_url:"u"}' > "$D/posted-0.json"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && [ -f "$D/prompt-seen" ] && ok "a comment wearing the judge's marker is not read as a verdict" || bad "forged comment trusted: $(status_line)"

# 4f A red verdict on a signed-off PR is the PM's call: the ticket is held, not repaired.
reset; touch "$D/signed"; answer SLOP "- Major · five rows read Sam Member"
bash "$J" run 7 >/dev/null 2>&1
grep -q 'issue edit 12599 .*--add-label status:pm-decision' "$GH_LOG" && grep -q "PM's call" "$D/comment-0.md" \
  && ok "a red verdict on a signed-off PR goes to the PM" || bad "signed-off red not held"

# 4g A picture with no regions, or drawn from tidy data, fails closed.
reset; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && grep -q "real data: 'duplicate-names'" "$D/comment-0.md" && [ ! -f "$D/prompt-seen" ] \
  && ok "a tidy picture fails closed, before any model" || bad "tidy picture passed: $(status_line)"

# 5 PARITY: DRIFT fails.
reset; answer SHIP; sed -i.b 's/PARITY: MATCH/PARITY: DRIFT/' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a drift from the approved picture fails" || bad "drift passed"

# 6 An answer that does not name the shot set is refused, and no status is set.
reset; answer SHIP; sed -i.b '1d' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -s "$D/statuses" ] && ok "a verdict that does not name its shot set is refused, never recorded" || bad "unnamed set: rc=$rc $(status_line)"

# 7 Stale shots hold the PR (pending), and no model runs.
reset; answer SHIP; sed -i.b 's/state=pinned/state=stale/' "$D/ev-status"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=pending' && [ ! -f "$D/prompt-seen" ] && ok "shots from before a change to the screens hold the PR, judged by nobody" || bad "stale: $(status_line)"

# 8 No pinned shots yet: nothing posted.
reset; answer SHIP; sed -i.b 's/state=pinned/state=pending/' "$D/ev-status"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && [ ! -s "$D/statuses" ] && ok "with no pinned shots it waits and posts nothing" || bad "pending: rc=$rc"

# 8b CI's own record says the head has nothing to photograph: success, no model.
OLD=$(printf '3%.0s' {1..40})
ev_none() { # <head CI read> [<head its nothing-to-photograph record names>]
  { printf 'head=%s\nsha=\nshots=0\nstate=none\n' "$1"; [ -n "${2:-}" ] && printf 'nothing=%s\n' "$2"; echo "reason=r"; } > "$D/ev-status"
}
reset; answer SHIP; ev_none "$HEAD" "$HEAD"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
printf '%s' "$(status_line)" | grep -q "statuses/$HEAD .*state=success.*description=Independent critic: no rendered change — CI found nothing to photograph at ${HEAD:0:9}" \
  && [ $rc -eq 0 ] && [ ! -f "$D/prompt-seen" ] && ok "CI's nothing-to-photograph record for the head sets success, judged by nobody" || bad "nothing to photograph: rc=$rc $(status_line)"
# 8c No record that the head has nothing (CI never decided, e.g. the PR is not armed): stays pending.
reset; answer SHIP; ev_none "$HEAD"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && [ ! -s "$D/statuses" ] && ! grep -q "^7	" "$FIX/judge/none.tsv" 2>/dev/null \
  && ok "with no nothing-to-photograph record it posts nothing and asks again later" || bad "no record: rc=$rc $(status_line)"
# 8d A record for an older head is not this head's record.
reset; answer SHIP; ev_none "$OLD" "$OLD"; bash "$J" run 7 >/dev/null 2>&1
[ ! -s "$D/statuses" ] && ok "a record CI made for an older head posts nothing" || bad "older head: $(status_line)"
reset; answer SHIP; ev_none "$HEAD" "$OLD"; bash "$J" run 7 >/dev/null 2>&1
[ ! -s "$D/statuses" ] && ok "a record naming an older sha posts nothing" || bad "older record: $(status_line)"

# 9 due: a status a trailer earned (CI's own wording) is owed a judgement; the judge's own is not.
jq -n --arg h "$HEAD" '[
  {number:7, headRefOid:$h, isDraft:false, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"SHIP for UI fingerprint f9ad4e1a738d"}]},
  {number:8, headRefOid:$h, isDraft:false, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Independent critic: SHIP on shots abc"}]},
  {number:9, headRefOid:$h, isDraft:false, body:"no evidence", statusCheckRollup:[]},
  {number:10, headRefOid:$h, isDraft:true, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[]},
  {number:11, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"PENDING", description:"Waiting for CI"}]},
  {number:12, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Nothing owed"}]}]' > "$D/list.json"
export GH_PRS_FILE="$D/list.json"; mkdir -p "$FIX/judge"; printf '12\t%s\n' "$HEAD" > "$FIX/judge/none.tsv"
printf '8\t%s\tabc\tSHIP\tsuccess\tu\n' "$HEAD" > "$FIX/judge/verdicts.tsv"
printf '8\t%s\tsuccess\n12\t%s\tsuccess\n' "$HEAD" "$HEAD" > "$FIX/judge/relayed.tsv"
out=$(bash "$J" due)
[ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "7 11 " ] && ok "due: what the ledger holds for the head is settled; a trailer's status, a pending one are owed" || bad "due: $out"
printf '7\t%s\tabc\tSHIP\tsuccess\tu\n' "$HEAD" > "$FIX/judge/verdicts.tsv"
jq '.[0].statusCheckRollup[0].description = "Independent critic: SHIP on shots abc"' "$D/list.json" > "$D/l2" && mv "$D/l2" "$D/list.json"
printf '9\t%s\tabc\tSHIP\tsuccess\tu\n' "$HEAD" > "$FIX/judge/verdicts.tsv"
out=$(bash "$J" due)
printf '%s\n' "$out" | cut -f1 | grep -qx 8 && ok "due: a status whose description claims the judge, with no ledger entry, is still owed" || bad "description trusted: $out"
# 9b A verdict recorded before it went through the relay is owed once more, from the ledger.
case_unrelayed() {
  jq -n --arg h "$HEAD" '[{number:8, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Independent critic: SHIP on shots abc"}]},
    {number:12, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Independent critic: no rendered change"}]}]' > "$D/list.json"
  printf '8\t%s\tabc\tSHIP\tsuccess\tu\n' "$HEAD" > "$FIX/judge/verdicts.tsv"; printf '12\t%s\n' "$HEAD" > "$FIX/judge/none.tsv"
  rm -f "$FIX/judge/relayed.tsv"; local a b; a=$(bash "$J" due | cut -f1 | tr '\n' ' ')
  printf '8\t%s\tsuccess\n12\t%s\tsuccess\n' "$HEAD" "$HEAD" > "$FIX/judge/relayed.tsv"; b=$(bash "$J" due | cut -f1 | tr '\n' ' ')
  [ "$a" = "8 12 " ] && [ -z "$b" ] && echo green || echo red
}
[ "$(case_unrelayed)" = green ] && ok "due: a verdict never sent through the relay is owed again (no model: the ledger answers); once sent it is settled" || bad "unrelayed: $(case_unrelayed)"
# 9b2 Sent is not posted: a head whose newest status the relay did not post is owed again,
# nothing-to-photograph included; once read back as the relay's, it is settled and not read again.
case_unposted() {
  jq -n --arg h "$HEAD" '[8,12] | map({number:., headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS"}]})' > "$D/list.json"
  printf '8\t%s\tabc\tSHIP\tsuccess\tu\n' "$HEAD" > "$FIX/judge/verdicts.tsv"; printf '12\t%s\n' "$HEAD" > "$FIX/judge/none.tsv"
  printf '8\t%s\tsuccess\n12\t%s\tsuccess\n' "$HEAD" "$HEAD" > "$FIX/judge/relayed.tsv"; rm -f "$FIX/judge/confirmed.tsv" "$D/status-reads"
  local a b c
  # The Mac's own status is still the newest: the relay never posted.
  echo '[{"context":"Design critic","state":"success","description":"Independent critic: SHIP","creator":{"login":"the-owner"}},{"context":"Design critic","state":"success","description":"Independent critic: SHIP","creator":{"login":"github-actions[bot]"}}]' > "$D/head-statuses.json"
  a=$(bash "$J" due | cut -f1 | tr '\n' ' ')
  rm -f "$D/head-statuses.json"; b=$(bash "$J" due | cut -f1 | tr '\n' ' ')
  : > "$D/status-reads"; c=$(bash "$J" due | cut -f1 | tr '\n' ' ')
  rm -f "$D/head-statuses.json"
  [ "$a" = "8 12 " ] && [ -z "$b" ] && [ -z "$c" ] && [ ! -s "$D/status-reads" ] && echo green || echo "red: '$a' '$b' '$c' reads=$(grep -c . "$D/status-reads" 2>/dev/null)"
}
r=$(case_unposted); [ "$r" = green ] && ok "due: a verdict sent but never posted by the relay is owed again; once read back it is settled, and not read again" || bad "unposted: $r"

# 9b3 Stale shots: the pending verdict goes once a head, not once a sweep.
reset; answer SHIP; sed -i.b 's/state=pinned/state=stale/' "$D/ev-status"
bash "$J" run 7 >/dev/null 2>&1; bash "$J" run 7 >/dev/null 2>&1
[ "$(grep -c . "$D/dispatches" 2>/dev/null)" = 1 ] && ok "a stale head's pending verdict is sent once, not on every sweep" || bad "stale sends: $(grep -c . "$D/dispatches" 2>/dev/null)"

# 9c A run that sends the verdict records it as relayed.
case_relayed_rec() { reset; answer SHIP; bash "$J" run 7 >/dev/null 2>&1; grep -q "^7	$HEAD	success$" "$FIX/judge/relayed.tsv" 2>/dev/null && echo green || echo red; }
[ "$(case_relayed_rec)" = green ] && ok "a sent verdict is recorded as relayed for its head" || bad "relayed.tsv: $(cat "$FIX/judge/relayed.tsv" 2>/dev/null)"

echo "scope: only what the change changed blocks (#315)"
# The picture names the files that draw each region: the grid is drawn by the voices page
# the PR changes, the menu by a folder it does not touch.
scoped() {
  sed -i.b 's|data-evidence-shot="voice-grid-laptop-light"|& data-evidence-files="apps/web/voices/**"|; s|data-evidence-shot="voice-menu-phone-dark"|& data-evidence-files="apps/web/menu/**"|' "$D/mock.html"
}
FOUR='- Major · voice-grid-laptop-light · the grid header overlaps the first row → fix: pad the header
- Major · voice-menu-phone-dark · the menu clips its last item → fix: let it scroll
- Minor · untouched · the page title is cut to "Voi…" on phone → fix: give it priority
- Minor · untouched · a toast fires on load → fix: trace the failing search'
# S1 THE BUG: one finding in the changed region, three outside it. Blocks on one, lists three.
case_s1() { reset; scoped; echo voices > "$D/screen"; answer SLOP "$FOUR"; bash "$J" run 7 >/dev/null 2>&1; }
case_s1
[ "$(grep -c . "$FIX/judge/findings-7.txt" 2>/dev/null)" = 1 ] && grep -q 'grid header overlaps' "$FIX/judge/findings-7.txt" \
  && printf '%s' "$(status_line)" | grep -q 'state=failure' && printf '%s' "$(status_line)" | grep -q '1 blocking' \
  && ok "a finding in a changed region blocks, alone" || bad "changed: $(status_line) $(cat "$FIX/judge/findings-7.txt" 2>/dev/null)"
[ "$(grep -c . "$D/polish-adds" 2>/dev/null)" = 3 ] && [ "$(cut -f1 "$D/polish-adds" | sort -u)" = voices ] \
  && grep -q $'^voices\tMajor · the menu clips its last item' "$D/polish-adds" && grep -q 'toast fires on load.*outside what it changed' "$D/polish-adds" \
  && ok "the three outside it go to the screen's polish list, graded" || bad "polish adds: $(cat "$D/polish-adds" 2>/dev/null)"
grep -q 'menu clips its last item.*its own ticket #555, not polish' "$D/comment-0.md" && ! grep -q 'toast fires on load.*its own ticket' "$D/comment-0.md" \
  && ok "a Major outside the change is named as its own ticket, not as polish" || bad "own ticket: $(sed -n '/### Outside/,/###/p' "$D/comment-0.md")"
grep -q 'Outside this change — on the `voices` polish list' "$D/comment-0.md" && ! sed -n '/^### Findings/,/^### Outside/p' "$D/comment-0.md" | grep -q 'menu clips' \
  && ok "the comment lists them apart, not as findings" || bad "comment: $(sed -n '/### Findings/,/### Shots/p' "$D/comment-0.md")"
grep -q '^apps/web/voices/page.tsx$' "$D/prompt-seen" && grep -q $'^voice-menu-phone-dark\tuntouched' "$D/prompt-seen" \
  && ok "the critic is shown the diff's files and each region's scope" || bad "prompt lacks the scope"

# S2 Findings all outside the change: the critic's SLOP is not this change's failure.
case_s2() { reset; scoped; answer SLOP "$(printf '%s\n' "$FOUR" | sed 1d)"; bash "$J" run 7 >/dev/null 2>&1; }
case_s2
printf '%s' "$(status_line)" | grep -q 'state=success' && [ ! -f "$FIX/judge/findings-7.txt" ] && [ "$(grep -c . "$D/polish-adds")" = 3 ] \
  && cut -f1 "$D/polish-adds" | grep -qx settings-voices \
  && ok "with every finding outside the change it passes, and they are listed (under the shots' route with no screen label)" || bad "outside only: $(status_line)"

# S3 An outside finding that cannot be listed still blocks: nothing is dropped.
case_s3() { reset; scoped; touch "$D/polish-fail"; answer SLOP "- Minor · untouched · a toast fires on load"; bash "$J" run 7 >/dev/null 2>&1; }
case_s3
printf '%s' "$(status_line)" | grep -q 'state=failure' && grep -q 'toast fires' "$FIX/judge/findings-7.txt" \
  && ok "an outside finding the polish list refused blocks" || bad "dropped: $(status_line)"

# S4 A region that names no files is changed, whatever the critic thinks.
case_s4() { reset; scoped; sed -i.b 's| data-evidence-files="apps/web/menu/\*\*"||' "$D/mock.html"; answer SLOP "- Major · voice-menu-phone-dark · the menu clips"; bash "$J" run 7 >/dev/null 2>&1; }
case_s4
printf '%s' "$(status_line)" | grep -q 'state=failure' && [ ! -s "$D/polish-adds" ] \
  && ok "a finding in a region with no files named blocks (unknown is changed)" || bad "unknown passed: $(status_line)"
# S4b The region's scope is the picture's, not the critic's word.
case_s4b() { reset; scoped; answer SLOP "- Major · voice-grid-laptop-light · overlaps"; bash "$J" run 7 >/dev/null 2>&1; }
case_s4b
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a finding in a changed region blocks" || bad "changed region passed"

# S5 (#289 review) A line that says the finding is resolved is no finding.
case_s5() { reset; answer SHIP "$(printf -- '- Major · none\n- Minor · changed · the header narration — gone\n- Major · 0\n- Minor · the stray token (fixed)\nnone\n0')"; bash "$J" run 7 >/dev/null 2>&1; }
case_s5
printf '%s' "$(status_line)" | grep -q 'state=success' && ok "'none', '0', '— gone' and '(fixed)' lines never block" || bad "resolved blocked: $(status_line)"
# S5b "gone" inside a live finding is still a finding.
reset; answer SHIP "- Major · the save button is gone from the header → fix: restore it"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a finding that something is gone still blocks" || bad "'is gone' read as resolved"

# S6 (#289 review) The verdict is read off its own line, not a quote of one in the prose.
case_s6() { reset; answer SLOP; sed -i.b '3i\
The last critic said VERDICT: SHIP at the previous head; that no longer holds.
' "$D/answer"; bash "$J" run 7 >/dev/null 2>&1; }
case_s6
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a VERDICT quoted in the prose is not the verdict" || bad "prose verdict read: $(status_line)"

echo "older pictures: regions derived, real data by approval date"
# A picture drawn before the region convention: two frames, a phone inside the first,
# a dark theme in its styles, and no data-evidence-* markers at all.
legacy() {
  cat > "$D/mock.html" <<'HTML'
<html><head><style>@media (prefers-color-scheme: dark) { :root { --bg: #111 } }</style></head><body>
<section class="frame" id="grid"><h3>The grid</h3><div class="phone">the grid on a phone</div></section>
<section class="frame" id="empty"><h3>Nobody yet</h3></section>
</body></html>
HTML
  jq --arg b $'Closes #12599\n\n## Evidence routes\n- /settings/voices\n' '.body = $b' "$D/pr.json" > "$D/pr2" && mv "$D/pr2" "$D/pr.json"
  rm -f "$D"/shots/*
  # CI names its shots by the route, not by the picture's frames.
  printf 'L1' > "$D/shots/settings-voices.png"; printf 'L2' > "$D/shots/settings-voices-dark.png"
  printf 'L3' > "$D/shots/settings-voices-phone.png"; printf 'L4' > "$D/shots/settings-voices-phone-dark.png"
}
case_legacy() { reset; legacy; echo 2026-10-18 > "$D/pic-date"; answer SHIP; bash "$J" run 7 >/dev/null 2>&1; }

# L1 THE BUG (#289 on older pictures): no markers failed closed on every older PR.
case_legacy
s=$(status_line)
printf '%s' "$s" | grep -q 'state=success' && printf '%s' "$s" | grep -q 'regions derived from frames (4)' && [ -f "$D/prompt-seen" ] \
  && ok "an older picture with no markers is judged on regions derived from its frames, and the status says so" || bad "legacy: $s $(cat "$D"/comment-0.md 2>/dev/null | grep -i 'picture' | head -3)"
grep -q 'grid-phone-dark' "$D/prompt-seen" && ! grep -q 'empty-laptop-light' "$D/prompt-seen" \
  && ok "each page state is a region at the widths and themes the picture draws, once however many frames draw it" || bad "derived regions not in the prompt: $(grep -A8 'regions the picture' "$D/prompt-seen")"

# L2 A derived region CI did not photograph is still a gap.
reset; legacy; echo 2026-10-18 > "$D/pic-date"; rm "$D/shots/settings-voices-phone-dark.png"; answer SHIP
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && grep -q 'evidence gap.*grid-phone-dark' "$D/comment-0.md" && [ ! -f "$D/prompt-seen" ] \
  && ok "a derived region with no shot of its route, width and theme fails, named" || bad "derived gap: $(status_line)"

# L3 No frames: the PR's own evidence routes at laptop/phone x light/dark.
reset; legacy; echo 2026-10-18 > "$D/pic-date"; echo '<html><body><div>an old picture with no frames</div></body></html>' > "$D/mock.html"; answer SHIP
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && printf '%s' "$(status_line)" | grep -q 'derived from the PR routes (4)' \
  && ok "a picture with no frames falls back to the evidence routes x laptop/phone x light/dark, and says so" || bad "routes fallback: $(status_line)"

# D1 A picture approved before 2026-10-20 is not refused for tidy data; the critic still sees the real-data brief.
reset; echo 2026-10-18 > "$D/pic-date"; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && [ -f "$D/prompt-seen" ] && grep -q '^## Real data' "$D/prompt-seen" \
  && ok "a tidy picture approved before 2026-10-20 is exempt; the critic is still held to real data on the screen" || bad "old tidy refused: $(status_line)"
# D2 No date known: exempt.
reset; : > "$D/pic-date"; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && ok "a picture with no known approval date is exempt" || bad "undated refused: $(status_line)"
# D3 The ticket's "Picture approved" comment counts: the earlier date wins.
reset; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"
echo '[{"body":"Picture approved: https://claude.ai/artifact/x","created_at":"2026-10-17T12:00:00Z"}]' > "$D/ticket-comments.json"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && ok "the ticket's 'Picture approved' comment dates the picture" || bad "comment date ignored: $(status_line)"
# D4 (4g, again) From 2026-10-20 on a tidy picture is refused.
reset; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a tidy picture approved on 2026-10-20 is still refused" || bad "new tidy passed: $(status_line)"

echo "places: more than one judge, none held for ever"
reset; rm -f "$FIX/judge/verdicts.tsv" "$FIX/judge/none.tsv" "$FIX/judge/tried.tsv" "$FIX/judge/launched.tsv"
jq -n --arg h "$HEAD" '[21,22,23,24] | map({number:., headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"SHIP for UI fingerprint f9"}]})' > "$D/list.json"
starts() { CRITIC_JUDGE_ROOM="$1" bash "$J" sweep --dry-run 2>/dev/null | grep -o 'would judge PR #[0-9]*' | grep -o '[0-9]*$' | tr '\n' ' '; }
case_three() { [ "$(starts 5)" = "21 22 23 " ] && echo green || echo red; }
[ "$(case_three)" = green ] && ok "with room on the machine, three judges run at once by default" || bad "three: $(starts 5)"
[ "$(starts 0)" = "21 " ] && ok "with no room on the machine, the one place that is always open still judges" || bad "no room: $(starts 0)"
[ "$(CRITIC_JUDGE_MAX_LIVE=2 starts 5)" = "21 22 " ] && ok "the most at once is configurable" || bad "max 2: $(CRITIC_JUDGE_MAX_LIVE=2 starts 5)"
case_fair() { rm -f "$FIX/judge/launched.tsv"; mkdir -p "$FIX/judge"; printf '21\t%s\t%s\n' "$HEAD" "$(date +%s)" > "$FIX/judge/launched.tsv"
  r=$(starts 0); rm -f "$FIX/judge/launched.tsv"; [ "$r" = "22 " ] && echo green || echo red; }
[ "$(case_fair)" = green ] && ok "a PR started last time waits behind one never started" || bad "fair: the same PR took the place again"
case_reap() {
  echo '[]' > "$D/list.json"; mkdir -p "$FIX/judge"; rm -f "$FIX/judge/tried.tsv"
  perl -e 'use POSIX qw(setsid); setsid(); sleep 300' & local old=$!
  perl -e 'use POSIX qw(setsid); setsid(); sleep 300' & local young=$!
  printf '%s %s %s\n' "$old" "$HEAD" "$(( $(date +%s) - 1300 ))" > "$FIX/judge/31.pid"
  printf '%s %s %s\n' "$young" "$HEAD" "$(date +%s)" > "$FIX/judge/32.pid"
  CRITIC_JUDGE_ROOM=0 bash "$J" sweep >/dev/null 2>&1; sleep 1
  local r=green
  kill -0 "$old" 2>/dev/null && r=red
  [ -f "$FIX/judge/31.pid" ] && r=red
  grep -q "^31	$HEAD" "$FIX/judge/tried.tsv" 2>/dev/null || r=red
  kill -0 "$young" 2>/dev/null || r=red
  kill "$old" "$young" 2>/dev/null; wait "$old" "$young" 2>/dev/null; rm -f "$FIX/judge"/3?.pid
  echo "$r"
}
[ "$(case_reap)" = green ] && ok "a judge past 20 minutes is stopped, its place given back and the try counted; a young one runs on" || bad "a stuck judge kept its place"

echo "plants"
plant() { # <desc> <old> <new> <case number to re-run> <expect-text>
  local P="$HERE/.critic-judge.plant.sh"; cp "$J" "$P"
  python3 - "$P" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  J_ORIG="$J"; J="$P"
  # A plant's own raw POSTs are not the shipped judge's.
  cp "$FIX/raw-ever" "$FIX/raw-ever.keep" 2>/dev/null || : > "$FIX/raw-ever.keep"
  local r; r=$("$4"); J="$J_ORIG"; rm -f "$P"; mv -f "$FIX/raw-ever.keep" "$FIX/raw-ever"
  [ "$r" = red ] && ok "planted: $1 → red" || bad "planted: $1 → not caught"
}
case_build()  { reset; answer SHIP; HARNESS_DRIVER_RUN=x bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
case_gap()    { reset; rm "$D/shots/voice-menu-phone-dark.png"; answer SHIP; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
case_minor()  { reset; answer SHIP "- Minor · x"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
case_noset()  { reset; answer SHIP; sed -i.b '1d' "$D/answer"; bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
case_relay()  { reset; answer SHIP; bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/raw-statuses" ] || [ ! -s "$D/dispatches" ] && echo red || echo green; }
plant "the verdict posted as a raw status again" 'local a=(api -X POST "repos/$REPO_SLUG/dispatches"' 'local a=(api -X POST "repos/$REPO_SLUG/statuses/$1"' case_relay
case_unposted_rc() { [ "$(case_unposted)" = green ] && echo green || echo red; }
plant "a sent verdict counts as posted" 'relayed "$pr" "$head" && posted "$pr" "$head" && continue
        rec=' 'relayed "$pr" "$head" && continue
        rec=' case_unposted_rc
plant "the poster is never checked" '(.creator.login // "") == $who and ' '' case_unposted_rc
plant "the sent verdict is never recorded as relayed" 'printf '"'"'%s\t%s\t%s\n'"'"' "$1" "$2" "$5" >> "$RELAYED"' ':' case_relayed_rec
plant "a build run may judge"            '[ -z "${HARNESS_DRIVER_RUN:-}" ] ||' 'true ||' case_build
plant "the picture's regions are not checked" 'if [ -n "$miss" ] || [ -n "$lint" ] || [ -n "$gaps" ]; then' 'if [ -n "$lint" ] || [ -n "$gaps" ]; then' case_gap
case_cov()    { reset; answer SHIP; printf 'missing-route\tx/A.tsx\t/a\tevidence gap: x/A.tsx changed and no route renders it\n' > "$D/gaps"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
plant "a changed screen nobody photographed passes" 'if [ -n "$miss" ] || [ -n "$lint" ] || [ -n "$gaps" ]; then' 'if [ -n "$miss" ] || [ -n "$lint" ]; then' case_cov
plant "the coverage check is never asked" 'gaps=$(bash "$COVERAGE" judge' 'gaps=$(true' case_cov
plant "a Minor does not block"          '[ -z "$blocks" ] && { [ "$verdict" = SHIP ]' '{ [ "$verdict" = SHIP ]' case_minor
red_s1() { case_s1; [ "$(grep -c . "$FIX/judge/findings-7.txt" 2>/dev/null)" = 1 ] && [ "$(grep -c . "$D/polish-adds" 2>/dev/null)" = 3 ] && echo green || echo red; }
red_s2() { case_s2; status_line | grep -q 'state=success' && echo green || echo red; }
red_s3() { case_s3; status_line | grep -q 'state=failure' && grep -q 'toast fires' "$FIX/judge/findings-7.txt" 2>/dev/null && echo green || echo red; }
red_s4() { case_s4; status_line | grep -q 'state=failure' && echo green || echo red; }
red_s5() { case_s5; status_line | grep -q 'state=success' && echo green || echo red; }
red_s6() { case_s6; status_line | grep -q 'state=failure' && echo green || echo red; }
plant "every finding blocks, in or out of the change" 'blocks=$(printf '"'"'%s\n'"'"' "$blocks" | grep -v '"'"'^$'"'"' | split_scope "$W/scope.tsv")' 'blocks=$(printf '"'"'%s\n'"'"' "$blocks" | grep -v '"'"'^$'"'"' | sed "s/^/changed	/")' red_s1
plant "outside findings are never listed"  'bash "$PL" add "$slug"' 'true "$slug"' red_s1
plant "a SLOP outside the change still fails" '[ "$verdict" = SHIP ] || [ -n "$listed" ]; }' '[ "$verdict" = SHIP ]; }' red_s2
plant "a refused listing drops the finding" 'blocks="$blocks${blocks:+$'"'"'\n'"'"'}$f"' ':' red_s3
plant "unknown scope counts as untouched"  'w = (sc[t] == "untouched") ? "untouched" : "changed"' 'w = (sc[t] != "changed") ? "untouched" : "changed"' red_s4
plant "resolved lines are read as live"    'if (tolower(t) !~ ENVIRON["RE"]) print' 'print' red_s5
plant "the verdict matched anywhere"       "VLINE='^[[:space:]>#*_]*VERDICT:" "VLINE='VERDICT:" red_s6
case_forged() { reset; answer SLOP "- Major · x"; jq -n --arg h "$HEAD" --arg s "$(set_of)" '{body:("<!-- critic-judge head=" + $h + " shots=" + $s + " verdict=SHIP -->"), html_url:"u"}' > "$D/posted-0.json"; mkdir -p "$FIX/judge"; printf '7\t%s\t%s\tSHIP\tsuccess\tu\n' "$HEAD" "$(set_of)" > "$FIX/forged"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
plant "the verdict read off a PR comment"  'prev=$(ledger_set "$pr" "$set")' 'prev=$(swarm_gh api "repos/$REPO_SLUG/issues/$pr/comments" | jq -r ".[] | .body" | grep -q "verdict=SHIP" && printf "%s\t%s\t%s\tSHIP\tsuccess\tu" "$pr" "$head" "$set")' case_forged
case_tidy()   { reset; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
plant "the picture is not linted"          'lint="$lint"$'"'"'\n'"'"'"$(python3 -I "$PE" lint' 'true || lint="$lint"$'"'"'\n'"'"'"$(python3 -I "$PE" lint' case_tidy
plant "an answer need not name its set" 'if ! grep -qF "SHOTS: $set" "$answer"; then' 'if false; then' case_noset

case_legacy_rc() { case_legacy; status_line | grep -q 'state=success' && echo green || echo red; }
case_old_tidy() { reset; echo 2026-10-18 > "$D/pic-date"; answer SHIP; sed -i.b 's/ data-real-data="[^"]*"//' "$D/mock.html"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo green || echo red; }
plant "an unmarked picture fails closed (no derivation)" 'popt=(--derive)' 'popt=()' case_legacy_rc
plant "every picture owes real data, whatever its date" '--approved "${d:-none}"' '--approved today' case_old_tidy
plant "no picture date is read" 'd=$(picture_date "$f" "$head" "$W/ticket-comments.json")' 'd=today' case_old_tidy
plant "one judge at a time again"     'MAXLIVE=$(swarm_opt review.judge.maxLive 3)' 'MAXLIVE=$(swarm_opt review.judge.maxLive 1)' case_three
plant "a stuck judge is never stopped" '[ "$dry" = 1 ] || reap' 'true' case_reap
plant "the same PR first every time"   'done <<<"$(due | by_last_start)"' 'done <<<"$(due)"' case_fair

case_none_ok()     { reset; answer SHIP; ev_none "$HEAD" "$HEAD"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo green || echo red; }
case_none_absent() { reset; answer SHIP; ev_none "$HEAD";         bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
case_none_oldrec() { reset; answer SHIP; ev_none "$HEAD" "$OLD";  bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
NONE_IF='if [ -n "$head" ] && [ "$(sed -n '"'"'s/^nothing=//p'"'"' <<<"$st")" = "$head" ]; then'
plant "nothing to photograph has no exit"        "$NONE_IF" 'if false; then' case_none_ok
plant "no record is read as nothing to judge"    "$NONE_IF" 'if true; then' case_none_absent
plant "the record's sha is not checked"          '[ "$(sed -n '"'"'s/^nothing=//p'"'"' <<<"$st")" = "$head" ]' 'true' case_none_oldrec

# 13 THE BASELINE ROUTE (the owner, 2026-10-21): pictures and this critic are for new or
# redesigned screens. A PR CI put on the baseline route is never judged and nothing is
# posted; a screen:new / screen:redesign one, or one CI sent to the picture route, still is.
CFGF="$HARNESS_CFG_PATH"; cp "$CFGF" "$FIX/cfg.keep"
jq '.design.baselineRoute = {enabled: true}' "$FIX/cfg.keep" > "$CFGF"
MARKB='<!-- screen-route: baseline -->'
on_baseline() { jq --arg m "$MARKB" '.body = ("<!-- ci-evidence:begin -->\n" + $m)' "$D/pr.json" > "$D/p2" && mv "$D/p2" "$D/pr.json"; }
judged() { [ -s "$D/statuses" ] && [ -f "$D/prompt-seen" ]; }
case_base()    { reset; answer SHIP; rm -f "$D/ticket-labels"; on_baseline; bash "$J" run 7 >/dev/null 2>&1; judged && echo red || echo green; }
case_newtkt()  { reset; answer SHIP; echo '["status:in-review","screen:new"]' > "$D/ticket-labels"; on_baseline; bash "$J" run 7 >/dev/null 2>&1; judged && echo green || echo red; }
case_redopr()  { reset; answer SHIP; rm -f "$D/ticket-labels"; on_baseline; jq '.labels = [{name:"screen:redesign"}]' "$D/pr.json" > "$D/p2" && mv "$D/p2" "$D/pr.json"; bash "$J" run 7 >/dev/null 2>&1; judged && echo green || echo red; }
case_nomark()  { reset; answer SHIP; rm -f "$D/ticket-labels"; bash "$J" run 7 >/dev/null 2>&1; judged && echo green || echo red; }
case_due_base() {
  rm -rf "$FIX/judge"; mkdir -p "$FIX/judge"
  jq -n --arg h "$HEAD" --arg m "$MARKB" '[
    {number:21, headRefOid:$h, isDraft:false, body:("x " + $m), labels:[], statusCheckRollup:[{context:"Design critic", state:"PENDING"}]},
    {number:22, headRefOid:$h, isDraft:false, body:("x " + $m), labels:[{name:"screen:new"}], statusCheckRollup:[{context:"Design critic", state:"PENDING"}]},
    {number:23, headRefOid:$h, isDraft:false, body:"<!-- screen-route: picture -->", labels:[], statusCheckRollup:[{context:"Design critic", state:"PENDING"}]}]' > "$D/list.json"
  [ "$(bash "$J" due | cut -f1 | tr '\n' ' ')" = "22 23 " ] && echo green || echo red; }
[ "$(case_base)" = green ] && [ ! -s "$D/dispatches" ] && ok "baseline route: an existing screen is not judged — no model, no status, no dispatch" || bad "baseline route judged: $(status_line)"
[ "$(case_newtkt)" = green ] && ok "baseline route: a ticket labelled screen:new is judged as before" || bad "screen:new ticket skipped"
[ "$(case_redopr)" = green ] && ok "baseline route: a PR labelled screen:redesign is judged as before" || bad "screen:redesign PR skipped"
[ "$(case_nomark)" = green ] && ok "baseline route: a PR CI did not mark (a route with no approved shot) is judged" || bad "unmarked PR skipped"
[ "$(case_due_base)" = green ] && ok "due: a baseline-route PR is not due; a screen:new one and a picture-route one are" || bad "due: $(bash "$J" due | cut -f1 | tr '\n' ' ')"
plant "the run judges a baseline-route PR"  'if [ "$tl" != '"'"'["(unreadable)"]'"'"' ] && baseline_route' 'if false && baseline_route' case_base
plant "due lists a baseline-route PR"       '| select(($on == "true" and ((.body // "") | contains($m))' '| select((false and ((.body // "") | contains($m))' case_due_base
plant "a picture label is not read"         '| any(. as $l | $pl | index($l)) | not)'"'"' >/dev/null' '| any(false) | not)'"'"' >/dev/null' case_newtkt
plant "the ticket's labels are not read"    '. + {ticketLabels: $tl}' '.' case_newtkt
jq '.design.baselineRoute = {enabled: false}' "$FIX/cfg.keep" > "$CFGF"
[ "$(case_base)" = red ] && ok "baseline route off: the marker alone skips nothing" || bad "the marker skipped a judge with the route off"
cp "$FIX/cfg.keep" "$CFGF"

# U A read that decides the verdict and fails is unknown: no verdict is sent, no model runs.
for what in files comments history; do
  reset; answer SHIP; rm -f "$D/dispatches"; : > "$D/$what.fail"
  out=$(bash "$J" run 7 2>&1); rc=$?
  rm -f "$D/$what.fail"
  [ $rc -ne 0 ] && [ ! -s "$D/statuses" ] && [ ! -s "$D/dispatches" ] && [ ! -f "$D/prompt-seen" ] \
    && printf '%s' "$out" | grep -q 'unknown — ' \
    && ok "an unreadable $what is unknown: no verdict, no model call, and it says so" || bad "unreadable $what: rc=$rc status=$(status_line) out=$(printf '%s' "$out" | tail -3)"
done
# A real empty answer is still an answer: no history and no comments leave the picture undated, and it is judged.
reset; answer SHIP; : > "$D/pic-date"; echo '[]' > "$D/ticket-comments.json"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=success' && ok "empty history and comments read as empty, and the PR is judged" || bad "empty refused: $(status_line)"

# Whatever the plants did, the judge as shipped never posted a raw status in any case above.
grep -v '^$' "$FIX/raw-ever" 2>/dev/null | grep -q . && bad "a raw status POST was sent: $(head -1 "$FIX/raw-ever")" || ok "no case sent a raw status POST"
echo "critic-judge: $pass passed, $fail failed"
suite_end "$fail"
