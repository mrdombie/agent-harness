#!/usr/bin/env bash
# api-refusal.test.sh — a session the API refused is a wait, never a skipped Skill.
# Measured 2026-11-11: a ten-minute 403 ended 10 step sessions in under a second with
# no turn and no tokens; each parked as "did not run the Skill its brief names", and
# that record is what stops a machine taking builds.
#
#   - a refusal then a session that runs: the step carries on, nothing parks;
#   - a 403 that outlasts the tries: the usage hold file names the API's status and
#     code, the ticket requeues, and the skill check's record is untouched;
#   - a refusal that is not the account's parks as a machine fault, the same record untouched;
#   - a session that ran and called no Skill still parks with the skill wording, and counts;
#   - an expired login is the host's: one call, the auth hold, a requeue, never a machine fault.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/fixture.sh"
driver_fixture; on_exit_keep_status 'rm -rf "$FIX"'
BT="$HERE/../build-ticket"
. "$HERE/../ai-step.sh" || exit 1

cat > "$FIX/queue-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX/queue.log"
SH
cat > "$FIX/wait-stub.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FIX/waits.log"
SH
export DRIVER_QUEUE="$FIX/queue-stub.sh"
export SWARM_USAGE_HOLD_FILE="$FIX/usage-hold"
export HARNESS_SKILL_CHECKS="$FIX/skill-checks.tsv"
export DRIVER_API_REFUSAL_WAIT_CMD="bash $FIX/wait-stub.sh"
export SWARM_NOW=1794402000
export SWARM_AUTH_HOLD_FILE="$FIX/auth-hold" SWARM_HOST=hostA SWARM_ACCOUNT=acct-1
CLK="$HERE/../../scripts/claim-lock.sh"
fix_brief plan superpowers:writing-plans

# The result line the CLI wrote on 2026-11-11, cut to the fields read; no init, no turn.
refused() { # [status] [code]
  jq -nc --arg s "${1-403}" --arg c "${2-oauth_not_allowed_for_organization}" \
    '{type:"result", subtype:"success", is_error:true, num_turns:1, terminal_reason:"api_error",
      result:"Claude Code can'"'"'t use your Claude subscription, usually because a payment is past due · Pay or renew at https://claude.ai/settings/billing (if you just paid, try again shortly), or use an Anthropic API key instead",
      usage:{input_tokens:0, output_tokens:0}}
     + (if $s == "" then {} else {api_error_status:($s|tonumber), api_error_code:$c, api_error_origin:"first_party"} end)'
}
# Turns ran, tokens were used, the session listed the skill, and no Skill call was made.
no_skill() {
  jq -nc '{type:"system", subtype:"init", claude_code_version:"2.1.319", tools:["Skill","Bash"], skills:["superpowers:writing-plans"]}'
  jq -nc '{type:"assistant", message:{content:[{type:"text", text:"Here is the plan."}]}}'
  jq -nc '{type:"result", subtype:"success", is_error:false, num_turns:4, result:"{\"files\":[\"a.sh\"]}",
           usage:{input_tokens:1200, output_tokens:300}}'
}
# The result line the CLI wrote on 2026-11-12 when the host's OAuth login had expired.
expired() { # [text]
  jq -nc --arg x "${1-Failed to authenticate: OAuth session expired and could not be refreshed}" \
    '{type:"result", subtype:"success", is_error:true, num_turns:1, terminal_reason:"api_error",
      result:$x, usage:{input_tokens:0, output_tokens:0}}'
}
reset_case() { # <ticket>
  rm -f "$SWARM_AUTH_HOLD_FILE" "$SWARM_USAGE_HOLD_FILE" "$FIX/queue.log" "$FIX/waits.log" "$FIX/ai/plan.then.jsonl"; : > "$GH_LOG"; fix_gh_ok
  rm -rf "$STATE/driver/$1"
  fix_issue "$1" OPEN "status:ready"
  driver_state_init "$1" --worktree "$REPO"
}
calls()  { grep -cx plan "$CLAUDE_LOG"; }
checks() { wc -l < "$HARNESS_SKILL_CHECKS" | tr -d ' '; }
nones()  { awk -F'\t' '$4 == "none"' "$HARNESS_SKILL_CHECKS" | wc -l | tr -d ' '; }
SKILL_WORDS='did not run the Skill|does not contain any of those Skill calls|ran none of the skills|did not call it'
# Two builds already read no Skill call: one more would stop this machine building.
printf '1794401000\t690\tplan\tnone\t2.1.319\t0.7.0\tloaded\tsuperpowers:writing-plans\n1794401500\t691\tplan\tnone\t2.1.319\t0.7.0\tloaded\tsuperpowers:writing-plans\n' > "$HARNESS_SKILL_CHECKS"

