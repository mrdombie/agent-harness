#!/usr/bin/env bash
# quick-route.test.sh — a ticket is sized before it is planned, and a quick one is one
# agent session, one review and an open PR — not nine steps and seven sessions.
#
# The owner, 2026-10-22: "So a tiny change will take half an hour?" A two-line config
# edit took 3 minutes by hand and was projected at ~30 through the driver. These cases
# hold the size step to its rules, walk the REAL steps for a config ticket (real git,
# a real origin, the briefs that ship; only the model and GitHub are stubbed), and
# prove the fallback: a quick change that turns out bigger goes to the full route.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
fix_real_briefs
BT="$HERE/../build-ticket"

jq --arg r "$FIX/trees" '.gates = {"local": ["echo lint-ok"]} | .worktreeRoot = $r
    | .commit = {"parkType": "chore"} | .design = {"surfacePaths": ["src/screens/*"]}' \
  "$REPO/.claude/harness.json" > "$FIX/h.json" && mv "$FIX/h.json" "$REPO/.claude/harness.json"
mkdir -p "$REPO/config" "$REPO/src/screens" "$REPO/src/lib"
printf '{ "lint": "loose" }\n' > "$REPO/config/app.json"
printf 'export const Home = () => null\n' > "$REPO/src/screens/home.tsx"
git -C "$REPO" add -A && git -C "$REPO" commit -qm "a project with a config file and a screen"
git init -q --bare "$FIX/origin"
git -C "$REPO" remote add origin "$FIX/origin"
git -C "$REPO" push -q origin develop

export HARNESS_STATE_DIR="$STATE"
. "$HERE/../driver-env.sh" || exit 1
. "$HERE/../state.sh" || exit 1
. "$HERE/../steps/size.sh" || exit 1
. "$HERE/../steps/quick.sh" || exit 1
HARNESS_CFG="$REPO/.claude/harness.json"; export HARNESS_CFG

# issue <n> <labels-csv> <title> <body>
issue() {
  jq -n --argjson n "$1" --arg l "$2" --arg t "$3" --arg b "$4" \
    '{number:$n, state:"OPEN", title:$t, body:$b, labels:($l|split(",")|map(select(length>0)|{name:.}))}' \
    > "$FIX/gh/issue-$1.json"
}
# The model is stubbed, and a stubbed session can still EDIT: <step>.do runs in the
# tree the driver started the step in, then the fixture's recorder answers.
cat > "$BIN/claude-q" <<'SH'
#!/usr/bin/env bash
step=""; prev=""; for a in "$@"; do [ "$prev" = --name ] && step="$a"; prev="$a"; done
[ ! -x "$FIX/ai/$step.do" ] || "$FIX/ai/$step.do" </dev/null >/dev/null 2>&1
exec "$BIN/claude" "$@"
SH
chmod +x "$BIN/claude-q"; export DRIVER_CLAUDE="$BIN/claude-q"
do_step() { printf '#!/usr/bin/env bash\nset -e\n%s\n' "$2" > "$FIX/ai/$1.do"; chmod +x "$FIX/ai/$1.do"; }
QUICK_OK=$(jq -c . "$DRIVER_BRIEFS/examples/quick.valid.json")
REVIEW_SHIP=$(jq -c . "$DRIVER_BRIEFS/examples/review.valid-ship-clean.json")
CONFIG_BODY='In `config/app.json`, change `lint` from "loose" to "strict":
```json
{ "lint": "strict" }
```'

echo "--- the default order sizes the ticket right after start ---"
want "size is the second step of a build" "start size plan" "$(printf '%s' "$DRIVER_STEPS" | cut -d' ' -f1-3)"
want "and the quick order is one session, one review, ship" "start size quick review ship" "$DRIVER_QUICK_STEPS"

