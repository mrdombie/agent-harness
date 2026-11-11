#!/usr/bin/env bash
# gh-budget.test.sh — one token's hourly allowance is shared by every machine and
# session, and running out of it must cost a wait, never a wrong answer.
#   - under 10% of REST or GraphQL a read that is not essential waits for the reset
#     (and says so); an essential read, and every write, goes through;
#   - a rate-limit refusal is exit GH_WAIT (75) with a message, and neither the
#     coordinator's open-PR read nor the driver's PR lookup reads it as "none";
#   - the per-tick PR read costs the same number of requests for 5 open PRs as for 40,
#     and none of them REST;
#   - the reading is kept per token and never names the token;
#   - the calls log keeps one row a call, whatever an argument holds.
# On 2026-11-11 REST ran at 82 requests a minute, 4,920 an hour of 5,000, and every
# reader went blind for the end of each hour.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
FIX=$(mktemp -d); on_exit_keep_status 'rm -rf "$FIX"'
FAILED=0
want()    { if [ "$2" = "$3" ]; then echo "  ok  $1"; else echo "  FAIL $1: wanted '$2', got '$3'"; FAILED=1; fi; }
want_in() { case "$3" in *"$2"*) echo "  ok  $1" ;; *) echo "  FAIL $1: wanted '$2' in '$3'"; FAILED=1 ;; esac; }

mkdir -p "$FIX/bin" "$FIX/state"
# The forge: records its argv; $FIX/rl.json is what `api rate_limit` answers (absent: it
# fails); $FIX/refuse present: every other call is refused as GitHub refuses a spent token.
cat > "$FIX/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" | tr '\n' ' ' >> "$FIX/gh.log"; echo >> "$FIX/gh.log"
if [ "$1 $2" = "api rate_limit" ]; then [ -s "$FIX/rl.json" ] || exit 1; cat "$FIX/rl.json"; exit 0; fi
if [ -f "$FIX/refuse" ]; then
  echo '{"message":"API rate limit exceeded for user ID 1.","documentation_url":"https://docs.github.com/rest/overview/rate-limits-for-the-rest-api","status":"403"}'
  echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2; exit 1
fi
case "$*" in "api graphql "*OpenPullRequests*) exec bash "$GH_OPEN_PRS_PAGE" "$FIX/prs.json" "$@" ;; esac
case "$1 $2" in
  "pr list") echo '[{"number":7}]' ;;
  "pr view") echo '{"number":7}' ;;
  "issue comment") echo "https://github.com/acme/widgets/issues/7#issuecomment-1" ;;
  *) echo '{}' ;;
esac
SH
# Sleep is recorded, never taken.
cat > "$FIX/bin/sleep" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$FIX/sleep.log"
SH
chmod +x "$FIX/bin/gh" "$FIX/bin/sleep"
export FIX PATH="$FIX/bin:$PATH" SWARM_GH="$FIX/bin/gh" GH_REPO=acme/widgets REPO_SLUG=acme/widgets
export GH_BACKOFF_FILE="$FIX/state/gh-backoff" GH_ALLOWANCE_FILE="$FIX/state/gh-allowance" GH_FLEET_FILE="$FIX/state/fleet.json"
export GH_OPEN_PRS_PAGE="$HERE/fixtures/gh-open-prs-page.sh" GH_PRS_RETRY_SEC=0 GH_CALLER=some-reader
unset GH_TOKEN GITHUB_TOKEN GH_ESSENTIAL GH_ESSENTIAL_CALLERS GH_BUDGET_WAIT_MAX_SEC GH_BUDGET_CACHE_SEC
. "$HERE/gh-batch.sh" || exit 1

NOW=$(date +%s); export SWARM_NOW="$NOW"   # one clock for the whole suite
rl() { # <core remaining> <graphql remaining> [reset-in-sec]
  printf '{"resources":{"core":{"limit":5000,"remaining":%s,"used":%s,"reset":%s},"graphql":{"limit":5000,"remaining":%s,"used":%s,"reset":%s}}}\n' \
    "$1" $(( 5000 - $1 )) $(( NOW + ${3:-600} )) "$2" $(( 5000 - $2 )) $(( NOW + ${3:-600} )) > "$FIX/rl.json"
}
fresh() { rm -rf "$FIX/state" "$FIX/refuse" "$FIX/rl.json"; mkdir -p "$FIX/state"; : > "$FIX/gh.log"; : > "$FIX/sleep.log"; }
calls() { grep -cv '^api rate_limit' "$FIX/gh.log"; }           # requests that spend the allowance
asked() { grep -c '^api rate_limit' "$FIX/gh.log"; }            # free readings of it
slept() { awk '{ s += $1 } END { print s + 0 }' "$FIX/sleep.log"; }

