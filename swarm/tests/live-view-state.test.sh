#!/usr/bin/env bash
# live-view-state.test.sh — a finished row says where its ticket REALLY stands, read
# from GitHub; a live row names its real step; another machine's run is coloured
# from its heartbeat.
#
# Measured 2026-10-21 on /api/agents: six rows read outcome "success" and the header
# "1 shipped · 15 in review", and none of the six had merged. "success" meant only
# that the builder handed off a pull request. Every row had pr "" and at null, live
# rows read every step "unknown", and the Yomato rows were grey whether busy or stuck.
# Run: bash "$0"     LIVE_VIEW_DIR=<dir> runs it against another copy of the page.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../../scripts"
. "$HERE/fixture.sh"
swarm_fixture
sleep 30 & DEAD=$!; kill "$DEAD" 2>/dev/null; wait "$DEAD" 2>/dev/null
on_exit_keep_status 'rm -rf "$FIX"'
command -v node >/dev/null 2>&1 || { suite_skip "SKIP live-view-state: node is not on PATH"; }
LV="${LIVE_VIEW_DIR:-$HERE/../live-view}"

NOW_S=$(date +%s)
iso() { node -e 'console.log(new Date(Number(process.argv[1]) * 1000).toISOString().replace(/\.\d{3}Z$/, "Z"))' "$1"; }
hhmm() { node -e 'const d = new Date(Number(process.argv[1]) * 1000); console.log(String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0"))' "$1"; }
NOW_ISO=$(iso "$NOW_S")
MERGED_S=$(( NOW_S - 60 )); MERGED_ISO=$(iso "$MERGED_S"); MERGED_HM=$(hhmm "$MERGED_S")
SINCE=$(node -e 'const d = new Date(); d.setHours(0, 0, 0, 0); console.log(d.toISOString().replace(/\.\d{3}Z$/, "Z"))')

snap() { # [server dir]
  local mjs="${1:-$LV}/server.mjs"
  SWARM_RUNS_DIR="$STATE/runs" SWARM_REPO=acme/widgets SWARM_TITLES="$FIX/titles.json" SWARM_GH="$BIN/gh" \
  SWARM_PROGRESS_SYNC=1 SWARM_HOLD_SCRIPT="$HERE/../hold-status.sh" SWARM_HOST=laptop SWARM_OWNER_NAME=Dom BRANCH_PREFIX=tkt- SWARM_SERVER_MJS="$mjs" \
  node --input-type=module -e "
    import { pathToFileURL } from 'node:url'
    const { snapshot } = await import(pathToFileURL(process.env.SWARM_SERVER_MJS).href)
    console.log(JSON.stringify(snapshot()))"
}
page_render() { # <page dir> <snapshot> — every element the page wrote, as id=html lines
  printf '%s' "$2" > "$FIX/snap.json"
  PAGE="$1/index.html" SNAP="$FIX/snap.json" node -e '
    const fs = require("fs"), vm = require("vm")
    const html = fs.readFileSync(process.env.PAGE, "utf8")
    const js = html.slice(html.indexOf("<script>") + 8, html.lastIndexOf("</script>"))
    const els = {}
    const el = (id) => (els[id] ||= { textContent: "", innerHTML: "", hidden: false })
    const ctx = { document: { getElementById: el }, fetch: () => new Promise(() => {}), setInterval: () => 0, console }
    vm.createContext(ctx); vm.runInContext(js + "\n;globalThis.__render = render", ctx)
    ctx.__render(JSON.parse(fs.readFileSync(process.env.SNAP, "utf8")))
    for (const [k, v] of Object.entries(els)) console.log(k + "=" + (v.innerHTML || v.textContent).replace(/\s+/g, " "))' 2>&1
}
ended_run() { # <ticket> <exit> [result line]
  local t=$1 log="$STATE/logs/claim-$1-a.log"
  printf '{"run_id":"claim-%s-a","ticket":"%s","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
    "$t" "$t" "$DEAD" "$NOW_ISO" "$log" > "$STATE/runs/claim-$t-a.json"
  printf '{"exit_code":%s,"ended_at":"%s"}\n' "$2" "$NOW_ISO" > "$STATE/runs/claim-$t-a.ended"
  printf '%s\n' "${3:-}" > "$log"
}
park_line() { printf '⏸ #%s parked (%s): %s\n' "$1" "$2" "$3" >> "$STATE/logs/claim-$1-a.log"; }
row_of() { printf '%s' "$1" | jq -r --arg t "$2" ".done[] | select(.ticket==\$t) | $3"; }

