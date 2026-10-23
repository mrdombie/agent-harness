#!/usr/bin/env bash
# cap-quick.test.sh — the driver's half of "quick tickets bypass the open-work cap".
#
# The owner, 2026-10-22: over coordinator.openPrCap, quick-sized new tickets start anyway;
# bigger ones still wait. "Quick" includes small changes on EXISTING screens (wording, one
# button, one component, at most maxFiles files, no new route, no schema, no lockfile, not
# screen:new or screen:redesign). These cases hold the size rules to that, and a run the
# coordinator started over the cap that then sizes bigger to stopping before plan: requeued,
# its quick attempt kept, and a slip left so the coordinator does not start it over the cap again.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"

mkdir -p "$REPO/config" "$REPO/src/screens" "$REPO/src/lib" "$REPO/app/home"
printf '{ "lint": "loose" }\n' > "$REPO/config/app.json"
printf 'export const Home = () => "Hi"\n' > "$REPO/src/screens/home.tsx"
printf 'export default function Page() { return null }\n' > "$REPO/app/home/page.tsx"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project with a config file, a screen and a route"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

export HARNESS_STATE_DIR="$STATE"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1
. "$HERE/../steps/size.sh" || exit 1
. "$HERE/../steps/quick.sh" || exit 1
# Two configs beside the repo's own: the screens named, with and without the baseline route.
jq '.design = {"surfacePaths": ["src/screens/*"]}' "$HARNESS_CFG_PATH" > "$FIX/h-screens.json"
jq '.design = {"surfacePaths": ["src/screens/*"], "baselineRoute": {"enabled": true}}' "$HARNESS_CFG_PATH" > "$FIX/h-base.json"

issue() { # <n> <labels-csv> <title> <body>
  jq -n --argjson n "$1" --arg l "$2" --arg t "$3" --arg b "$4" \
    '{number:$n, state:"OPEN", title:$t, body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))}' \
    > "$FIX/gh/issue-$1.json"
}
bsz() { HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 "$1" "${3:-}" "$2" | cut -f1; }
ssz() { HARNESS_CFG="$FIX/h-screens.json" driver_size_read 1 "$1" "${3:-}" "$2" | cut -f1; }
WORDING='In src/screens/home.tsx change the heading "Hi" to "Hello".'
CONFIG_BODY='In `config/app.json`, change `lint` from "loose" to "strict".'

echo "--- the size rules: an existing screen is quick on the baseline route ---"
want "a config ticket is quick"                                  quick   "$(bsz 'Lint' "$CONFIG_BODY")"
want "an existing screen's wording change is quick"              quick   "$(bsz 'Copy' "$WORDING")"
want "an existing route's one-line change is quick"              quick   "$(bsz 'Copy' 'In app/home/page.tsx change the title "Home" to "Dashboard".')"
want "without the baseline route a screen file is never quick"   project "$(ssz 'Copy' "$WORDING")"
want_in "and says so"           'src/screens/home.tsx — a screen file' "$(HARNESS_CFG="$FIX/h-screens.json" driver_size_read 1 'Copy' '' "$WORDING")"
want "a screen file not on the trunk is a new screen"            project "$(bsz 'Copy' 'In src/screens/fresh.tsx set the heading to "Hello".')"
want_in "said as a new screen file" 'src/screens/fresh.tsx — a new screen file' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'Copy' '' 'In src/screens/fresh.tsx set the heading to "Hello".')"
want "a page not on the trunk is a new route"                    project "$(bsz 'Route' 'In app/settings/page.tsx set the title to "Settings".')"
want_in "said as new"         'app/settings/page.tsx — a new (route|screen file)' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'Route' '' 'In app/settings/page.tsx set the title to "Settings".')"
want "screen:redesign is never quick"                            project "$(bsz 'Copy' "$WORDING" 'screen:redesign')"
want "screen:new is never quick"                                 project "$(bsz 'Copy' "$WORDING" 'screen:new')"
want "a lockfile beside an existing screen is never quick"       project "$(bsz 'Copy' "$WORDING And bump left-pad in package-lock.json to 1.3.0.")"
want "a schema change on an existing screen is never quick"      project "$(bsz 'Copy' "$WORDING And add a column to the users table.")"
want "four files on an existing screen is not quick"             small   "$(bsz 'Copy' 'Set a to b in src/screens/home.tsx, src/lib/a.ts, src/lib/b.ts and src/lib/c.ts.')"
want "a feature naming no file is not quick"                     project "$(bsz 'Saved searches' 'Recruiters want to save a search and be told when new candidates match it.')"