echo "--- the size rules ---"
sz() { driver_size_read 1 "$1" "${3:-}" "$2" | cut -f1; }
want "a config file with the change stated is quick"     quick   "$(sz 'Make lint strict' "$CONFIG_BODY")"
want "a docs file named alone is quick"                  quick   "$(sz 'Fix a typo' 'The word "recieve" in docs/guide.md is spelt wrong.')"
want "a code file with the change stated is quick"       quick   "$(sz 'Rename a helper' 'In src/lib/util.ts rename `fmt` to `formatDate`.')"
want "a code file with no stated change is undecided"    undecided "$(sz 'Tidy util' 'src/lib/util.ts is hard to read.')"
want "a stated change naming no file is undecided"       undecided "$(sz 'Copy' 'Change the Posts tab label to Content.')"
want "naming no file and no change is project"           project "$(sz 'Improve onboarding' 'spec')"
want "a screen file is never quick"                      project "$(sz 'Copy' 'In src/screens/home.tsx change "Hi" to "Hello".')"
want_in "and it says which file"  'src/screens/home.tsx — a screen file' "$(driver_size_read 1 'Copy' '' 'In src/screens/home.tsx change "Hi" to "Hello".')"
want "a lockfile is never quick"                         project "$(sz 'Bump' 'Bump left-pad in package-lock.json to 1.3.0.')"
want "a schema ticket is never quick"                    project "$(sz 'Add a column' 'In config/app.json set `x` to 1, and add a column to the users table with a migration.')"
want "a prisma file is never quick"                      project "$(sz 'Field' 'Set `name` to optional in prisma/schema.prisma.')"
want "a schema label is never quick"                     project "$(sz 'Config' "$CONFIG_BODY" 'schema')"
want "a design label is never quick"                     project "$(sz 'Config' "$CONFIG_BODY" 'needs:design')"
want "four named files is small"                         small   "$(sz 'Four' 'Set a to b in a.json, b.json, c.json and d.json.')"
want "a URL is not a file"                               project "$(sz 'Docs' 'See https://example.com/guide.md for why.')"

echo "--- the size step: rules first, one short call only when undecided ---"
issue 701 "status:ready" "Make lint strict" "$CONFIG_BODY"
driver_state_init 701; : > "$CLAUDE_LOG"
rc=0; out=$(driver_step_size 701 2>&1) || rc=$?
want "it finishes" 0 "$rc"
want "a config ticket is routed quick" quick "$(driver_state_get 701 route)"
want "sized by the rules" rules "$(driver_state_get 701 size_by)"
want "with no model call" "" "$(cat "$CLAUDE_LOG")"
want_in "and it says the route" 'size: route=quick size=quick' "$out"
issue 702 "status:ready" "Tidy util" "src/lib/util.ts is hard to read."
driver_state_init 702; : > "$CLAUDE_LOG"
fix_ai size '{"size":"quick","reason":"one line in one helper"}'
rc=0; out=$(driver_step_size 702 2>&1) || rc=$?
want "an undecided ticket asks once" "size" "$(cat "$CLAUDE_LOG")"
want "and takes the call's size" quick "$(driver_state_get 702 size)"
want "said as the model's" model "$(driver_state_get 702 size_by)"
issue 703 "status:ready" "Tidy util" "src/lib/util.ts is hard to read."
driver_state_init 703; rm -f "$FIX/ai/size.jsonl"
rc=0; driver_step_size 703 >/dev/null 2>&1 || rc=$?
want "a call with no answer is the full route" full "$(driver_state_get 703 route)"
issue 704 "status:ready" "Make lint strict" "$CONFIG_BODY"
driver_state_init 704; driver_state_done 704 plan
driver_step_size 704 >/dev/null 2>&1
want "a ticket already planned keeps the full route" full "$(driver_state_get 704 route)"
jq '.driver = {"quick": {"enabled": false}}' "$HARNESS_CFG" > "$FIX/h.json" && cp "$FIX/h.json" "$FIX/h-off.json"
HARNESS_CFG="$FIX/h-off.json" driver_step_size 701 >/dev/null 2>&1
want "driver.quick.enabled false routes full" full "$(driver_state_get 701 route)"
want "and still logs the size" quick "$(driver_state_get 701 size)"

echo "--- a config-only ticket: claim to an open PR on one session and one review ---"
issue 801 "status:ready" "Make lint strict" "$CONFIG_BODY"
fix_ai quick "$QUICK_OK" superpowers:verification-before-completion
do_step quick 'printf "{ \"lint\": \"strict\" }\n" > config/app.json; git add config/app.json; git commit -qm "chore(config): lint strict (#801)"'
fix_ai review "$REVIEW_SHIP" superpowers:requesting-code-review
: > "$CLAUDE_LOG"; : > "$GH_LOG"
t0=$(date +%s)
rc=0; out=$(bash "$BT" 801 2>&1) || rc=$?
secs=$(( $(date +%s) - t0 ))
printf '%s\n' "$out" | sed 's/^/    /' | tail -12
want "the run finishes" 0 "$rc"
want "it walks the quick order" "start,size,quick,review,ship" "$(driver_state_get 801 'done|join(",")')"
want "one agent session and one review, nothing else" "quick review" "$(tr '\n' ' ' < "$CLAUDE_LOG" | sed 's/ $//')"
want_in "a PR is opened"            'pr create' "$(cat "$GH_LOG")"
want_in "made ready"                'pr ready'  "$(cat "$GH_LOG")"
want_in "with auto-merge armed"     'pr merge .*--auto' "$(cat "$GH_LOG")"
want "the change reached origin" '{ "lint": "strict" }' "$(git -C "$FIX/origin" show "$(driver_state_get 801 branch):config/app.json" 2>/dev/null)"
want "the record says route=quick" quick "$(driver_state_get 801 route)"
want_in "the claim to PR time is on the record" '^[0-9]+$' "$(driver_state_get 801 claim_to_pr_secs)"
want_in "and on the run's last line" 'shipped: .* route=quick size=quick claim→PR [0-9]+m[0-9]{2}s' "$(printf '%s\n' "$out" | tail -1)"
want_in "the gates ran on it" 'self-check: .*gate\(s\) green' "$out"
echo "    (claim→PR on stubs: ${secs}s)"
want_in "inside 5 minutes" '^([0-9]|[0-9][0-9]|[12][0-9][0-9])$' "$secs"