echo "--- the fixture: handed-off pull requests in every state, a merge, two parks ---"
mkdir -p "$STATE/coordinator/snapshot"
ended_run 2101 0 '{"type":"result","subtype":"success","result":"Opened https://github.com/acme/widgets/pull/3101"}'
ended_run 2102 0 '{"type":"result","subtype":"success","result":"PR #3102 is open"}'
for t in 2103 2104 2105 2106 2109 2110 2111 2112 2114 2115; do ended_run "$t" 0 '{"type":"result","subtype":"success","result":"handed off"}'; done
ended_run 2107 20; park_line 2107 pm "build asked a question rather than guessing — which repo does this belong in?"
ended_run 2108 20; park_line 2108 person "repair asked a question rather than guessing — ship the changes made since the sign-off?"
ok_run() { printf '{"name":"%s","status":"COMPLETED","conclusion":"SUCCESS"}' "$1"; }
at_run() { printf '{"name":"%s","status":"COMPLETED","conclusion":"%s","completedAt":"%s"}' "$1" "$2" "$3"; }
busy_run() { printf '{"name":"%s","status":"IN_PROGRESS","conclusion":null}' "$1"; }
red_run() { printf '{"name":"%s","status":"COMPLETED","conclusion":"FAILURE"}' "$1"; }
pr() { # <number> <ticket> <mergeable> <labels json> <checks...>
  local n=$1 t=$2 m=$3 l=$4; shift 4
  local c; c=$(IFS=,; printf '%s' "$*")
  printf '{"number":%s,"headRefName":"tkt-%s/work","headRefOid":"h%s","mergeable":"%s","labels":%s,"closingIssuesReferences":[],"statusCheckRollup":[%s]}' "$n" "$t" "$n" "$m" "$l" "$c"
}
{ echo '['
  pr 3101 2101 MERGEABLE '[]' "$(ok_run 'Code gates')" "$(busy_run 'Unit tests')" "$(busy_run 'Build web')"; echo ','
  pr 3102 2102 MERGEABLE '[]' "$(red_run 'Code gates')" "$(ok_run 'Build web')"; echo ','
  pr 3103 2103 MERGEABLE '["needs:human-approval"]' "$(red_run 'approval-gate')" "$(ok_run 'Code gates')"; echo ','
  pr 3104 2104 CONFLICTING '[]' "$(ok_run 'Code gates')"; echo ','
  pr 3105 2105 MERGEABLE '[]' "$(busy_run 'Design critic')" "$(ok_run 'Code gates')"; echo ','
  pr 3110 2110 MERGEABLE '[]' "$(at_run 'Lesson' SKIPPED 2026-10-21T10:00:00Z)" "$(at_run 'Lesson' FAILURE 2026-10-21T13:00:00Z)" \
    "$(at_run 'Code gates' FAILURE 2026-10-21T10:00:00Z)" "$(at_run 'Code gates' SUCCESS 2026-10-21T13:00:00Z)"; echo ','
  pr 3111 2111 CONFLICTING '[]' "$(red_run 'Code gates')"; echo ','
  pr 3112 2112 MERGEABLE '[]' "$(red_run 'Unit tests')" "$(busy_run 'Build web')" "$(busy_run 'Lint')"; echo ','
  pr 3114 2114 MERGEABLE '["needs:human-approval"]' "$(red_run 'Widths and contrast on changed routes')" "$(red_run 'approval-gate')" "$(ok_run 'Code gates')"; echo ','
  pr 3115 2115 MERGEABLE '[]' "$(red_run 'Lesson / Every fix ships a lesson')" "$(busy_run 'Code gates')" "$(busy_run 'Did develop move this PR')"
  echo ']'; } > "$STATE/swarm/prs.json"
jq -e . "$STATE/swarm/prs.json" >/dev/null || bad "the open-PR fixture is not JSON"
cat > "$STATE/coordinator/snapshot/issues.json" <<JSON
{"2107":{"number":2107,"state":"OPEN","labels":["status:parked","status:pm-decision"]},
 "2108":{"number":2108,"state":"OPEN","labels":["status:needs-human"]}}