echo "--- sized by what the ticket is, not what it mentions ---"
# The live ticket #8807: effort:XL, ~715 routes, one named file and a fenced block, so it read quick.
XL_BODY='Group the gated routes into permission classes. Inputs:
```bash
grep -rn "OPEN_ROUTES" config/app.json
```'
want "the #8807 shape reads quick with no effort label (the plant's control)" quick "$(bsz 'test(access): permission matrix' "$XL_BODY")"
want "effort:XL naming one file is not quick"                    project "$(bsz 'test(access): permission matrix' "$XL_BODY" 'P1,effort:XL,type:chore')"
want "effort:L is not quick"                                     project "$(bsz 'Lint' "$CONFIG_BODY" 'effort:L')"
want "effort:M is not quick"                                     small   "$(bsz 'Lint' "$CONFIG_BODY" 'effort:M')"
want_in "and says why" 'it carries effort:XL: an effort that size is never quick' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'x' 'effort:XL' "$XL_BODY")"
want "effort:S stays quick"                                      quick   "$(bsz 'Lint' "$CONFIG_BODY" 'effort:S')"
jq '.driver.quick.neverEffort = ["size:big"]' "$FIX/h-base.json" > "$FIX/h-effort.json"
want "driver.quick.neverEffort replaces the default list" quick   "$(HARNESS_CFG="$FIX/h-effort.json" driver_size_read 1 'Lint' 'effort:L' "$CONFIG_BODY" | cut -f1)"
want "and its own label is never quick"                  project "$(HARNESS_CFG="$FIX/h-effort.json" driver_size_read 1 'Lint' 'size:big' "$CONFIG_BODY" | cut -f1)"
# The live ticket #10936: names labelled.json, a scratchpad file that is in no repo.
GONE_BODY='In `labelled.json`, change `sample` from 270 to 300.'
want "a ticket whose only named file is missing is undecided, not quick" undecided "$(bsz 'Self-check' "$GONE_BODY")"
want_in "and names the missing file" 'none of the files it names is on develop \(labelled.json\)' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'x' '' "$GONE_BODY")"
want "a missing file beside an existing one is not counted"      quick   "$(bsz 'Lint' "$CONFIG_BODY Also see notes/missing.md.")"
want_in "and is said as not counted" 'not counted: notes/missing.md' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'x' '' "$CONFIG_BODY Also see notes/missing.md.")"
want "a missing code file does not make a config ticket a code one" quick "$(bsz 'Lint' 'Tidy `config/app.json`; the old reader was src/lib/gone.ts.')"
want "with no readable trunk no named file counts"               undecided "$(MAIN_REPO="$FIX/nowhere" bsz 'Lint' "$CONFIG_BODY")"
# This project is acme/widgets: a repo:<other> label is another repo's work.
want "a repo:<other> ticket is never quick here"                 project "$(bsz 'Lint' "$CONFIG_BODY" 'repo:agent-harness')"
want_in "and says whose it is" 'it belongs to agent-harness, not this project' "$(HARNESS_CFG="$FIX/h-base.json" driver_size_read 1 'x' 'repo:agent-harness' "$CONFIG_BODY")"
want "the #10936 shape (effort:M, repo:agent-harness, a missing file) is not quick" project "$(bsz 'Self-check' "$GONE_BODY" 'P1,effort:M,type:feature,repo:agent-harness')"
want "a repo label naming this repo stays quick"                 quick   "$(bsz 'Lint' "$CONFIG_BODY" 'repo:widgets')"
want "an owner/name repo label naming this repo stays quick"     quick   "$(bsz 'Lint' "$CONFIG_BODY" 'repo:Acme/Widgets')"
want "a ticket for both repos is this repo's too"                quick   "$(bsz 'Lint' "$CONFIG_BODY" 'repo:agent-harness,repo:widgets')"
jq '.sisterRepos = ["widgets-support"]' "$FIX/h-base.json" > "$FIX/h-sister.json"
want "a sister repo's ticket is this project's to build" quick "$(HARNESS_CFG="$FIX/h-sister.json" driver_size_read 1 'Lint' 'repo:widgets-support' "$CONFIG_BODY" | cut -f1)"
rc=0; driver_repo_foreign 'P1,status:ready' >/dev/null || rc=$?
want "no repo label is this repo's"                              1 "$rc"