echo "--- a healthy allowance: nothing waits, and the reading is asked once a minute ---"
fresh; rl 4000 4000
out=$(gh_call pr view 7 --json number 2>"$FIX/err"); rc=$?
want "the read answers"                               "0" "$rc"
want "with GitHub's answer"                           '{"number":7}' "$out"
gh_call pr view 7 --json number >/dev/null 2>&1; gh_call pr list --json number >/dev/null 2>&1
want "three reads reached GitHub"                     "3" "$(calls)"
want "and the allowance was asked once for all three" "1" "$(asked)"
want "nothing slept"                                  "0" "$(slept)"

echo "--- under 10% of REST: a reader waits for the reset, and says so ---"
fresh; rl 499 4000 600
out=$(gh_call pr view 7 --json number 2>"$FIX/err"); rc=$?
want "the read is not failed"                         "0" "$rc"
want "it answers once the wait is over"               '{"number":7}' "$out"
want "having slept to the reset"                      "601" "$(slept)"
want_in "one line names how long"                     "waiting 601s for the reset" "$(cat "$FIX/err")"
want_in "and which allowance"                         "REST 499 of 5000 left" "$(cat "$FIX/err")"

echo "--- under 10% of GraphQL alone holds a reader too ---"
fresh; rl 4000 100 300
gh_call pr list --json number >/dev/null 2>"$FIX/err"; rc=$?
want "the read is not failed"                         "0" "$rc"
want "having slept to GraphQL's reset"                "301" "$(slept)"
want_in "and the line says GraphQL"                   "GraphQL 100 of 5000 left" "$(cat "$FIX/err")"

echo "--- an essential read goes through at once ---"
fresh; rl 499 4000 600
out=$(GH_ESSENTIAL=1 gh_call pr view 7 --json number 2>/dev/null); rc=$?
want "it answers"                                     "0:{\"number\":7}" "$rc:$out"
want "without sleeping"                               "0" "$(slept)"
out=$(GH_CALLER=coordinator-tick gh_call pr view 7 --json number 2>/dev/null); rc=$?
want "the coordinator's tick is essential by name"    "0:0" "$rc:$(slept)"
want "both reached GitHub"                            "2" "$(calls)"

echo "--- a write is never held ---"
fresh; rl 10 10 600
gh_call issue comment 7 --repo acme/widgets --body "done" >/dev/null 2>&1; rc=$?
want "the comment is posted"                          "0" "$rc"
gh_call api repos/acme/widgets/issues/7/labels -f 'labels[]=x' >/dev/null 2>&1
gh_call api -X PATCH repos/acme/widgets/issues/7 -f state=closed >/dev/null 2>&1
want "three writes reached GitHub"                    "3" "$(calls)"
want "and none slept"                                 "0" "$(slept)"

echo "--- a reset further off than the caller waits is the wait code, not a call ---"
fresh; rl 499 4000 3000
out=$(GH_BUDGET_WAIT_MAX_SEC=60 gh_call pr list --json number 2>"$FIX/err"); rc=$?
want "the exit is GH_WAIT"                            "75" "$rc"
want "nothing on stdout to read as an answer"         "" "$out"
want "the call was never sent"                        "0" "$(calls)"
want_in "the message says wait"                       "wait — GitHub's hourly allowance is under 10%" "$(cat "$FIX/err")"
want_in "and that it is not an empty answer"          "not an empty answer" "$(cat "$FIX/err")"

echo "--- a rate-limit 403 is the wait code ---"
fresh; rl 0 4000 600; touch "$FIX/refuse"
out=$(GH_ESSENTIAL=1 gh_call api repos/acme/widgets/pulls/7 2>"$FIX/err"); rc=$?
want "the refusal exits GH_WAIT, not gh's own 1"      "75" "$rc"
want_in "GitHub's refusal is passed on"               "API rate limit exceeded" "$(cat "$FIX/err")"
want_in "with the wait message"                       "wait — GitHub refused this call for its rate limit" "$(cat "$FIX/err")"
want "and a backoff every caller shares has started"  "0" "$(gh_backoff_active >/dev/null && echo 0 || echo 1)"
rm -f "$GH_BACKOFF_FILE"
out=$(gh_read "pull request #7" api repos/acme/widgets/pulls/7 2>"$FIX/err"); rc=$?
want "gh_read answers unknown, never the error body"  "69:" "$rc:$out"

