#!/usr/bin/env bash
# critic-judge.test.sh — the design status is set only by a critic the build did not
# start, judging CI's pinned shots of the head; a builder's verdict trailer counts for
# nothing; a region of the approved picture with no shot fails before any model runs;
# an answer that does not name the shot set it judged is refused.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX" "$HERE/.critic-judge.plant.sh"' EXIT
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
esac
if [ "$1" = api ]; then
  case "$*" in
    *"-X POST"*statuses*) printf '%s\n' "$*" >> "$D/statuses"; exit 0 ;;
    *pulls/7/files*)    cat "$D/files.json"; exit 0 ;;
    *pulls/7/commits*)  cat "$D/commits.json"; exit 0 ;;
    *issues/7/comments*) jq -s '[.[] ]' "$D"/posted-*.json 2>/dev/null || echo '[]'; exit 0 ;;
    *contents/.design/voice-mock.html*) cat "$D/mock.html"; exit 0 ;;
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
  fetch)  for f in "$D"/shots/*.png; do cp "\$f" "\$3/"; n=\$(basename "\$f" .png); printf '%s\t%s\t%s\t%s\n' "\$n" "\$3/\$n.png" light /settings/voices; done ;;
esac
SH
chmod +x "$FIX/ev"
# The critic, stood in for: it answers what $D/answer holds and keeps its prompt.
cat > "$FIX/claude" <<SH
#!/usr/bin/env bash
cat > "$D/prompt-seen"; printf '%s\n' "\$*" > "$D/argv"; cat "$D/answer"
SH
chmod +x "$FIX/claude"
export CRITIC_JUDGE_EVIDENCE="$FIX/ev" CRITIC_JUDGE_CLAUDE="$FIX/claude" CRITIC_JUDGE_DIR="$FIX/judge"
export CRITIC_JUDGE_FINDINGS="$FIX/sf"; printf '#!/usr/bin/env bash\n[ "$1" = critic ] && printf "major\\t#7\\tnine narration lines on the voices page\\n"; exit 0\n' > "$FIX/sf"; chmod +x "$FIX/sf"

reset() {
  rm -f "$D"/comment-* "$D"/posted-* "$D/statuses" "$D/prompt-seen" "$D"/shots/*; rm -rf "$FIX/judge"
  jq -n --arg h "$HEAD" '{headRefOid:$h, isDraft:false, state:"OPEN", headRefName:"tkt-12599/share"}' > "$D/pr.json"
  printf 'head=%s\nsha=%s\nshots=2\nstate=pinned\nreason=pinned\n' "$HEAD" "$EVSHA" > "$D/ev-status"
  echo '[{"filename":"apps/web/voices/page.tsx","status":"modified"},{"filename":".design/voice-mock.html","status":"added"}]' > "$D/files.json"
  printf '[{"sha":"%s","commit":{"message":"chore: design-critic\\n\\nDesign-Critic: SHIP (agent) f9ad4e1a738d"}},{"sha":"%s","commit":{"message":"feat: grid"}}]' "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" > "$D/commits.json"
  cat > "$D/mock.html" <<'HTML'
<html><body>
<section data-evidence-shot="voice-grid-laptop-light" data-evidence-route="/settings/voices" data-evidence-viewport="laptop" data-evidence-theme="light"></section>
<section data-evidence-shot="voice-menu-phone-dark" data-evidence-route="/settings/voices" data-evidence-viewport="phone" data-evidence-theme="dark"></section>
</body></html>
HTML
  printf 'P1' > "$D/shots/voice-grid-laptop-light.png"; printf 'P2' > "$D/shots/voice-menu-phone-dark.png"
}
set_of() { bash "$J" shotset "$D/shots"; }
answer() { # <verdict> [<extra lines>]
  { echo "SHOTS: $(set_of) at $EVSHA"; echo "**PARITY: MATCH** — matches."; echo "**VERDICT: $1** — the grid reads at a glance."
    printf 'For: owners sharing voices.\nHappening: the grid lists who can use each voice.\nNext: change a level.\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$D/answer"
}
status_line() { tail -1 "$D/statuses" 2>/dev/null; }

echo "critic-judge"
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
grep -q 'nine narration lines' "$D/prompt-seen" && grep -q 'voice-mock.html' "$D/prompt-seen" \
  && ok "the critic is handed the open findings for the screen and the approved picture" || bad "prompt lacks findings/picture"

# 3 THE BUG: the picture's phone region was never photographed. Fails without a model call.
reset; answer SHIP; rm "$D/shots/voice-menu-phone-dark.png"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
s=$(status_line)
[ $rc -ne 0 ] && printf '%s' "$s" | grep -q 'state=failure' && [ ! -f "$D/prompt-seen" ] \
  && grep -q 'evidence gap.*voice-menu-phone-dark' "$D/comment-0.md" && ok "a picture region with no pinned shot fails, named, before any model runs" || bad "gap: rc=$rc status=$s"

# 4 SHIP beside a Minor is not a pass (Minors block).
reset; answer SHIP "- Minor · the lock icon sits 2px low → fix: align to the baseline"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && grep -q '^- Minor · the lock icon' "$D/comment-0.md" \
  && ok "a SHIP that lists a Minor fails, and the Minor is a finding" || bad "minor passed: $(status_line)"

# 5 PARITY: DRIFT fails.
reset; answer SHIP; sed -i.b 's/PARITY: MATCH/PARITY: DRIFT/' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && ok "a drift from the approved picture fails" || bad "drift passed"

# 6 An answer that does not name the shot set is refused, and no status is set.
reset; answer SHIP; sed -i.b '1d' "$D/answer"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -s "$D/statuses" ] && ok "a verdict that does not name its shot set is refused, never recorded" || bad "unnamed set: rc=$rc $(status_line)"

# 7 Stale shots fail.
reset; answer SHIP; sed -i.b 's/state=pinned/state=stale/' "$D/ev-status"
bash "$J" run 7 >/dev/null 2>&1
printf '%s' "$(status_line)" | grep -q 'state=failure' && [ ! -f "$D/prompt-seen" ] && ok "shots from before a change to the screens fail" || bad "stale: $(status_line)"

# 8 No pinned shots yet: nothing posted.
reset; answer SHIP; sed -i.b 's/state=pinned/state=pending/' "$D/ev-status"
bash "$J" run 7 >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && [ ! -s "$D/statuses" ] && ok "with no pinned shots it waits and posts nothing" || bad "pending: rc=$rc"

# 9 due: a status a trailer earned (CI's own wording) is owed a judgement; the judge's own is not.
jq -n --arg h "$HEAD" '[
  {number:7, headRefOid:$h, isDraft:false, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"SHIP for UI fingerprint f9ad4e1a738d"}]},
  {number:8, headRefOid:$h, isDraft:false, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Independent critic: SHIP on shots abc"}]},
  {number:9, headRefOid:$h, isDraft:false, body:"no evidence", statusCheckRollup:[]},
  {number:10, headRefOid:$h, isDraft:true, body:"<!-- ci-evidence:begin -->", statusCheckRollup:[]},
  {number:11, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"PENDING", description:"Waiting for CI"}]},
  {number:12, headRefOid:$h, isDraft:false, body:"", statusCheckRollup:[{context:"Design critic", state:"SUCCESS", description:"Nothing owed"}]}]' > "$D/list.json"
export GH_PRS_FILE="$D/list.json"; mkdir -p "$FIX/judge"; printf '12\t%s\n' "$HEAD" > "$FIX/judge/none.tsv"
out=$(bash "$J" due)
[ "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" = "7 11 " ] && ok "due: a status a trailer earned and a pending one are owed; the judge's own, none, drafts and nothing-to-photograph are not" || bad "due: $out"

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
  local r; r=$("$4"); J="$J_ORIG"; rm -f "$P"
  [ "$r" = red ] && ok "planted: $1 → red" || bad "planted: $1 → not caught"
}
case_build()  { reset; answer SHIP; HARNESS_DRIVER_RUN=x bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
case_gap()    { reset; rm "$D/shots/voice-menu-phone-dark.png"; answer SHIP; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
case_minor()  { reset; answer SHIP "- Minor · x"; bash "$J" run 7 >/dev/null 2>&1; status_line | grep -q 'state=success' && echo red || echo green; }
case_noset()  { reset; answer SHIP; sed -i.b '1d' "$D/answer"; bash "$J" run 7 >/dev/null 2>&1; [ -s "$D/statuses" ] && echo red || echo green; }
plant "a build run may judge"            '[ -z "${HARNESS_DRIVER_RUN:-}" ] ||' 'true ||' case_build
plant "the picture's regions are not checked" '[ -n "$miss" ]; then' '[ -n "" ]; then' case_gap
plant "a Minor does not block"          '[ -z "$blocks" ] && pass=1' 'pass=1' case_minor
plant "an answer need not name its set" 'if ! grep -qF "SHOTS: $set" "$answer"; then' 'if false; then' case_noset

echo "critic-judge: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