echo "--- the real diff: an existing screen fits, a screen it adds does not ---"
issue 904 "status:ready" "Copy" "$WORDING"
git -C "$REPO" worktree add -q "$FIX/wt904" -b tkt-904/x develop
printf 'export const Home = () => "Hello"\n' > "$FIX/wt904/src/screens/home.tsx"
git -C "$FIX/wt904" commit -qam "wording"
rc=0; why=$(HARNESS_CFG="$FIX/h-base.json" driver_quick_exceeds 904 "$FIX/wt904" develop) || rc=$?
want "an existing screen's real diff fits a quick change on the baseline route" 1 "$rc"
rc=0; why=$(HARNESS_CFG="$FIX/h-screens.json" driver_quick_exceeds 904 "$FIX/wt904" develop) || rc=$?
want "and does not without the baseline route" 0 "$rc"
git -C "$REPO" worktree add -q "$FIX/wt905" -b tkt-905/x develop
printf 'export const Fresh = () => null\n' > "$FIX/wt905/src/screens/fresh.tsx"
git -C "$FIX/wt905" add -A; git -C "$FIX/wt905" commit -qm "a new screen"
issue 905 "status:ready" "Copy" "$WORDING"
rc=0; why=$(HARNESS_CFG="$FIX/h-base.json" driver_quick_exceeds 905 "$FIX/wt905" develop) || rc=$?
want "a screen file the diff adds exceeds a quick change" 0 "$rc"
want_in "named as a new screen file" 'src/screens/fresh.tsx — a new screen file' "$why"
issue 906 "status:ready,screen:redesign" "Copy" "$WORDING"
rc=0; why=$(HARNESS_CFG="$FIX/h-base.json" driver_quick_exceeds 906 "$FIX/wt904" develop) || rc=$?
want "an existing screen labelled screen:redesign exceeds it (the picture route)" 0 "$rc"

echo "--- the size step keeps the body it sized, for a slip ---"
issue 701 "status:ready" "Make lint strict" "$CONFIG_BODY"
driver_state_init 701
HARNESS_CFG="$FIX/h-base.json" driver_step_size 701 >/dev/null 2>&1
want "the body's hash is on the record" "$(driver_size_body_hash "$CONFIG_BODY")" "$(driver_state_get 701 size_body_hash)"