echo "--- the reader: the CLI's own refused result, and nothing that quotes one ---"
refused > "$FIX/r.jsonl"
r=$(driver_api_refusal "$FIX/r.jsonl"); rc=$?
want "a refused result is read as one" "0" "$rc"
want_in "it says the status, the code and the CLI's words" "^403 oauth_not_allowed_for_organization: Claude Code can.t use your Claude subscription" "$r"
if [ "${#r}" -le 245 ]; then ok "the CLI's words are cut to 200"; else bad "the CLI's words are cut to 200 — ${#r} chars"; fi
refused "" > "$FIX/r.jsonl"
want_in "no status: terminal_reason api_error alone is one" '^api_error: Claude Code' "$(driver_api_refusal "$FIX/r.jsonl")"
no_skill > "$FIX/r.jsonl"
driver_api_refusal "$FIX/r.jsonl" >/dev/null; want "a session that ran is not one" "1" "$?"
jq -nc --arg q "$(refused)" '{type:"result", subtype:"success", is_error:false, result:("the log said: " + $q)}' > "$FIX/r.jsonl"
driver_api_refusal "$FIX/r.jsonl" >/dev/null; want "an answer quoting a refusal is not one" "1" "$?"
jq -nc '{type:"result", subtype:"error_max_turns", is_error:true, result:"ran out of turns"}' > "$FIX/r.jsonl"
driver_api_refusal "$FIX/r.jsonl" >/dev/null; want "an error that is not the API's is not one" "1" "$?"

echo "--- refused, then the session runs: the step carries on, nothing parks ---"
reset_case 701
fix_ai plan '{"step":"plan","skills":["superpowers:writing-plans"],"status":"planned","designSource":"ticket-body","premise":{"verdict":"still-true","evidence":"a.sh:1"},"tasks":[{"title":"t","files":[{"path":"a.sh","action":"modify"}],"tests":[{"file":"a.test.sh","behaviour":"it does the thing","redWhen":"the fix is deleted"}]}]}' superpowers:writing-plans
mv "$FIX/ai/plan.jsonl" "$FIX/ai/plan.then.jsonl"; refused > "$FIX/ai/plan.jsonl"
before=$(calls); rows=$(checks)
out=$(DRIVER_TICKET=701 driver_ai_step 701 plan 2>&1); rc=$?
want "the step finishes" "0" "$rc"
want "after one more call" "2" "$(( $(calls) - before ))"
want_in "it says the session could not run, with the status and code" 'plan: the session could not run — the API refused it: 403 oauth_not_allowed_for_organization' "$out"
want_not_in "and never the skill sentence" "$SKILL_WORDS" "$out"
want "the answer kept is the second call's" "a.sh" "$(jq -r '.tasks[0].files[0].path' "$(driver_state_dir 701)/steps/plan.json")"
want "no note is left to park on" "" "$(driver_state_get 701 park_note)"
want "no hold is written" "no" "$([ -f "$SWARM_USAGE_HOLD_FILE" ] && echo yes || echo no)"
want "the one skill check recorded is the call that ran" "$(( rows + 1 )) ok" "$(checks) $(tail -1 "$HARNESS_SKILL_CHECKS" | cut -f4)"
want "and the count of no-Skill checks is unchanged" "2" "$(nones)"

