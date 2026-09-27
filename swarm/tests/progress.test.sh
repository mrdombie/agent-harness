#!/usr/bin/env bash
# progress.test.sh — how far along an agent is, and how far along its plan is.
#
# The one thing to pin: every step is read from a FACT, and a fact that cannot be
# read says so. The failure this suite exists for is the comfortable one — a bar
# that fills in because the code assumed, so a card reports progress nobody made.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
swarm_fixture
trap 'rm -rf "$FIX"' EXIT
M="$HERE/../live-view/progress.mjs"
command -v node >/dev/null 2>&1 || { echo "SKIP progress: node is not on PATH"; exit 0; }

# ask <js> — run an expression against the module and print it
ask() { node --input-type=module -e "
  import * as P from '$M'
  const out = (() => { $1 })()
  console.log(typeof out === 'string' ? out : JSON.stringify(out))"; }
states() { ask "return P.progressOf($1, ${2:-null}).steps.map(s => s.state).join(' ')"; }

echo "--- with nothing readable, every step says so ---"
want "all unknown" "unknown unknown unknown unknown unknown unknown unknown" "$(states null)"
want "and all seven are named" \
  "Set up,Plan,Build,Check,Review,PR,Merged" \
  "$(ask "return P.progressOf(null, null).unreadable.join(',')")"
want "the walk is still at step 1" "1" "$(ask "return String(P.progressOf(null,null).step)")"

echo "--- each step comes from its own fact ---"
JUST_CLAIMED='{claim:true,commits:0,pushed:false,trailers:[],stampsReviews:true,prRead:true,pr:null}'
want "claimed, nothing else done" "done now todo todo todo todo todo" "$(states "$JUST_CLAIMED")"
ONE='{claim:true,commits:1,pushed:false,trailers:[],stampsReviews:true,prRead:true,pr:null}'
want "one commit is a plan, not a build" "done done now todo todo todo todo" "$(states "$ONE")"
PUSHED='{claim:true,commits:6,pushed:true,trailers:[],stampsReviews:true,prRead:true,pr:null}'
want "pushed means the gates ran" "done done done done now todo todo" "$(states "$PUSHED")"
REVIEWED='{claim:true,commits:6,pushed:true,trailers:["UI-Gate"],stampsReviews:true,prRead:true,pr:null}'
want "a trailer is the review" "done done done done done now todo" "$(states "$REVIEWED")"
GREEN='{claim:true,commits:6,pushed:true,trailers:["UI-Gate"],stampsReviews:true,prRead:true,pr:{number:9,state:"OPEN",fail:0,pending:0}}'
want "a green PR" "done done done done done done now" "$(states "$GREEN")"
MERGED='{claim:true,commits:6,pushed:true,trailers:["UI-Gate"],stampsReviews:true,prRead:true,pr:{number:9,state:"MERGED",fail:0,pending:0}}'
want "merged is the end" "done done done done done done done" "$(states "$MERGED")"
want "and it reads as step 7 of 7" "7" "$(ask "return String(P.progressOf($MERGED,null).step)")"

echo "--- a failing check is red, and it is the step the card stops on ---"
RED='{claim:true,commits:6,pushed:true,trailers:["UI-Gate"],stampsReviews:true,prRead:true,pr:{number:9,state:"OPEN",fail:2,pending:0}}'
want "the PR step is bad" "done done done done done bad todo" "$(states "$RED")"
want "the card stops at 6" "6" "$(ask "return String(P.progressOf($RED,null).step)")"
want "and it carries how many" "2" "$(ask "return String(P.progressOf($RED,null).checksFail)")"

echo "--- the three pairs that must never draw the same ---"
BLIND='{claim:true,commits:6,pushed:true,trailers:[],stampsReviews:true,prRead:false,pr:null}'
want "could not ask the forge is not no PR" "done done done done now unknown unknown" "$(states "$BLIND")"
NOSTAMP='{claim:true,commits:6,pushed:true,trailers:[],stampsReviews:false,prRead:true,pr:null}'
want "a repo that stamps none is unreadable, not unreviewed" \
  "done done done done unknown now todo" "$(states "$NOSTAMP")"
SWEPT='{claim:true,commits:null,pushed:true,trailers:[],stampsReviews:true,prRead:true,pr:null}'
want "a swept tree is not nothing committed" "done unknown unknown done now todo todo" "$(states "$SWEPT")"

echo "--- the step-runner's own record wins over the inference ---"
DRIVER='{done:["start","plan","build","self-check"],step:"review",counters:{review_rounds:"1"}}'
want "its four finished steps" "done done done done now todo todo" "$(states "$JUST_CLAIMED" "$DRIVER")"
want "and the round it is on" "1" "$(ask "return String(P.progressOf($JUST_CLAIMED,$DRIVER).reviewRounds)")"

echo "--- the plan bar: weighted, epics out, the unsized counted ---"
ISSUES='[{state:"CLOSED",labels:[{name:"effort:M"}]},{state:"OPEN",labels:[{name:"effort:L"}]},{state:"OPEN",labels:[{name:"epic"},{name:"effort:XL"}]},{state:"OPEN",labels:[]}]'
want "three jobs, the epic excluded" "3" "$(ask "return String(P.weigh($ISSUES).jobs)")"
want "one done" "1" "$(ask "return String(P.weigh($ISSUES).done)")"
want "weight 3 of 11, the XL epic not counted" "3/11" \
  "$(ask "const w=P.weigh($ISSUES); return w.weightDone+'/'+w.weightTotal")"
want "the unsized one is counted, not zeroed" "1" "$(ask "return String(P.weigh($ISSUES).unestimated)")"
LIVE='[{project:"one-desk"},{project:"one-desk"},{project:"harness-kit"}]'
PLANS='{"one-desk":{jobs:25,done:3,weightDone:12,weightTotal:75,unestimated:4}}'
want "the percentage is by weight" "16" "$(ask "return String(P.plansOf($LIVE,$PLANS)[1].pct)")"
want "and the jobs beside it" "3 of 25" \
  "$(ask "const p=P.plansOf($LIVE,$PLANS)[1]; return p.done+' of '+p.jobs")"
want "two are being worked on" "2" "$(ask "return String(P.plansOf($LIVE,$PLANS)[1].working)")"
want "a plan that could not be read keeps its row" "harness-kit" \
  "$(ask "return P.plansOf($LIVE,$PLANS)[0].id")"
want "with no percentage rather than nought" "null" \
  "$(ask "return String(P.plansOf($LIVE,$PLANS)[0].pct)")"

echo "--- the plain title ---"
want "notes are cut back to the clause that names it" "The driver" \
  "$(ask "return P.shortTitle('Harness phase 1 · the driver: build-ticket runs every step in order, resumable, tested')")"
want "a conventional-commit prefix goes" "The strip drops its last item" \
  "$(ask "return P.shortTitle('fix(desk): the strip drops its last item')")"
want "the operator's own word wins" "The step-runner" \
  "$(ask "return P.shortTitle('Harness phase 1 · the driver: anything at all', 'The step-runner')")"

echo "--- the live view carries it, and so does the reporter ---"
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"run_id":"claim-601-a","ticket":"601","child_pid":%s,"started_at":"%s","budget_usd":150,"log":"%s"}\n' \
  "$$" "$NOW_ISO" "$STATE/logs/claim-601.log" > "$STATE/runs/claim-601-a.json"