echo "--- a quick change that touches a screen goes to the full route, keeping the work ---"
issue 802 "status:ready" "Make lint strict" "$CONFIG_BODY"
do_step quick 'printf "{ \"lint\": \"strict\" }\n" > config/app.json; printf "export const Home = () => 1\n" > src/screens/home.tsx; git add -A; git commit -qm "chore: lint strict and a screen (#802)"'
: > "$CLAUDE_LOG"
rc=0; out=$(bash "$BT" 802 2>&1) || rc=$?
want_in "it says why it moved up" 'src/screens/home.tsx — a screen file' "$out"
want_in "plan runs after quick: the full route, from plan" '^quick plan' "$(tr '\n' ' ' < "$CLAUDE_LOG")"
want "the record says route=full" full "$(driver_state_get 802 route)"
want "and the size went up to project" project "$(driver_state_get 802 size)"
WT802=$(driver_state_get 802 worktree)
want "the quick attempt is kept at its ref" "export const Home = () => 1" "$(git -C "$WT802" show refs/driver/quick/802:src/screens/home.tsx 2>/dev/null)"
want "and the branch is back at its cut, for the proof" "$(git -C "$REPO" rev-parse develop)" "$(git -C "$WT802" rev-parse HEAD)"
want_in "the full route is told where the attempt is" 'refs/driver/quick/802' "$(cat "$(driver_state_get 802 run_brief)" 2>/dev/null)"

echo "--- a migration in the real diff is never quick ---"
git -C "$REPO" worktree add -q "$FIX/wt901" -b tkt-901/x develop
mkdir -p "$FIX/wt901/db/migrations"; printf 'alter table t add c int;\n' > "$FIX/wt901/db/migrations/001.sql"
git -C "$FIX/wt901" add -A; git -C "$FIX/wt901" commit -qm "a migration"
rc=0; why=$(driver_quick_exceeds 901 "$FIX/wt901" develop) || rc=$?
want "it exceeds a quick change" 0 "$rc"
want_in "naming the migration" 'db/migrations/001.sql — never quick' "$why"
git -C "$REPO" worktree add -q "$FIX/wt902" -b tkt-902/x develop
for f in a b c d; do printf '%s\n' "$f" > "$FIX/wt902/docs-$f.md"; done
git -C "$FIX/wt902" add -A; git -C "$FIX/wt902" commit -qm "four files"
rc=0; why=$(driver_quick_exceeds 902 "$FIX/wt902" develop) || rc=$?
want "more files than maxFiles exceeds it" 0 "$rc"
git -C "$REPO" worktree add -q "$FIX/wt903" -b tkt-903/x develop
printf '{ "lint": "strict" }\n' > "$FIX/wt903/config/app.json"
git -C "$FIX/wt903" add -A; git -C "$FIX/wt903" commit -qm "config"
rc=0; driver_quick_exceeds 903 "$FIX/wt903" develop >/dev/null || rc=$?
want "one config file fits" 1 "$rc"

echo "--- the quick step's own skill is the one its log must show ---"
issue 804 "status:ready" "Make lint strict" "$CONFIG_BODY"
git -C "$REPO" worktree add -q "$FIX/wt804" -b tkt-804/x develop
driver_state_init 804 --worktree "$FIX/wt804" --branch tkt-804/x
driver_state_set 804 size quick
fix_ai quick "$QUICK_OK" ""
do_step quick 'true'
rc=0; driver_step_quick 804 >/dev/null 2>&1 || rc=$?
want "a quick session whose log shows no skill is refused" "$DRIVER_E_NO_SKILL" "$rc"
want "the quick step declares verification-before-completion" "superpowers:verification-before-completion" \
  "$(driver_declared_skills quick | tr '\n' ' ' | sed 's/ $//')"