echo "--- the coordinator's open-PR read: a refusal is a wait, never an empty list ---"
fresh; rl 0 0 600; touch "$FIX/refuse"
out=$(GH_CALLER=coordinator-tick gh_open_prs 0 2>/dev/null); rc=$?
want "the read exits GH_WAIT"                         "75" "$rc"
want "and prints no list at all"                      "" "$out"
want "no shared copy was written from it"             "absent" "$([ -e "$(gh_prs_file)" ] && echo present || echo absent)"

echo "--- the driver's PR lookup waits out a spent allowance and then answers ---"
fresh; rl 499 4000 3000
# One try only: the ordinary retry must not be what rescues the read.
driver_gh_read_under_test() { ( export GH_BUDGET_WAIT_MAX_SEC=60 DRIVER_LOOKUP_RETRY_SEC=0 DRIVER_LOOKUP_TRIES=1
  # the allowance comes back once the driver has slept twice
  sleep() { echo "$1" >> "$FIX/sleep.log"; [ "$(wc -l < "$FIX/sleep.log")" -lt 2 ] || { rl 4000 4000; rm -f "$(gh_budget_file)"; }; }
  eval "$(sed -n '/^driver_gh_read() {/,/^}/p' "$HERE/../driver/driver-env.sh")"
  driver_gh_read gh_call pr list --repo acme/widgets --head tkt-7/x --state open --json number -q '.[0].number // empty' ) }
out=$(driver_gh_read_under_test 2>/dev/null); rc=$?
want "the lookup answers in the end"                  "0" "$rc"
want_in "with the pull request, not 'none'"           '"number":7' "$out"
want "after two waits, each bounded at the caller's 60s" "60 60" "$(tr '\n' ' ' < "$FIX/sleep.log" | sed 's/ $//')"
want "and one request, sent only after them"          "1" "$(calls)"

echo "--- the per-tick PR read costs the same for 5 open PRs as for 40 ---"
prs() { jq -n --argjson n "$1" '[range(0; $n) as $i | {number: (1000 - $i), title: "PR \($i)", headRefName: "tkt-\($i)/x", headRefOid: "sha\($i)",
  baseRefName: "develop", isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", updatedAt: "2026-11-11T10:00:00Z", body: "",
  labels: [{id: "L", name: "x", description: "", color: "B60205"}], closingIssuesReferences: [],
  statusCheckRollup: [{__typename: "CheckRun", completedAt: "2026-11-11T11:01:43Z", conclusion: "FAILURE", detailsUrl: "https://x/\($i)", name: "build", startedAt: "2026-11-11T11:01:00Z", status: "COMPLETED", workflowName: "CI"}]}]' > "$FIX/prs.json"; }
tick_read() { fresh; rl 4000 4000; prs "$1"; GH_CALLER=coordinator-tick gh_open_prs 0 > "$FIX/out.json" 2>/dev/null; }
tick_read 5;  rc5=$?;  n5=$(calls);  got5=$(jq 'length' "$FIX/out.json" 2>/dev/null)
tick_read 40; rc40=$?; n40=$(calls); got40=$(jq 'length' "$FIX/out.json" 2>/dev/null)
want "5 open PRs are read"                            "0:5" "$rc5:$got5"
want "40 open PRs are read"                           "0:40" "$rc40:$got40"
want "in one request for 5"                           "1" "$n5"
want "and the same count for 40"                      "$n5" "$n40"
want "none of them a REST request"                    "0" "$(grep -v '^api rate_limit' "$FIX/gh.log" | grep -cv '^api graphql ')"
want "each PR carries its checks, labels and merge state" "40" "$(jq '[.[] | select(.statusCheckRollup[0].conclusion == "FAILURE" and .labels[0].name == "x" and .mergeable == "MERGEABLE" and .mergeStateStatus == "CLEAN" and (.headRefOid | startswith("sha")) and .isDraft == false)] | length' "$FIX/out.json")"

echo "--- the reading is kept per token, and never names it ---"
fresh; rl 4000 4000
gh_budget_read >/dev/null
( export GH_TOKEN=ghp_exampletokenAAAAAA111111; gh_budget_read >/dev/null )
( export GH_TOKEN=ghp_exampletokenBBBBBB222222; gh_budget_read >/dev/null; gh_budget_read >/dev/null )
want "three tokens, three readings"                   "3" "$(ls "$FIX/state" | grep -c '^gh-budget\.')"
want "and each was asked once"                        "3" "$(asked)"
want "no file name carries a token's characters"      "0" "$(ls "$FIX/state" | grep -cE '111111|222222|ghp_')"
want "nor does any file's content"                    "0" "$(cat "$FIX/state"/gh-budget.* | grep -cE '111111|222222|ghp_')"
want "the stored login is its own reading"            "present" "$([ -s "$FIX/state/gh-budget.login" ] && echo present || echo absent)"