echo "--- a 403 that outlasts the tries: held with the API's reason, requeued, never parked ---"
reset_case 702
refused > "$FIX/ai/plan.jsonl"
before=$(calls); rows=$(checks)
out=$(env -u DRIVER_API_REFUSAL_BASE_SEC bash "$BT" 702 --steps "plan" 2>&1); rc=$?
want "it ends as a requeue, not a park" "28" "$rc"
want "the call is made five times" "5" "$(( $(calls) - before ))"
want "after waits of 60, 180, 300 and 420 seconds" "60 180 300 420" "$(tr '\n' ' ' < "$FIX/waits.log" | sed 's/ $//')"
want_in "it says so" 'requeued.*not parked' "$out"
want_not_in "it is not read as a skipped Skill or a park" "parked \\(|cannot read|$SKILL_WORDS" "$out"
want "the hold lasts an hour" "$(( SWARM_NOW + 3600 ))" "$(cut -f1 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"
want_in "and names the API's status and code" '^the API refused the session: 403 oauth_not_allowed_for_organization: Claude Code' "$(cut -f2 "$SWARM_USAGE_HOLD_FILE" 2>/dev/null)"
want_in "the coordinator's hold reads it" 'API refused the session: 403' "$(bash -c '. "$1/../../swarm/swarm-env.sh" >/dev/null 2>&1; swarm_usage_hold_source' _ "$HERE")"
want_in "the reason is on the record" 'the API refused the plan session: 403 oauth_not_allowed_for_organization' "$(driver_state_get 702 requeued)"
want_in "the ticket is back on the queue" '^add 702 ' "$(cat "$FIX/queue.log" 2>/dev/null)"
want "no label goes on the ticket" "" "$(grep -E 'issue edit .*--add-label' "$GH_LOG" || true)"
want_not_in "no draft pull request, no park comment" 'pr create|issue comment' "$(cat "$GH_LOG")"
want "plan is not marked done" "" "$(driver_state_get 702 'done|join(",")')"
want "the skill check's record has no new row" "$rows" "$(checks)"
want "and its count of no-Skill checks is unchanged" "2" "$(nones)"

echo "--- the tries and the base wait are the environment's ---"
reset_case 703
before=$(calls)
DRIVER_API_REFUSAL_TRIES=2 DRIVER_API_REFUSAL_BASE_SEC=5 bash "$BT" 703 --steps "plan" >/dev/null 2>&1; rc=$?
want "still a requeue" "28" "$rc"
want "three calls for two tries" "3" "$(( $(calls) - before ))"
want "waits of 5 and 15" "5 15" "$(tr '\n' ' ' < "$FIX/waits.log" | sed 's/ $//')"

echo "--- a refusal that is not the account's: a machine fault, with the API's reason ---"
reset_case 704
refused "" > "$FIX/ai/plan.jsonl"
rows=$(checks)
out=$(bash "$BT" 704 --steps "plan" 2>&1); rc=$?
want "it exits as the machine's" "33" "$rc"
want_in "the park names the API's refusal" 'machine fault.*the API refused the plan session: api_error: Claude Code' "$out"
want_not_in "and never the skill sentence" "$SKILL_WORDS" "$out"
want "no hold is written" "no" "$([ -f "$SWARM_USAGE_HOLD_FILE" ] && echo yes || echo no)"
want "the skill check's record has no new row" "$rows 2" "$(checks) $(nones)"

echo "--- a session that ran and called no Skill still parks with the skill wording ---"
reset_case 705
no_skill > "$FIX/ai/plan.jsonl"
before=$(calls); rows=$(checks)
out=$(bash "$BT" 705 --steps "plan" 2>&1); rc=$?
want "it parks" "20" "$rc"
want "asked once, never waited for" "1 no" "$(( $(calls) - before )) $([ -f "$FIX/waits.log" ] && echo yes || echo no)"
want_in "with the park's wording" 'plan did not run the Skill its brief names' "$out"
want_in "and the step's own line" 'the session \(Claude Code 2\.1\.319\) listed the skill and the model did not call it' "$out"
want "and it is counted: a third no-Skill check" "$(( rows + 1 )) 3" "$(checks) $(nones)"

echo "--- the auth reader: the CLI's own lost login, and nothing that quotes one ---"
auth_is() { # <title> <want-rc> <file>
  swarm_api_auth_log "$3" >/dev/null; want "$1" "$2" "$?"
}
expired > "$FIX/r.jsonl"
a=$(swarm_api_auth_log "$FIX/r.jsonl"); rc=$?
want "an expired OAuth session is auth" "0" "$rc"
want_in "it prints the CLI's words" '^Failed to authenticate: OAuth session expired' "$a"
expired "OAuth token has expired. Please obtain a new token or refresh your existing token." > "$FIX/r.jsonl"
auth_is "an expired OAuth token is auth" 0 "$FIX/r.jsonl"
expired "OAuth token revoked" > "$FIX/r.jsonl"
auth_is "a revoked OAuth token is auth" 0 "$FIX/r.jsonl"
expired 'API Error: {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}' > "$FIX/r.jsonl"
auth_is "authentication_error is auth" 0 "$FIX/r.jsonl"
expired "Invalid API key · Please run /login" > "$FIX/r.jsonl"
auth_is "'run /login' is auth" 0 "$FIX/r.jsonl"
jq -nc '{type:"result", is_error:true, terminal_reason:"api_error", api_error_status:401, api_error_code:"x", result:"unauthorised"}' > "$FIX/r.jsonl"
auth_is "a 401 is auth" 0 "$FIX/r.jsonl"
refused > "$FIX/r.jsonl"
auth_is "a 403 org refusal is not auth" 1 "$FIX/r.jsonl"
refused 529 overloaded_error > "$FIX/r.jsonl"
auth_is "a 529 overload is not auth" 1 "$FIX/r.jsonl"
jq -nc --arg q "$(expired)" '{type:"result", subtype:"success", is_error:false, result:("the log said: Failed to authenticate " + $q)}' > "$FIX/r.jsonl"
auth_is "an answer quoting 'Failed to authenticate' is not auth" 1 "$FIX/r.jsonl"
{ expired; jq -nc '{type:"result", is_error:false, result:"{\"files\":[]}"}'; } > "$FIX/r.jsonl"
auth_is "an earlier auth line the CLI then ran past is not auth" 1 "$FIX/r.jsonl"