JSON
cat > "$FIX/gh/api-repos_acme_widgets_pulls_state_closed_sort_updated_direction_desc_per_page_100.json" <<JSON
[{"number":3106,"title":"fix(desk): the strip","merged_at":"$MERGED_ISO","closed_at":"$MERGED_ISO","head":{"ref":"tkt-2106/strip"},"body":""},
 {"number":3109,"title":"feat: other","merged_at":"$MERGED_ISO","closed_at":"$MERGED_ISO","head":{"ref":"someone/else"},"body":"Closes #2109"},
 {"number":3001,"title":"old, closed unmerged","merged_at":null,"closed_at":"$MERGED_ISO","head":{"ref":"tkt-2101/old"},"body":""}]
JSON
# The open heads, fresh: 3104's copy is of its current head, 3111's of an older one.
printf '[{"number":3104,"head":{"sha":"h3104"}},{"number":3111,"head":{"sha":"a-newer-push"}}]\n' \
  > "$FIX/gh/api-repos_acme_widgets_pulls_state_open_sort_updated_direction_desc_per_page_100.json"
ended_run 2113 20; park_line 2113 person "repair asked a question rather than guessing — is the pricing change cleared commercially?"
# The trunk's ruleset: what blocks a merge. Widths and the lesson are report-only.
cat > "$FIX/gh/api-repos_acme_widgets_rules_branches_develop.json" <<'JSON'
[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Code gates"},{"context":"Unit tests"},
 {"context":"Build web"},{"context":"Lint"},{"context":"approval-gate"}]}},{"type":"pull_request","parameters":{}}]
JSON
cat > "$FIX/gh/api-search_issues.json" <<JSON
{"total_count":2,"items":[{"number":3106,"title":"fix(desk): the strip","closed_at":"$MERGED_ISO","pull_request":{"merged_at":"$MERGED_ISO"}},
 {"number":3109,"title":"feat: other","closed_at":"$MERGED_ISO","pull_request":{"merged_at":"$MERGED_ISO"}}]}
JSON