echo "--- the orchestration, on recorded steps ---"
FAKE="$FIX/fakesteps"; RAN="$FIX/ran.log"; export RAN
fake() { # <step> <codes…> [route]
  local s="$1" codes="$2" route="${3:-}"
  { echo '#!/usr/bin/env bash'
    printf 'driver_step_%s() {\n' "${s//-/_}"
    printf '  printf "%%s\\n" %s >> "$RAN"\n' "$s"
    [ -z "$route" ] || printf '  driver_state_set "$1" route %s; driver_state_set "$1" size %s\n' "$route" "$route"
    printf '  local nf="$FIX/n.%s"; local n=$(( $(cat "$nf" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$nf"\n' "$s"
    printf '  local c; c=$(printf "%%s\\n" %s | sed -n "${n}p"); [ -n "$c" ] || c=$(printf "%%s\\n" %s | tail -1)\n' "$codes" "$codes"
    printf '  return "$c"\n}\n'
  } > "$FAKE/$s.sh"
}
fakes() { # <size-route> [step:codes…]
  rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$RAN"; rm -f "$FIX"/n.*
  printf '#!/usr/bin/env bash\ndriver_park() { printf "PARK %%s\\n" "$2" >> "$FIX/park.log"; return 20; }\n' > "$FAKE/park.sh"
  local s p
  for s in start plan build fix compare self-check review record ship quick; do fake "$s" 0; done
  fake size 0 "$1"; shift
  for p in "$@"; do fake "${p%%:*}" "${p#*:}"; done
}
ran() { tr '\n' ' ' < "$RAN" | sed 's/ $//'; }
fakes quick
rm -rf "$STATE/driver/1001"; out=$(DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1001 2>&1); rc=$?
want "a quick ticket walks the quick order" "start size quick review ship" "$(ran)"
want "and finishes" 0 "$rc"
fakes full
rm -rf "$STATE/driver/1002"; DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1002 >/dev/null 2>&1
want "a full ticket walks the full order" "start size plan build fix compare self-check review record ship" "$(ran)"
fakes quick "quick:$DRIVER_E_UPSIZE"
rm -rf "$STATE/driver/1003"; out=$(DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1003 2>&1); rc=$?
want "a quick step that upsizes goes on from plan" "start size quick plan build fix compare self-check review record ship" "$(ran)"
want "and finishes" 0 "$rc"
want "on the full route" full "$(driver_state_get 1003 route)"
fakes quick "review:$DRIVER_E_REWORK 0"
rm -rf "$STATE/driver/1004"; out=$(DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1004 2>&1); rc=$?
want "a review that blocks a quick change goes to the full route's fix" "start size quick review fix compare self-check review record ship" "$(ran)"
want "and finishes" 0 "$rc"
fakes quick "quick:$DRIVER_E_REQUEUE 0"
rm -rf "$STATE/driver/1005"; DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1005 >/dev/null 2>&1; : > "$RAN"
DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1005 >/dev/null 2>&1
want "a resumed quick ticket stays on the quick order" "start quick review ship" "$(ran)"
fakes quick
rm -rf "$STATE/driver/1006"; DRIVER_STEPS_DIR="$FAKE" bash "$BT" 1006 --steps "start size plan" >/dev/null 2>&1
want "an order given with --steps is walked as given" "start size plan" "$(ran)"

echo "--- review: on the quick route a Minor does not block ---"
issue 805 "status:ready" "Make lint strict" "$CONFIG_BODY"
git -C "$REPO" worktree add -q "$FIX/wt805" -b tkt-805/x develop
printf '{ "lint": "strict" }\n' > "$FIX/wt805/config/app.json"; git -C "$FIX/wt805" commit -qam "config"
driver_state_init 805 --worktree "$FIX/wt805" --branch tkt-805/x
driver_state_set 805 route quick
fix_ai review "$(jq -c '.findings = [.findings[] | select(.grade == "minor")]' "$DRIVER_BRIEFS/examples/review.valid-blocked.json")" superpowers:requesting-code-review
. "$HERE/../steps/review.sh" || exit 1
rc=0; out=$(driver_step_review 805 2>&1) || rc=$?
want "a quick change with only a Minor is not sent back" 0 "$rc"
want "its verdict is SHIP" SHIP "$(jq -r .verdict "$(driver_state_dir 805)/steps/review.json")"
driver_state_set 806 route quick 2>/dev/null; driver_state_init 806 --worktree "$FIX/wt805" --branch tkt-805/x; driver_state_set 806 route quick
fix_ai review "$(jq -c . "$DRIVER_BRIEFS/examples/review.valid-blocked.json")" superpowers:requesting-code-review
rc=0; out=$(driver_step_review 806 2>&1) || rc=$?
want "a Major sends it back" "$DRIVER_E_REWORK" "$rc"

suite_end "$FAILED"