echo "--- started over the open-work cap: a slip stops before plan and is requeued ---"
cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
chmod +x "$FIX/queue-stub.sh"; export DRIVER_QUEUE="$FIX/queue-stub.sh"
FAKE="$FIX/fakesteps"; RAN="$FIX/ran.log"; export RAN
fake() { # <step> <codes…> [route]
  local s="$1" codes="$2" route="${3:-}"
  { echo '#!/usr/bin/env bash'
    printf 'driver_step_%s() {\n' "${s//-/_}"
    printf '  printf "%%s\\n" %s >> "$RAN"\n' "$s"
    [ -z "$route" ] || printf '  driver_state_set "$1" route %s; driver_state_set "$1" size %s; driver_state_set "$1" size_reason "it names a feature"; driver_state_set "$1" size_body_hash "bh-$1"\n' "$route" "$route"
    [ "$s" != quick ] || printf '  driver_state_set "$1" quick_fallback "the change touches src/screens/fresh.tsx — a new screen file"\n'
    printf '  local nf="$FIX/n.%s"; local n=$(( $(cat "$nf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$nf"\n' "$s"
    printf '  local c; c=$(printf "%%s\\n" %s | sed -n "${n}p"); [ -n "$c" ] || c=$(printf "%%s\\n" %s | tail -1)\n' "$codes" "$codes"
    printf '  return "$c"\n}\n'
  } > "$FAKE/$s.sh"
}
fakes() { # <size-route> [step:codes…]
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$RAN"; rm -f "$FIX"/n.*; : > "$FIX/queue.log"
  printf '#!/usr/bin/env bash\ndriver_park() { printf "PARK %%s\\n" "$2" >> "$FIX/park.log"; return 20; }\n' > "$FAKE/park.sh"
  local s p
  for s in start plan build fix compare self-check review record ship quick; do fake "$s" 0; done
  fake size 0 "$1"; shift
  for p in "$@"; do fake "${p%%:*}" "${p#*:}"; done
}
ran() { tr '\n' ' ' < "$RAN" | sed 's/ $//'; }

fakes quick "quick:$DRIVER_E_UPSIZE"
rm -rf "$STATE/driver/1007"
out=$(DRIVER_CAP_BYPASS=1 DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1007 2>&1); rc=$?
want "a quick step that sizes bigger over the cap stops before plan" "start size quick" "$(ran)"
want "requeued, not parked" "$DRIVER_E_REQUEUE" "$rc"
want_in "it says it waits behind the cap" 'waits behind the open-work cap' "$out"
want_in "and why"                         'a new screen file' "$out"
want_in "back on the queue at the front"  '^add 1007 .*--first' "$(cat "$FIX/queue.log")"
want "the slip is kept on its body"       "bh-1007" "$(cut -f1 "$STATE/size-cache/1007.slip" 2>/dev/null)"
want "and nothing parked"                 "" "$(cat "$FIX/park.log" 2>/dev/null)"

fakes full
rm -rf "$STATE/driver/1008"
out=$(DRIVER_CAP_BYPASS=1 DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1008 2>&1); rc=$?
want "sized bigger at size over the cap: it stops before plan" "start size" "$(ran)"
want "requeued"                           "$DRIVER_E_REQUEUE" "$rc"
want_in "and says so"                     'waits behind the open-work cap' "$out"
want "the slip is kept"                   "bh-1008" "$(cut -f1 "$STATE/size-cache/1008.slip" 2>/dev/null)"
: > "$RAN"; out=$(DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1008 2>&1); rc=$?
want "the next run, under the cap, goes on from plan" "start plan build fix compare self-check review record ship" "$(ran)"
want "and finishes"                       0 "$rc"

fakes quick
rm -rf "$STATE/driver/1009"
out=$(DRIVER_CAP_BYPASS=1 DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1009 2>&1); rc=$?
want "a quick one over the cap walks the quick order to ship" "start size quick review ship" "$(ran)"
want "and finishes"                       0 "$rc"
want "with no slip"                       "" "$(cat "$STATE/size-cache/1009.slip" 2>/dev/null)"

fakes quick "quick:$DRIVER_E_UPSIZE"
rm -rf "$STATE/driver/1010"
DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1010 >/dev/null 2>&1; rc=$?
want "under the cap an upsize still goes on from plan" "start size quick plan build fix compare self-check review record ship" "$(ran)"

echo "--- the slip ledger ---"
driver_size_slip_put 77 bh-a "why"
driver_size_slipped 77 bh-a; want "a slipped body reads as slipped" 0 "$?"
driver_size_slipped 77 bh-b; want "a changed body does not" 1 "$?"
driver_size_slipped 78 bh-a; want "nor another ticket" 1 "$?"

suite_end "$FAILED"