s=$(snap)
echo "--- a handed-off pull request still open is NOT success, NOT shipped: it shows its real state ---"
want "2 of its checks still running"          "Waiting for checks (2 running)" "$(row_of "$s" 2101 .now.text)"
want "a red check, by name"                   "A check failed: Code gates" "$(row_of "$s" 2102 .now.text)"
want "the approval check red under a hold is the sign-off" "Waiting for sign-off" "$(row_of "$s" 2103 .now.text)"
want "a clash"                                "Clashes with newer code" "$(row_of "$s" 2104 .now.text)"
want "the design critic still running"        "Waiting for design review" "$(row_of "$s" 2105 .now.text)"
want "a clash read on an older head is not believed" "Waiting for checks on the newest push" "$(row_of "$s" 2111 .now.text)"
red=$(cd "$LV" && SWARM_RUNS_DIR="$STATE/runs" BRANCH_PREFIX=tkt- node --input-type=module -e '
  import { prRowsByTicket } from "./server.mjs"
  const r = prRowsByTicket(process.argv[1], { "3104": "h3104", "3111": "a-newer-push" })
  console.log(r["2104"].red + " " + r["2111"].red)' "$STATE/swarm/prs.json")
want "the board's red believes a clash only on the current head too" "true false" "$red"
want "a failure outranks running, and says what still runs" "A check failed: Unit tests (2 still running)" "$(row_of "$s" 2112 .now.text)"
want "each check by its newest run: a failure after a skip fails, a pass after a failure passes" "lesson" "$(row_of "$s" 2110 '.now.notes[0] // .now.text')"
want "a report-only failure is not the state"  "Checks passed — waiting to merge" "$(row_of "$s" 2110 .now.text)"
want "only a REQUIRED check's failure is"      "A check failed: Code gates" "$(row_of "$s" 2102 .now.text)"
want "report-only reds beside a hold: the sign-off, with the note" "Waiting for sign-off|widths" "$(row_of "$s" 2114 '"\(.now.text)|\(.now.notes | join(","))"')"
want "a report-only red while a required check runs: waiting for that one" "Waiting for checks (1 running)|lesson" "$(row_of "$s" 2115 '"\(.now.text)|\(.now.notes | join(","))"')"
want "the ruleset was read once"              "1" "$(grep -c 'rules/branches/develop' "$GH_LOG")"
sn=$(SWARM_NONBLOCKING_CHECKS='["Code gates"]' snap)
want "a check the project names report-only never blocks" "Checks passed — waiting to merge|code gates" "$(row_of "$sn" 2102 '"\(.now.text)|\(.now.notes | join(","))"')"
want_not_in "no row's state says success or shipped" '(success|shipped)' "$(printf '%s' "$s" | jq -r '.done[] | "\(.now.text) \(.now.state) \(.lastRun)"' | tr 'A-Z' 'a-z')"
want_not_in "nor does the header"             '(success|shipped)' "$(printf '%s' "$s" | jq -r '.doneSummary' | tr 'A-Z' 'a-z')"
want_not_in "no row carries the CLI's word"   'success' "$(printf '%s' "$s" | jq -c '.done[]' | tr 'A-Z' 'a-z')"
want "each row has its PR"                    "3101" "$(row_of "$s" 2101 .pr)"
want "and its link"                           "https://github.com/acme/widgets/pull/3101" "$(row_of "$s" 2101 .prUrl)"
want "and when it finished"                   "$NOW_ISO" "$(row_of "$s" 2101 .at)"
want "no row without a finished-at time"      "0" "$(printf '%s' "$s" | jq '[.done[] | select(.at == null or .finishedAt == null)] | length')"

rr=$(cd "$LV" && node --input-type=module -e '
  import { rollupOf } from "./progress.mjs"
  const at = (name, conclusion, completedAt) => ({ name, status: "COMPLETED", conclusion, completedAt })
  const r = rollupOf({ number: 1, statusCheckRollup: [at("Lesson", "SKIPPED", "2026-10-21T10:00:00Z"), at("Lesson", "FAILURE", "2026-10-21T13:00:00Z"),
    at("Code gates", "FAILURE", "2026-10-21T10:00:00Z"), at("Code gates", "SUCCESS", "2026-10-21T13:00:00Z")] })
  console.log(r.total + " " + r.fail + " " + r.pending)')
want "the live card's PR cell reads each check by its newest run too" "2 1 0" "$rr"
printf '{"contexts":["Code gates"]}\n' > "$FIX/req.json"
rq=$(cd "$LV" && SWARM_REQUIRED_CHECKS_FILE="$FIX/req.json" node --input-type=module -e '
  import { rollupOf } from "./progress.mjs"
  const red = (name) => ({ name, status: "COMPLETED", conclusion: "FAILURE", completedAt: "2026-10-21T13:00:00Z" })
  console.log(rollupOf({ number: 1, statusCheckRollup: [red("Lesson"), red("Code gates")] }).fail)')
want "and turns red only for a required check" "1" "$rq"
red=$(cd "$LV" && SWARM_RUNS_DIR="$STATE/runs" node --input-type=module -e '
  import { prRed } from "./server.mjs"
  const at = (name, conclusion, completedAt) => ({ name, status: "COMPLETED", conclusion, completedAt })
  console.log(prRed({ statusCheckRollup: [at("Code gates", "FAILURE", "2026-10-21T10:00:00Z"), at("Code gates", "SUCCESS", "2026-10-21T13:00:00Z")] })
    + " " + prRed({ statusCheckRollup: [at("Unit tests", "SKIPPED", "2026-10-21T10:00:00Z"), at("Unit tests", "FAILURE", "2026-10-21T13:00:00Z")] }))')
want "and so does the board's red: a pass after a failure is not red, a failure after a skip is" "false true" "$red"

echo "--- a merged pull request reads Merged <time>, by branch or by its closing word ---"
want "by branch"                              "Merged $MERGED_HM" "$(row_of "$s" 2106 .now.text)"
want "by 'Closes #'"                          "Merged $MERGED_HM" "$(row_of "$s" 2109 .now.text)"
want "with its PR"                            "3106" "$(row_of "$s" 2106 .pr)"
want "merged today: the count"                "2" "$(printf '%s' "$s" | jq '.mergedToday.total')"
want "and each pull request"                  "3106 3109" "$(printf '%s' "$s" | jq -r '[.mergedToday.items[].number] | sort | join(" ")')"
want "counted from local midnight"            "$SINCE" "$(printf '%s' "$s" | jq -r '.mergedToday.since')"

echo "--- a parked ticket: Stopped: <reason> — next: <who> ---"
want "a PM question"                          "Stopped: build asked a question — next: PM" "$(row_of "$s" 2107 .now.text)"
want "with what it needs"                     "which repo does this belong in?" "$(row_of "$s" 2107 .now.detail)"
want "a question for the owner names the owner" "Stopped: repair asked a question — next: Dom" "$(row_of "$s" 2108 .now.text)"
sl=$(SWARM_UNTIL_LAUNCH_PM=true snap)
want "until launch the PM takes it"            "Stopped: repair asked a question — next: PM" "$(row_of "$sl" 2108 .now.text)"
want "but a commercial question still goes to the owner" "Stopped: repair asked a question — next: Dom" "$(row_of "$sl" 2113 .now.text)"

echo "--- the page draws those states, the links and Merged today ---"
r=$(page_render "$LV" "$s")
want_in "the open PR's state on the row"      '^done=.*Waiting for checks \(2 running\)</span><div class="note"><a href="https://github.com/acme/widgets/pull/3101"' "$r"
want_in "the merge and its time"              "^done=.*Merged $MERGED_HM</span>" "$r"
want_in "report-only reds are a muted note on the row" '^done=.*Waiting for sign-off</span>.*<div class="note muted">notes: widths</div>' "$r"
want_not_in "and never the pill"               '^done=.*pill [a-z]+">A check failed: (Widths|Lesson)' "$r"
want_in "the stop and who moves it"           '^done=.*Stopped: build asked a question — next: PM</span>' "$r"
want_in "a finished-at time on each row"      '^done=.*finished ' "$r"
want_not_in "no success or shipped anywhere on the rows" '^done=.*([Ss]uccess|[Ss]hipped)' "$r"
want_not_in "nor in the header"               '^donehead=.*([Ss]uccess|[Ss]hipped)' "$r"
want_in "Merged today, counted"               '^mergedhead=Merged today · 2$' "$r"
want_in "and linked"                          '^merged=.*href="https://github.com/acme/widgets/pull/3106".*merged ' "$r"

echo "--- one batched read of PR states, kept, never per row ---"
want "the closed list was read once"          "1" "$(grep -c 'pulls?state=closed' "$GH_LOG")"
want "today's merges once"                    "1" "$(grep -c '^api search/issues' "$GH_LOG")"
want "and no per-row PR read"                 "0" "$(grep -cE '^pr (view|list)' "$GH_LOG")"
snap >/dev/null
want "a second look inside the minute asks again for neither" "2" "$(grep -cE 'pulls\?state=closed|^api search/issues' "$GH_LOG")"

echo "--- a live claim's step is the step shown, not unknown ---"
rm -f "$STATE"/runs/claim-* "$STATE"/logs/claim-*
printf '{"run_id":"claim-2201-a","ticket":"2201","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
  "$$" "$(iso $(( NOW_S - 3600 )))" "$STATE/logs/claim-2201-a.log" > "$STATE/runs/claim-2201-a.json"
echo 'Reading the diff' > "$STATE/logs/claim-2201-a.log"
cat > "$STATE/swarm/claims.json" <<JSON
{"at":"$NOW_ISO","claims":[{"issue":"2201","host":"laptop","step":"review"},
 {"issue":"2301","host":"studio-mac","step":"build"},{"issue":"2302","host":"studio-mac","step":"review"},
 {"issue":"2303","host":"old-vm","step":"fix"}]}
JSON
STALE_S=$(( NOW_S - 2400 ))
cat > "$STATE/coordinator/fleet.json" <<JSON
{"at":$NOW_S,"hosts":[{"host":"laptop","tick":$NOW_S,"builds":1},
 {"host":"studio-mac","tick":$(( NOW_S - 60 )),"builds":2,"runs":[{"t":"2301","at":$(( NOW_S - 30 )),"say":"build: task 3 of 5"},{"t":"2302","at":$(( NOW_S - 1200 )),"say":"review: round 2"}]},
 {"host":"old-vm","tick":$STALE_S,"builds":1,"runs":[{"t":"2303","at":$STALE_S,"say":"fix: lint"}]}]}
JSON
s=$(snap)
want "the step comes from the claim"          "claim review" "$(printf '%s' "$s" | jq -r '.live[] | select(.ticket=="2201") | "\(.stepFrom) \(.claimStep)"')"
r=$(page_render "$LV" "$s")
want_in "and the page names it"               '^building=.*This machine \(laptop\) · <b>Being reviewed</b>' "$r"
want_not_in "not Starting, not unknown"       '^building=.*(Starting|unknown)' "$r"

echo "--- another machine's run is coloured from its heartbeat; grey only when the machine stops reporting ---"
want "fresh activity, quiet about 30s"        "true" "$(printf '%s' "$s" | jq '.elsewhere[] | select(.ticket=="2301") | .quietSec >= 30 and .quietSec < 90')"
want_in "a busy remote run is green, with its last line" '<div class="row build remote"><span class="dot ok"[^>]*></span><div class="main"> <div class="title">Ticket 2301.*<div class="line">build: task 3 of 5</div>' "$r"
want_in "one quiet 20 min is stuck"           '<span class="dot stuck"[^>]*></span><div class="main"> <div class="title">Ticket 2302' "$r"
# Past midnight the clock carries its day ("Fri 23 Oct 23:54", clockOf), so the day is optional here.
want_in "a stale heartbeat is the grey ring, saying since when" "<span class=\"dot away\"[^>]*></span><div class=\"main\"> <div class=\"title\">Ticket 2303.*old-vm not reporting since ([A-Z][a-z]{2} [0-9]{1,2} [A-Z][a-z]{2} )?$(hhmm "$STALE_S")" "$r"

printf '{"at":%s,"hosts":[{"host":"studio-mac","tick":%s,"builds":2}]}\n' "$NOW_S" "$(( NOW_S - 60 ))" > "$STATE/coordinator/fleet.json"
r=$(page_render "$LV" "$(snap)")
want_in "a fresh heartbeat with no runs on it is not a stuck run" '<span class="dot away"[^>]*></span><div class="main"> <div class="title">Ticket 2301.*studio-mac reports no activity for this run yet' "$r"
want_not_in "and nothing reads stuck"         'dot stuck' "$r"

echo "--- the heartbeat carries each live run's last activity and line ---"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"description":"Run the <gates> -->"}}]}}\n' > "$FIX/beat-a.log"
printf '   build: x\n\033[32m   self-check: changed 2 ok\033[0m\n\n' > "$FIX/beat-b.log"
hb=$( export SWARM_NOW="$NOW_S"; . "$SCRIPTS/coordinator-env.sh" >/dev/null 2>&1; . "$SCRIPTS/coordinator-sheet.sh" >/dev/null 2>&1
      runs=$( { coord_run_beat 41 100 "$FIX/beat-a.log"; coord_run_beat 42 200 "$FIX/beat-b.log"; } | jq -sc . )
      coord_heartbeat 2 100 6 "$runs" )