echo "--- an expired login: the host's, held for auth, requeued after one call ---"
reset_case 706
expired > "$FIX/ai/plan.jsonl"
git init -q --bare "$FIX/claims-origin"
git -C "$REPO" remote add origin "$FIX/claims-origin" 2>/dev/null || git -C "$REPO" remote set-url origin "$FIX/claims-origin"
git -C "$REPO" push -q origin develop
GH_CALLER=build-ticket bash "$CLK" acquire 706 --branch tkt-706/work >/dev/null 2>&1
want "the ticket is claimed before the run" "held" "$(bash "$CLK" show 706 >/dev/null 2>&1 && echo held || echo free)"
before=$(calls); rows=$(checks)
out=$(bash "$BT" 706 --steps "plan" 2>&1); rc=$?
want "it ends as a requeue, not a machine fault" "28" "$rc"
want "exactly one model call" "1" "$(( $(calls) - before ))"
want "no refusal waits" "no" "$([ -f "$FIX/waits.log" ] && echo yes || echo no)"
want_not_in "no API retry" 'Trying once more|Try 1 of' "$out"
want "the auth hold is written" "yes" "$([ -f "$SWARM_AUTH_HOLD_FILE" ] && echo yes || echo no)"
want "it names this host" "hostA" "$(cut -f3 "$SWARM_AUTH_HOLD_FILE" 2>/dev/null)"
want_in "and the CLI's error" 'Failed to authenticate: OAuth session expired' "$(cut -f2 "$SWARM_AUTH_HOLD_FILE" 2>/dev/null)"
want "since is now" "$SWARM_NOW" "$(cut -f1 "$SWARM_AUTH_HOLD_FILE" 2>/dev/null)"
want_in "the host reads as held for auth" 'Failed to authenticate.*\(since ' "$(swarm_auth_hold)"
want "no usage hold is written" "no" "$([ -f "$SWARM_USAGE_HOLD_FILE" ] && echo yes || echo no)"
want_not_in "no machine fault in the park note" 'machine fault' "$(driver_state_get 706 park_note)"
want_not_in "and none on the log" 'machine fault' "$out"
want_in "the requeue names the login" 'login' "$(driver_state_get 706 requeued)"
want "the claim is released" "free" "$(bash "$CLK" show 706 >/dev/null 2>&1 && echo held || echo free)"
want "the requeue cap is not bumped" "0" "$(driver_state_get 706 '.counters.requeue // 0')"
want "the skill check's record has no new row" "$rows" "$(checks)"

echo "--- the auth hold: the first since stays, and it never expires by time ---"
reset_case 707
swarm_auth_hold_write "first" >/dev/null
SWARM_NOW=$(( SWARM_NOW + 500 )) swarm_auth_hold_write "second" >/dev/null
want "the first since is kept on a re-write" "$SWARM_NOW" "$(cut -f1 "$SWARM_AUTH_HOLD_FILE")"
want "the text is the newest" "second" "$(cut -f2 "$SWARM_AUTH_HOLD_FILE")"
want "the account is recorded" "acct-1" "$(cut -f4 "$SWARM_AUTH_HOLD_FILE")"
SWARM_NOW=$(( SWARM_NOW + 86400 * 30 )) swarm_auth_hold >/dev/null; want "a month later it still holds" "0" "$?"
rm -f "$SWARM_AUTH_HOLD_FILE"; swarm_auth_hold >/dev/null; want "no file holds nothing" "1" "$?"

suite_end "$FAILED"