: > "$STATE/logs/claim-601.log"
cat > "$FIX/titles.json" <<'JSON'
{"601":{"title":"Harness phase 1 · the driver: build-ticket runs every step","project":"one-desk"}}
JSON
printf '{"601":"The step-runner"}' > "$FIX/plain-titles.json"
printf '{"tickets":{"601":%s},"plans":{"one-desk":{"jobs":25,"done":3,"weightDone":12,"weightTotal":75,"unestimated":4}}}' \
  '{"claim":true,"commits":6,"pushed":true,"trailers":["UI-Gate"],"stampsReviews":true,"prRead":true,"pr":{"number":"9","state":"OPEN","fail":2,"pending":0}}' \
  > "$STATE/swarm/progress.json"
snap() {
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" \
  SWARM_PLAIN_TITLES="$FIX/plain-titles.json" SWARM_PROGRESS_CACHE="$STATE/swarm/progress.json" \
  SWARM_PROGRESS_MS=999999 SWARM_GH="$BIN/gh" \
  node --input-type=module -e "
    import { snapshot } from '$HERE/../live-view/server.mjs'
    console.log(JSON.stringify(snapshot()))"
}
s=$(snap)
want "the row carries its bar" "bad" \
  "$(printf '%s' "$s" | jq -r '.live[0].progress.steps[5].state')"
want "and the step it stops on" "6" "$(printf '%s' "$s" | jq -r '.live[0].progress.step')"
want "and the plain title" "The step-runner" "$(printf '%s' "$s" | jq -r '.live[0].short')"
want "the snapshot carries the plan" "16" "$(printf '%s' "$s" | jq -r '.plans[0].pct')"
want "named in words" "One Desk" "$(printf '%s' "$s" | jq -r '.plans[0].name')"

printf '%s' "$s" > "$FIX/live.json"
r=$(SWARM_DIR="$STATE/swarm" SWARM_LOGS="$STATE/logs" RUNS_DIR="$STATE/runs" \
    HARNESS_CFG_PATH="$REPO/.claude/harness.json" HARNESS_STATE_DIR="$STATE" HARNESS_MAIN_REPO="$REPO" \
    SWARM_LIVE_URL=http://x SWARM_CURL="$BIN/curl" SWARM_GH="$BIN/gh" \
    bash "$HERE/../report.sh" --json)
want "the reporter passes the bar through" "bad" \
  "$(printf '%s' "$r" | jq -r '.live[0].progress.steps[5].state')"
want "and the plan" "16" "$(printf '%s' "$r" | jq -r '.plans[0].pct')"
want "and the plain title" "The step-runner" "$(printf '%s' "$r" | jq -r '.live[0].short')"