want "both runs ride on the heartbeat"        "41 100 42 200" "$(jq -r '[.runs[] | "\(.t) \(.at)"] | join(" ")' <<<"$hb")"
want "a stream-json log's last action"        "Run the gates --" "$(jq -r '.runs[0].say' <<<"$hb")"
want "a plain log's last line, colour codes gone" "self-check: changed 2 ok" "$(jq -r '.runs[1].say' <<<"$hb")"

echo "--- planted: each rule removed is seen ---"
P="$FIX/lv-plant"; mkdir -p "$P"
plant() { # <file> <exact text> [replacement]
  cp "$LV"/*.mjs "$LV/index.html" "$P/"
  python3 - "$P/$1" "$2" "${3:-}" <<'PY' || bad "plant did not land: $2"
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]; s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
}
rm -f "$STATE/swarm/claims.json" "$STATE/coordinator/fleet.json" "$STATE"/runs/claim-* "$STATE"/logs/claim-*
ended_run 2101 0 '{"type":"result","subtype":"success","result":"Opened https://github.com/acme/widgets/pull/3101"}'
ended_run 2106 0; ended_run 2107 20; park_line 2107 pm "build asked a question rather than guessing — which repo?"
plant server.mjs "    if (!o || at >= o.at) by.set(name, { busy, failed, good, at })" "    by.set(name, { busy: (o && o.busy) || busy, failed: (o && o.failed) || failed, good: (o && o.good) || good, at })"
got=$(row_of "$(snap "$P")" 2110 .now.text)
[ "$got" != "A check failed: Lesson" ] && ok "planted: every run of a check counted alike → 2110 reads '$got' → red" || bad "planted: the newest-run rule dropped and the test cannot see it"
plant server.mjs "    const row = { number: p.number, red: ['clash', 'failed'].includes(status.state)," "    const row = { number: p.number, red: prRed(p),"
got=$(cd "$P" && SWARM_RUNS_DIR="$STATE/runs" BRANCH_PREFIX=tkt- node --input-type=module -e '
  import { prRowsByTicket } from "./server.mjs"
  console.log(prRowsByTicket(process.argv[1], { "3111": "a-newer-push" })["2111"].red)' "$STATE/swarm/prs.json")
[ "$got" = "true" ] && ok "planted: the board's red from the copy alone → a stale clash is red → red" || bad "planted: the board's red from the copy alone and the test cannot see it ($got)"
plant server.mjs "  const blocks = (n) => !rules.nonBlocking.has(n) && (!rules.required || rules.required.has(n))" "  const blocks = () => true"
got=$(row_of "$(snap "$P")" 2114 .now.text)
[ "$got" != "Waiting for sign-off" ] && ok "planted: every red blocks again → 2114 reads '$got' → red" || bad "planted: the required-only rule dropped and the test cannot see it"
plant index.html "  const notes = (n.notes || []).length ? \`<div class=\"note muted\">notes: \${esc(n.notes.join(', '))}</div>\` : ''" "  const notes = ''"
[ "$(page_render "$P" "$(snap)" | grep '^done=' | grep -c 'notes: widths')" = 0 ] && ok "planted: the page drops the notes → red" || bad "planted: the page drops the notes and the test cannot see it"
plant server.mjs "heads && heads[String(p.number)] && p.headRefOid && heads[String(p.number)] !== p.headRefOid" "false"
got=$(row_of "$(snap "$P")" 2111 .now.text)
[ "$got" != "Waiting for checks on the newest push" ] && ok "planted: no head check → 2111 reads '$got' → red" || bad "planted: the head check dropped and the test cannot see it"
plant server.mjs "busy.length ? \`\${busy.length} still running\` : ''" "''"
got=$(row_of "$(snap "$P")" 2112 .now.text)
[ "$got" != "A check failed: Unit tests (2 still running)" ] && ok "planted: the running count dropped → 2112 reads '$got' → red" || bad "planted: the running count dropped and the test cannot see it"
plant server.mjs "export const ownerAsk = (text) => (UNTIL_LAUNCH_PM && !OWNER_ONLY_RE.test(String(text || '')) ? 'PM' : OWNER)" "export const ownerAsk = () => OWNER"
got=$(row_of "$(SWARM_UNTIL_LAUNCH_PM=true snap "$P")" 2108 .now.text)
[ "$got" != "Stopped: repair asked a question — next: PM" ] && ok "planted: the until-launch rule dropped → 2108 reads '$got' → red" || bad "planted: the until-launch rule dropped and the test cannot see it"
plant server.mjs "'Waiting for checks on the newest push' } : openPrState(p)" "'Waiting for checks on the newest push' } : { state: 'checks', text: 'Waiting for checks' }"
got=$(row_of "$(snap "$P")" 2101 .now.text)
[ "$got" != "Waiting for checks (2 running)" ] && ok "planted: no open-PR state → 2101 reads '$got' → red" || bad "planted: the open-PR state dropped and the test cannot see it"
plant server.mjs "  if (closed && closed.mergedAt && !(open && open.number > closed.number)) {" "  if (false) {"
got=$(row_of "$(snap "$P")" 2106 .now.text)
[ "$got" != "Merged $MERGED_HM" ] && ok "planted: no merge rule → 2106 reads '$got' → red" || bad "planted: the merge rule dropped and the test cannot see it"
plant server.mjs "  if (park && !(issue && issue.state === 'CLOSED')" "  if (false && park && !(issue && issue.state === 'CLOSED')"
got=$(row_of "$(snap "$P")" 2107 .now.text)
[ "$got" != "Stopped: build asked a question — next: PM" ] && ok "planted: no park rule → 2107 reads '$got' → red" || bad "planted: the park rule dropped and the test cannot see it"
plant server.mjs "  guard('pr states', () => refreshPrStates(now))"
rm -f "$STATE/swarm/pr-states.json"
got=$(snap "$P" | jq -c '.mergedToday')
[ "$got" = "null" ] && ok "planted: the PR-state read dropped → merged today reads $got → red" || bad "planted: the PR-state read dropped and the test cannot see it"
plant index.html "  document.getElementById('merged').innerHTML = mergedList(s.mergedToday)"
[ "$(page_render "$P" "$(snap)" | grep '^merged=' | grep -c 'pull/3106')" = 0 ] && ok "planted: the page drops Merged today → no link → red" || bad "planted: the page drops Merged today and the test cannot see it"
# The live and remote rows, re-planted against their own fixture.
printf '{"run_id":"claim-2201-a","ticket":"2201","child_pid":%s,"started_at":"%s","log":"%s"}\n' \
  "$$" "$(iso $(( NOW_S - 3600 )))" "$STATE/logs/claim-2201-a.log" > "$STATE/runs/claim-2201-a.json"
echo 'Reading the diff' > "$STATE/logs/claim-2201-a.log"
cat > "$STATE/swarm/claims.json" <<JSON
{"at":"$NOW_ISO","claims":[{"issue":"2201","host":"laptop","step":"review"},{"issue":"2301","host":"studio-mac","step":"build"}]}
JSON
printf '{"at":%s,"hosts":[{"host":"studio-mac","tick":%s,"runs":[{"t":"2301","at":%s,"say":"build: task 3 of 5"}]}]}\n' \
  "$NOW_S" "$(( NOW_S - 60 ))" "$(( NOW_S - 30 ))" > "$STATE/coordinator/fleet.json"
plant index.html "  if (a.stepFrom === 'claim' || (!a.stepFrom && a.claimStep)) return \`<b>\${esc(CLAIM_WORD[a.claimStep] || a.claimStep)}</b>\`"
[ "$(page_render "$P" "$(snap)" | grep '^building=' | grep -c 'Being reviewed')" = 0 ] \
  && ok "planted: the page ignores the claim's step → no 'Being reviewed' → red" || bad "planted: the claim step dropped and the test cannot see it"
plant server.mjs "    const run = !beatStale ? (hb.runs || []).find((r) => String(r.t) === String(c.issue)) : null" "    const run = null"
[ "$(page_render "$P" "$(snap "$P")" | grep -c 'dot ok[^>]*></span><div class="main"> <div class="title">Ticket 2301')" = 0 ] \
  && ok "planted: the heartbeat's runs ignored → 2301 is not green → red" || bad "planted: the heartbeat's runs ignored and the test cannot see it"
plant index.html "  const away = a.beatStale !== false" "  const away = true"
[ "$(page_render "$P" "$(snap)" | grep -c 'dot ok[^>]*></span><div class="main"> <div class="title">Ticket 2301')" = 0 ] \
  && ok "planted: every remote row grey again → red" || bad "planted: every remote row grey and the test cannot see it"

echo "--- the machine line shows the open-work cap ---"
printf '{"live":2,"ceiling":4,"reading":"cpu idle 60%%, 9 GB free","openPrs":{"count":23,"cap":10,"over":true}}\n' > "$STATE/coordinator/capacity.json"
r=$(page_render "$LV" "$(snap)")
want_in "over the cap: finishing before starting" '^machine=.*open changes 23 / cap 10: finishing before starting' "$r"
printf '{"live":2,"ceiling":4,"reading":"cpu idle 60%%, 9 GB free","openPrs":{"count":9,"cap":10,"over":false}}\n' > "$STATE/coordinator/capacity.json"
r=$(page_render "$LV" "$(snap)")
want_in "under it: the count alone"           '^machine=.*open changes 9 / cap 10' "$r"
want_not_in "and no hold claimed"              'finishing before starting' "$r"
printf '{"live":2,"ceiling":4,"reading":"cpu idle 60%%, 9 GB free","openPrs":{"count":23,"cap":10,"over":true}}\n' > "$STATE/coordinator/capacity.json"
plant index.html "  if (op && op.cap) parts.push(" "  if (false) parts.push("
[ "$(page_render "$P" "$(snap)" | grep -c 'open changes 23')" = 0 ] \
  && ok "planted: the page drops the cap → red" || bad "planted: the page drops the cap and the test cannot see it"
rm -f "$STATE/coordinator/capacity.json"

suite_end "$FAILED"
