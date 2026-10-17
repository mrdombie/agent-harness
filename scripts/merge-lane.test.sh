#!/usr/bin/env bash
# merge-lane.test.sh — the guards the lane exists to hold: its order, one PR in
# flight at a time, a conflict or a real red leaves the lane with a fixer, a
# flake is re-run once, a hold is re-cleared only after a develop-only update
# that left the PR's own screens alone, shadow does nothing, and the project's
# facts come from harness.json.
# Run: bash "$0"
set -uo pipefail
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../swarm/tests/fixture.sh"
swarm_fixture; trap 'rm -rf "$FIX"' EXIT
L="$HERE/merge-lane.sh"
C="$STATE/coordinator"
cfg() { jq "$1" "$HARNESS_CFG_PATH" > "$FIX/h.json" && mv "$FIX/h.json" "$HARNESS_CFG_PATH"; }
cfg '.merge = {method: "squash"} | .gates = {requiredChecks: ["build", "lint"]} | .design = {surfacePaths: ["apps/web/**", ":(exclude)**/*.test.ts"], surfacePathsComplete: true}'

# The forge: answers from $FIX/gh/, records every call, and can be told to refuse.
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
q=""; prev=""; ep=""
for a in "$@"; do
  case "$prev" in -q|--jq) q="$a" ;; esac
  prev="$a"
done
if [ "$1" = api ]; then
  skip=0
  for a in "${@:2}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    case "$a" in -X|-f|-F|-H|-q|--jq|--method|--input) skip=1 ;; -*) ;; *) [ -n "$ep" ] || ep="$a" ;; esac
  done
fi
emit() { if [ -n "$q" ]; then jq -r "$q" < "$1"; else cat "$1"; fi; }
case "$1 $2" in
  "pr list") f="$FIX/gh/prs-all.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  "pr merge")
    case "$*" in *--disable-auto*) exit 0 ;; esac
    [ -f "$FIX/gh/merge-$3.fail" ] && { cat "$FIX/gh/merge-$3.fail" >&2; exit 1; }; exit 0 ;;
  "pr view") jq --argjson n "$3" '.[] | select(.number == $n) | {author:{login:"tester"}, headRefOid, headRefName}' "$FIX/gh/prs-all.json" ;;
  "variable get") exit 1 ;;
  "label list") f="$FIX/gh/labels.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  "label create") [ -f "$FIX/gh/label-create.fail" ] && exit 1
    jq --arg l "$3" '. + [{name:$l}]' "$FIX/gh/labels.json" > "$FIX/gh/l.json" && mv "$FIX/gh/l.json" "$FIX/gh/labels.json"; exit 0 ;;
  "pr edit") # like GitHub: a label the repo lacks cannot be added
    prev=""; for a in "$@"; do
      [ "$prev" = --add-label ] && { jq -e --arg l "$a" 'any(.[]; .name == $l)' "$FIX/gh/labels.json" >/dev/null 2>&1 || exit 1; }
      prev="$a"; done; exit 0 ;;
  "issue view") f="$FIX/gh/issue-$3.json"; [ -f "$f" ] || exit 1; emit "$f" ;;
  api*)
    case "$ep" in
      */update-branch)
        n=$(printf '%s' "$ep" | sed -E 's#.*/pulls/([0-9]+)/update-branch#\1#')
        [ -f "$FIX/gh/update-$n.fail" ] && { cat "$FIX/gh/update-$n.fail" >&2; exit 1; }
        echo '{"message":"Updating pull request branch."}'; exit 0 ;;
    esac
    f="$FIX/gh/api-$(printf '%s' "$ep" | tr '/?&=' '____').json"
    [ -f "$f" ] || exit 1; emit "$f" ;;
  *) : ;;
esac
exit 0
GH
cat > "$BIN/notify" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/notify.log"
SH
chmod +x "$BIN/gh" "$BIN/notify"
export COORDINATOR_NOTIFY_CMD="$BIN/notify"
unset MERGE_LANE_SHADOW COORDINATOR_SHADOW