echo "--- a reading GitHub cannot give holds nobody, and is asked once a minute ---"
fresh
gh_call pr view 7 --json number >/dev/null 2>&1; rc=$?; gh_call pr view 7 --json number >/dev/null 2>&1
want "the read goes through"                          "0" "$rc"
want "nothing slept"                                  "0" "$(slept)"
want "and the allowance was asked once, not per call" "1" "$(asked)"

echo "--- the calls log keeps one row a call ---"
fresh; rl 4000 4000
gh_call api "repos/acme/widgets/commits/aaa
bbb
ccc/check-runs" >/dev/null 2>&1
want "an argument with newlines is one row"           "1" "$(wc -l < "$(gh_calls_file)" | tr -d ' ')"
printf 'deadbeef/check-runs\n9zz\n' >> "$(gh_calls_file)"
want "a row with no epoch is not counted"             "some-reader 1" "$(gh_calls_tally 0)"
gh_calls_trim
want "and the trim drops it"                          "1" "$(wc -l < "$(gh_calls_file)" | tr -d ' ')"

echo "--- the base's check runs are asked one commit a request, whatever IFS the caller reads under ---"
fresh; : > "$FIX/base.log"; mkdir -p "$FIX/cache"
( swarm_gh() { printf '%s\n' "$*" | tr '\n' '|' >> "$FIX/base.log"; echo >> "$FIX/base.log"
    case "$2" in *"/commits?sha="*) printf '[{"sha":"aaa"},{"sha":"bbb"},{"sha":"ccc"}]' ;; *) printf '{"check_runs":[]}' ;; esac; }
  REPO_SLUG=acme/widgets; REBUILD_BASE_DEPTH=3; CHECK_NEWEST_JQ='def newest_runs: .;'
  eval "$(sed -n '/^_rebuild_base_runs() {/,/^}/p; /^_rebuild_base_latest_done() {/,/^}/p' "$HERE/rebuild.sh")"
  # as rebuild_pass reads rebuild_pr_state: bash 3.2 hands the read's IFS to the substitution
  IFS=$'\t' read -r _a _b <<<"$(_rebuild_base_latest_done develop build "$FIX/cache"; echo x)" )
want "three commits, three check-run requests"        "3" "$(grep -c 'check-runs' "$FIX/base.log")"
want "none of them names more than one commit"        "0" "$(grep 'check-runs' "$FIX/base.log" | grep -c '|.*|')"
want_in "each names its own"                          "commits/bbb/check-runs" "$(cat "$FIX/base.log")"

echo "--- a build step's own gh goes through the wrapper ---"
fresh; rl 4000 4000
shim_exec=$(sed -n "/^  local gh_exec='echo/,/^  cat > \"\$shim\/gh\" <<SHIM/p" "$HERE/../driver/ai-step.sh" | sed '$d')
( KIT_ROOT="$HERE/.."; real_gh="$FIX/bin/gh"; eval "${shim_exec//local /}"
  printf '#!/usr/bin/env bash\n%s\n' "$gh_exec" > "$FIX/bin/step-gh"; chmod +x "$FIX/bin/step-gh" )
out=$(env -u GH_CALLER -u SWARM_GH GH_BACKOFF_FILE=/nonexistent/elsewhere "$FIX/bin/step-gh" pr view 7 --json number 2>/dev/null); rc=$?
want "the step's read answers"                        "0:{\"number\":7}" "$rc:$out"
want "and is counted, under the step's own name"      "builder-step 1" "$(gh_calls_tally 0)"
: > "$FIX/sleep.log"; rm -f "$FIX/state"/gh-budget.*; rl 499 4000 3000
out=$("$FIX/bin/step-gh" pr view 7 --json number 2>"$FIX/err"); rc=$?
want "under 10% the step is told to wait, at once"    "75::0" "$rc:$out:$(slept)"
want_in "in words a model cannot read as no answer"   "not an empty answer" "$(cat "$FIX/err")"
"$FIX/bin/step-gh" issue comment 7 --body "x" >/dev/null 2>&1; rc=$?
want "its write still goes through"                   "0" "$rc"

suite_end "$FAILED"