fresh() {
  rm -rf "$C" "$STATE/runs"/* "$STATE/swarm/HOLD" "$FIX"/gh/update-*.fail "$FIX"/gh/merge-*.fail "$FIX"/gh/api-repos_*compare*.json "$FIX"/gh/api-repos_*annotations*.json
  : > "$GH_LOG"; : > "$SPAWNS"; : > "$FIX/notify.log"
  printf '[]\n' > "$FIX/gh/prs-all.json"
  printf '[{"name":"queue:merge"}]\n' > "$FIX/gh/labels.json"; rm -f "$FIX/gh/label-create.fail"
  export SWARM_NOW=1000
  coordinator_ticked did
}
# A coordinator tick that just ran, in the given mode: it owns the fixer's start.
coordinator_ticked() { mkdir -p "$C"; printf '{"mode":"%s","epoch":%s}\n' "$1" "$(date +%s)" > "$C/capacity.json"; }
# pr <n> <sha> <labels-csv|-> <auto 1|0> <check:CONCLUSION…>  — appended to the open list
pr() {
  local n=$1 sha=$2 lab=$3 auto=$4; shift 4
  local checks; checks=$(printf '%s\n' "$@" | jq -R 'select(length > 0) | split(":") as $p
      | if $p[1] == "PENDING" then {__typename:"CheckRun", name:$p[0], status:"IN_PROGRESS", conclusion:null}
        else {__typename:"CheckRun", name:$p[0], status:"COMPLETED", conclusion:$p[1],
              detailsUrl:("https://github.com/acme/widgets/actions/runs/7" + ($p[2] // "0") + "/job/8" + ($p[2] // "0"))} end' | jq -s .)
  jq --argjson n "$n" --arg sha "$sha" --arg lab "$lab" --argjson auto "$auto" --argjson c "$checks" \
    '. + [{number:$n, headRefName:("tkt-" + ($n|tostring|.[0:3]) + "1-work"), headRefOid:$sha, isDraft:false,
           baseRefName:"develop", mergeable:"MERGEABLE", mergeStateStatus:"CLEAN",
           labels:(if $lab == "-" then [] else ($lab | split(",") | map({name:.})) end),
           autoMergeRequest:(if $auto == 1 then {mergeMethod:"SQUASH"} else null end),
           statusCheckRollup:$c}]' "$FIX/gh/prs-all.json" > "$FIX/gh/p.json" && mv "$FIX/gh/p.json" "$FIX/gh/prs-all.json"
}
set_pr() { jq --argjson n "$1" "map(if .number == \$n then $2 else . end)" "$FIX/gh/prs-all.json" > "$FIX/gh/p.json" && mv "$FIX/gh/p.json" "$FIX/gh/prs-all.json"; }
drop_pr() { jq --argjson n "$1" 'map(select(.number != $n))' "$FIX/gh/prs-all.json" > "$FIX/gh/p.json" && mv "$FIX/gh/p.json" "$FIX/gh/prs-all.json"; }
# compare <base> <head> <behind_by> [files-csv] [commits-csv] — commits: 2 a merge of
# the PR's own, 1 a commit of its own, t a trunk commit a merge brought in; the PR's
# own are added to its develop...<head> diff, as GitHub lists them.
compare() {
  local f="$FIX/gh/api-repos_acme_widgets_compare_$1...$2.json" own="$FIX/gh/api-repos_acme_widgets_compare_develop...$2.json"
  jq -n --argjson b "$3" --arg f "${4:-}" --arg c "${5:-}" \
    '{behind_by:$b, files:($f | split(",") | map(select(length > 0) | {filename:.})),
      commits:($c | split(",") | map(select(length > 0)) | to_entries
               | map(.key as $i | .value as $v
                 | if $v == "t" then {sha:"t\($i)", parents:[{sha:"p"}]}
                   else {sha:"o\($i)", parents:[range($v | tonumber) | {sha:"p"}]} end))}' > "$f"
  if [ "$1" != develop ] && [ -f "$own" ]; then
    jq --slurpfile s "$f" '.commits += [$s[0].commits[] | select(.sha | startswith("o"))]' "$own" > "$own.n" && mv "$own.n" "$own"
  fi
}
lane() { bash "$L" 2>&1; }
live() { MERGE_LANE_SHADOW=0 bash "$L" 2>&1; }
merges() { grep -E '^pr merge [0-9]+ ' "$GH_LOG" | grep -v -- '--disable-auto' | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }
updates() { grep -E '^api .*update-branch' "$GH_LOG" | sed -E 's#.*/pulls/([0-9]+)/update-branch.*#\1#' | tr '\n' ' ' | sed 's/ $//'; }
writes() { grep -E '^pr (merge|edit|comment)|^api .*-X|^run rerun|^issue edit' "$GH_LOG"; }
spawned() { cut -f1 "$SPAWNS" | tr '\n' ' ' | sed 's/ $//'; }
# The lane starts nothing itself: a fixer is a repair entry the coordinator tick starts.
fixers() { jq -r '[.tickets[]? | select(.class == "repair") | .n] | join(" ")' "$C/queue.json" 2>/dev/null; }
fixer_notes() { jq -r '.tickets[]?.note' "$C/queue.json" 2>/dev/null; }

echo "--- shadow is the default, and it writes nothing ---"
fresh; pr 21 s21 - 1 build:SUCCESS lint:SUCCESS; compare develop s21 0
out=$(lane)
want "nothing written to the forge"         "" "$(writes)"
want_in "it says it would merge"            'would merge #21' "$out"
want_in "the act is logged as would"        'would	merge	21' "$(cat "$C/actions.log")"
fresh; pr 22 s22 - 1 build:FAILURE lint:SUCCESS; compare develop s22 0
lane >/dev/null
want "shadow spawns no fixer"               "" "$(spawned)"
want "and queues none"                       "" "$(fixers)"
want "shadow tells the owner nothing"       "" "$(cat "$FIX/notify.log")"

echo "--- project facts come from harness.json, refused by key name ---"
fresh; pr 21 s21 - 1 build:SUCCESS lint:SUCCESS; compare develop s21 0
cp "$HARNESS_CFG_PATH" "$FIX/cfg.bak"
cfg 'del(.merge.method)'
out=$(live); rc=$?
want "no merge method: refused"             "1" "$rc"
want_in "and the key is named"              'merge\.method' "$out"
want "and nothing merged"                   "" "$(merges)"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"; cfg 'del(.gates.requiredChecks)'
out=$(live); rc=$?
want "no required checks: refused"          "1" "$rc"
want_in "and the key is named"              'gates\.requiredChecks' "$out"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"; cfg '.merge.method = "rebase"'
: > "$GH_LOG"; live >/dev/null
want_in "the configured method is the one used" '^pr merge 21 .*--rebase' "$(cat "$GH_LOG")"
want_in "and only on the head it checked"   '^pr merge 21 .*--match-head-commit s21' "$(cat "$GH_LOG")"
cp "$FIX/cfg.bak" "$HARNESS_CFG_PATH"

echo "--- candidates: approved, armed or labelled, not draft, on the trunk ---"
fresh
pr 31 s31 - 1 build:PENDING; pr 32 s32 queue:merge 0 build:PENDING; pr 33 s33 - 0 build:PENDING
pr 34 s34 needs:human-approval 1 build:PENDING; pr 35 s35 - 1 build:PENDING; pr 36 s36 - 1 build:PENDING
set_pr 35 '.isDraft = true'; set_pr 36 '.baseRefName = "main"'
for n in 31 32 33 34 35 36; do compare develop s$n 0; done
live >/dev/null
want "the lane is the armed and the labelled" "31 32" "$(jq -r '.order | map(tostring) | join(" ")' "$C/lane.did.json")"
want_in "an armed PR is labelled before its auto-merge is disarmed" '^pr edit 31 .*--add-label queue:merge' "$(cat "$GH_LOG")"
want_in "auto-merge is disarmed: the lane does the merge" '^pr merge 31 .*--disable-auto' "$(cat "$GH_LOG")"
want_not_in "a held PR is not touched"      '^pr (merge|edit) 34 ' "$(cat "$GH_LOG")"
first_label=$(grep -nE '^pr edit 31 .*--add-label' "$GH_LOG" | cut -d: -f1); first_disarm=$(grep -nE '^pr merge 31 .*--disable-auto' "$GH_LOG" | cut -d: -f1)
want "label first, so membership is never lost" "yes" "$([ "${first_label:-99}" -lt "${first_disarm:-0}" ] && echo yes || echo no)"

echo "--- order: P0 first, then the oldest approval, then the lowest number ---"
fresh
pr 40 s40 - 1 build:PENDING; pr 50 s50 - 1 build:PENDING
compare develop s40 0; compare develop s50 0
live >/dev/null
export SWARM_NOW=2000
pr 20 s20 - 1 build:PENDING; compare develop s20 0
live >/dev/null
want "a later approval waits behind an earlier one" "40 50 20" "$(jq -r '.order | map(tostring) | join(" ")' "$C/lane.did.json")"
drop_pr 40; export SWARM_NOW=3000
live >/dev/null
want "the head leaves; the oldest approval is next" "50" "$(jq -r '.head.pr' "$C/lane.did.json")"
fresh
pr 61 s61 - 1 build:PENDING; pr 62 s62 P0 1 build:PENDING
compare develop s61 0; compare develop s62 0
live >/dev/null
want "an owner-flagged P0 goes first"      "62" "$(jq -r '.head.pr' "$C/lane.did.json")"
want_in "the status line names the head"   'head #62' "$(cat "$C/lane.status")"
want_in "and what it is waiting for"       'waiting for checks: build, lint' "$(cat "$C/lane.status")"

echo "--- one at a time: the PR in flight stays head, one merge per pass ---"
fresh
pr 11 s11 - 1 build:SUCCESS lint:SUCCESS; compare develop s11 2
pr 12 s12 - 1 build:SUCCESS lint:SUCCESS; compare develop s12 0
live >/dev/null
want "the behind head is updated"          "11" "$(updates)"
want_in "against the head it read"         'update-branch .*expected_head_sha=s11' "$(cat "$GH_LOG")"
want "and nothing merges past it"          "" "$(merges)"
: > "$GH_LOG"
set_pr 11 '.headRefOid = "s11b" | .statusCheckRollup = [{__typename:"CheckRun", name:"build", status:"IN_PROGRESS", conclusion:null}]'
compare develop s11b 0; set_pr 12 '.labels = [{name:"P0"}]'
live >/dev/null
want "a P0 arriving does not jump a PR in flight" "11" "$(jq -r '.head.pr' "$C/lane.did.json")"
want "the green one behind it does not merge" "" "$(merges)"
: > "$GH_LOG"
set_pr 11 '.statusCheckRollup = [{__typename:"CheckRun", name:"build", status:"COMPLETED", conclusion:"SUCCESS"}, {__typename:"CheckRun", name:"lint", status:"COMPLETED", conclusion:"SUCCESS"}]'
live >/dev/null
want "the head merges when green, alone"   "11" "$(merges)"
mkdir -p "$C/lane.lock"; echo "$$" > "$C/lane.lock/pid"
LC_ALL=C TZ=UTC ps -o lstart= -p "$$" | tr -s ' ' | sed 's/^ *//;s/ *$//' > "$C/lane.lock/started"
: > "$GH_LOG"; drop_pr 11
out=$(live)
want "a running lane blocks a second one"  "" "$(writes)"
want_in "and says so"                      'another lane \(pid [0-9]+\) is running' "$out"
rm -rf "$C/lane.lock"

echo "--- a real conflict leaves the lane and gets a fixer; the lane never resolves it ---"
fresh; fix_issue 701 OPEN "status:in-review"
pr 70 s70 - 1 build:SUCCESS lint:SUCCESS; compare develop s70 3
printf 'gh: merge conflict between base and head (HTTP 422)\n' > "$FIX/gh/update-70.fail"
out=$(live)
want "nothing merged"                      "" "$(merges)"
want_in "it leaves the lane"               '^pr edit 70 .*--remove-label queue:merge' "$(cat "$GH_LOG")"
want_in "the PR is told why"               '^pr comment 70 .*conflict' "$(cat "$GH_LOG")"
want "a fixer is queued for its ticket"    "701" "$(fixers)"
want "the lane spawns nothing itself"      "" "$(spawned)"
want_in "and briefed on the conflict"      'conflict' "$(fixer_notes)"
rm -f "$C/queue.json"; live >/dev/null
want "the same head is not re-admitted or re-fixed" "" "$(fixers)"
fresh; fix_issue 711 OPEN "status:in-review"
pr 71 s71 - 1 build:SUCCESS lint:SUCCESS; compare develop s71 0; set_pr 71 '.mergeable = "CONFLICTING"'
live >/dev/null
want "a PR GitHub calls conflicting is out too" "711" "$(fixers)"
want "and not merged"                      "" "$(merges)"
fresh; fix_issue 701 OPEN "status:in-review"
pr 70 s70 - 1 build:SUCCESS lint:SUCCESS; compare develop s70 3
printf 'gh: merge conflict between base and head (HTTP 422)\n' > "$FIX/gh/update-70.fail"
printf '{"run_id":"claim-9-x","ticket":"9","child_pid":%s}\n' "$$" > "$STATE/runs/claim-9-x.json"
live >/dev/null
want "with a run already live, still no direct spawn" "" "$(spawned)"
want "the fixer is queued as a repair"     "701 repair" "$(jq -r '.tickets[] | "\(.n) \(.class)"' "$C/queue.json")"

echo "--- with no live coordinator, the lane starts its own fixer when the machine has room ---"
fresh; fix_issue 701 OPEN "status:in-review"; rm -f "$C/capacity.json"
pr 70 s70 - 1 build:SUCCESS lint:SUCCESS; compare develop s70 3
printf 'gh: merge conflict between base and head (HTTP 422)\n' > "$FIX/gh/update-70.fail"
out=$(SWARM_FREE_MEM_GB=16 live)
want "no coordinator tick on record: it spawns the fixer" "701" "$(spawned)"
want "and queues nothing"                  "" "$(fixers)"
want "the coordinator's record has its class" "repair" "$(cut -f3 "$C/run-classes.tsv" 2>/dev/null | tail -1)"
fresh; fix_issue 701 OPEN "status:in-review"; coordinator_ticked would
pr 70 s70 - 1 build:SUCCESS lint:SUCCESS; compare develop s70 3
printf 'gh: merge conflict between base and head (HTTP 422)\n' > "$FIX/gh/update-70.fail"
SWARM_FREE_MEM_GB=16 live >/dev/null
want "a coordinator in shadow does not own it either" "701" "$(spawned)"
fresh; fix_issue 701 OPEN "status:in-review"; rm -f "$C/capacity.json"
pr 70 s70 - 1 build:SUCCESS lint:SUCCESS; compare develop s70 3
printf 'gh: merge conflict between base and head (HTTP 422)\n' > "$FIX/gh/update-70.fail"
out=$(SWARM_FREE_MEM_GB=2 live)
want "no room: it queues instead"          "701" "$(fixers)"
want "and spawns nothing"                  "" "$(spawned)"

echo "--- a red required check leaves the lane, named; an unrequired red does not ---"
fresh; fix_issue 801 OPEN "status:in-review"
pr 80 s80 - 1 build:FAILURE lint:SUCCESS; compare develop s80 0
out=$(live)
want "nothing merged"                      "" "$(merges)"
want_in "the PR is told which check"       "^pr comment 80 .*build" "$(cat "$GH_LOG")"
want "a fixer is queued"                   "801" "$(fixers)"
want_in "and told which check"             'build' "$(fixer_notes)"
want_not_in "a real failure is not re-run" '^run rerun' "$(cat "$GH_LOG")"
fresh
pr 81 s81 - 1 build:SUCCESS lint:SUCCESS deploy-preview:FAILURE; compare develop s81 0
live >/dev/null
want "a red check nobody requires does not block" "81" "$(merges)"
fresh
pr 82 s82 - 1 build:SUCCESS; compare develop s82 0
out=$(live)
want "a required check that never reported is not green" "" "$(merges)"
want_in "it waits for it by name"          'waiting for checks: lint' "$(cat "$C/lane.status")"

echo "--- a flake is re-run once; a second flake is a failure ---"
fresh; fix_issue 901 OPEN "status:in-review"
pr 90 s90 - 1 build:TIMED_OUT:1 lint:SUCCESS; compare develop s90 0
live >/dev/null
want_in "a timed-out check is re-run"      '^run rerun 71 .*--failed' "$(cat "$GH_LOG")"
want "and not taken out"                   "" "$(fixers)"
: > "$GH_LOG"; live >/dev/null
want_not_in "the stale result is not a second failure" '^run rerun|^pr edit 90 .*--remove-label' "$(cat "$GH_LOG")"
set_pr 90 '.statusCheckRollup[0].detailsUrl = "https://github.com/acme/widgets/actions/runs/71/job/82"'
: > "$GH_LOG"; live >/dev/null
want_not_in "never a second re-run"        '^run rerun' "$(cat "$GH_LOG")"
want "a second flake leaves the lane"      "901" "$(fixers)"
fresh
pr 91 s91 - 1 build:FAILURE:3 lint:SUCCESS; compare develop s91 0
printf '[{"message":"The runner has received a shutdown signal."}]\n' > "$FIX/gh/api-repos_acme_widgets_check-runs_83_annotations.json"
live >/dev/null
want_in "a lost runner is a flake, re-run" '^run rerun 73 ' "$(cat "$GH_LOG")"

echo "--- a hold comes off only after a develop-only update that left the screens alone ---"
hold_setup() { # the lane updated aaaa600 -> bbbb600; the gate put the hold back on bbbb600
  fresh; fix_issue 601 OPEN "status:in-review"
  pr 60 aaaa600 - 1 build:SUCCESS lint:SUCCESS; compare develop aaaa600 1
  live >/dev/null
  set_pr 60 '.headRefOid = "bbbb600" | .labels = [{name:"queue:merge"}, {name:"needs:human-approval"}] | .autoMergeRequest = null'
  compare develop bbbb600 0 "apps/web/page.tsx,lib/api.ts"
  : > "$GH_LOG"
}
hold_setup; compare aaaa600 bbbb600 0 "lib/server.ts" "t,t,2"
out=$(live)
want_in "the hold is cleared"              '^pr edit 60 .*--remove-label needs:human-approval' "$(cat "$GH_LOG")"
want_in "and the reason is recorded"       '^pr comment 60 .*develop-only update' "$(cat "$GH_LOG")"
want "it stays in the lane"                "60" "$(jq -r '.head.pr' "$C/lane.did.json")"
hold_setup; compare aaaa600 bbbb600 0 "lib/server.ts" "2,1"
live >/dev/null
want_not_in "a commit of its own: the hold stays" 'remove-label needs:human-approval' "$(cat "$GH_LOG")"
want_in "and it is logged for the sign-off batch" 'lane-hold:60:.*PR #60' "$(cat "$C/agent-work.log")"
want "not pinged on its own"               "" "$(cat "$FIX/notify.log")"
want "and it leaves the lane"              "none" "$(jq -r '.head.pr // "none"' "$C/lane.did.json")"
want_not_in "keeping its label, so a sign-off brings it straight back" '^pr edit 60 .*--remove-label queue:merge' "$(cat "$GH_LOG")"
hold_setup; compare aaaa600 bbbb600 0 "apps/web/page.tsx" "2"
live >/dev/null
want_not_in "the update touched its screen: the hold stays" 'remove-label needs:human-approval' "$(cat "$GH_LOG")"
want_in "and it is logged for the sign-off batch" 'lane-hold:60:.*PR #60' "$(cat "$C/agent-work.log")"
want "not pinged on its own"               "" "$(cat "$FIX/notify.log")"
hold_setup; compare aaaa600 bbbb600 0 "lib/api.ts" "2"
live >/dev/null
want_in "a shared file that is no screen does not hold it" 'remove-label needs:human-approval' "$(cat "$GH_LOG")"
hold_setup
live >/dev/null
want_not_in "an unreadable comparison: the hold stays" 'remove-label needs:human-approval' "$(cat "$GH_LOG")"
fresh
pr 63 s63 queue:merge 0 build:PENDING; compare develop s63 0
live >/dev/null
set_pr 63 '.headRefOid = "s63b" | .labels = [{name:"queue:merge"}, {name:"needs:human-approval"}]'
compare develop s63b 0 "apps/web/page.tsx"; compare s63 s63b 0 "lib/server.ts" "2"
: > "$GH_LOG"; live >/dev/null
want_not_in "a hold on an update the lane did not make is never touched" 'remove-label needs:human-approval' "$(cat "$GH_LOG")"
want "and it waits out of line for sign-off" "none" "$(jq -r '.head.pr // "none"' "$C/lane.did.json")"
hold_setup; compare aaaa600 bbbb600 0 "lib/server.ts" "2"
out=$(lane)
want_not_in "shadow clears no hold"        '^pr (edit|comment) 60' "$(cat "$GH_LOG")"

echo "--- the lane label: checked every pass, created live when missing ---"
fresh; pr 31 s31 - 1 build:PENDING; compare develop s31 0
printf '[{"name":"queue:merged-elsewhere"}]\n' > "$FIX/gh/labels.json"
out=$(live)
want_in "a missing label is created"       '^label create queue:merge .*--color' "$(cat "$GH_LOG")"
want_in "and the creation is logged"       'created the lane label queue:merge' "$out"
made=$(grep -nE '^label create' "$GH_LOG" | cut -d: -f1); added=$(grep -nE '^pr edit 31 .*--add-label queue:merge' "$GH_LOG" | cut -d: -f1)
want "created before any PR is labelled"   "yes" "$([ "${made:-99}" -lt "${added:-0}" ] && echo yes || echo no)"
want_not_in "so the PR is labelled, not left out" 'could not label' "$out"
fresh; pr 31 s31 - 1 build:PENDING; compare develop s31 0
printf '[]\n' > "$FIX/gh/labels.json"
out=$(lane)
want_in "shadow says it would create it"   'would create the lane label queue:merge' "$out"
want_in "and logs the act as would"        'would	label-create	-' "$(cat "$C/actions.log")"
want_not_in "and creates nothing"          '^label create' "$(cat "$GH_LOG")"
fresh; pr 31 s31 - 1 build:PENDING; compare develop s31 0
out=$(live)
want_not_in "a label that exists is not created again" '^label create' "$(cat "$GH_LOG")"
want_not_in "and nothing is said about it" 'lane label' "$out"
fresh; pr 31 s31 - 1 build:PENDING; compare develop s31 0
printf '[]\n' > "$FIX/gh/labels.json"; : > "$FIX/gh/label-create.fail"
out=$(live)
want_in "a label that cannot be created is said" 'could not be created' "$out"
want_not_in "and auto-merge stays armed"   '^pr merge 31 .*--disable-auto' "$(cat "$GH_LOG")"
fresh; pr 31 s31 - 1 build:PENDING; compare develop s31 0
rm -f "$FIX/gh/labels.json"
out=$(live)
want_in "an unreadable label list is said, not guessed" 'could not read whether the label queue:merge exists' "$out"
want_not_in "and nothing is created on a guess" '^label create' "$(cat "$GH_LOG")"

echo "--- a swarm hold stops the lane acting ---"
fresh; pr 21 s21 - 1 build:SUCCESS lint:SUCCESS; compare develop s21 0
printf 'owner said stop\n' > "$STATE/swarm/HOLD"
out=$(live)
want "held: nothing merges"                "" "$(merges)"
want_in "and it says why"                  'held — owner said stop' "$out"

exit $FAILED
