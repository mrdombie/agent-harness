#!/usr/bin/env bash
# steps/fix.sh — the rework round, and the only step that reads what the reviewer
# found.
#
#   driver_step_fix <ticket>
#
# WHY IT EXISTS. `briefs/fix.md` shipped carrying {{BLOCKERS}} and nothing sent it
# anything: there was no step file, `fix` was not in the order, and `grep -rn
# BLOCKERS driver/` was empty outside the tests. A review that graded a Critical
# returned exit 30, the orchestrator rewound to the build step, and the build step
# re-ran the ORIGINAL plan task — blind to what the reviewer had just said. So the
# two-round ceiling bounded a loop that could not act, and both rounds spent an
# agent re-deciding what to build rather than fixing what was wrong.
#
# IT IS A NO-OP UNTIL THERE IS SOMETHING TO FIX, and it says so. On the first pass
# no review has happened, so there are no findings and no agent is started. That is
# what lets it sit in the fixed order rather than being conditionally skipped —
# and a step that is conditionally skipped reports exactly like a step that passed.
#
# EVERY BLOCKING GRADE. What the review left blocking is fixed here, in the change that
# caused it: Critical, Major and Minor after round 1, Critical and Major after a later
# round (its Minors went on the screen's polish list); a Nit was dropped. A Minor once left as its own follow-up, and every
# passing review opened new tickets.
#
# AND THE FIX IS PROVED THE SAME WAY THE BUILD IS. Each cleared finding names the
# commit that added its test and the commit that made it pass, and the driver runs
# that test at the change's parent and at the change. A fix whose test is green
# before the fix is a fix nothing pins — the same defect the build step exists to
# catch, reached one round later.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
# driver_prove_red_green lives with the build step: one proof, read by both, so a
# second copy cannot start disagreeing with it about what red means.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.sh" || exit 1

# _driver_fix_gates <ticket> — the fix round for gates self-check found red. Every gate
# finding is answered in `gateFixes` with a commit on the branch; a gate is not
# deferrable, because self-check refuses while it is red anyway.
_driver_fix_gates() { # <ticket>
  local t="$1" d f wt n round rc ans ids bid unanswered="" c bad=0
  d=$(driver_state_dir "$t"); f="$d/steps/self-check.findings.json"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  n=$(jq -r 'length' "$f" 2>/dev/null)
  round=$(driver_state_count "$t" fix)
  driver_fact_put "$t" fix BLOCKERS "$(jq -r '
    [.[] | "- id \(.id) · gate · `\(.command)` exited \(.exit)\n  This is a self-check gate, not a review finding: answer it in gateFixes.\n  output (last lines):\n\(.output | split("\n") | map("    " + .) | join("\n"))"]
    | join("\n")' "$f")"
  driver_fact_put "$t" fix DIFF "$(_driver_fix_diff "$wt")"
  driver_fact_put "$t" fix ROUND "$((round + 1))"
  _driver_fix_pm_answers "$t" "$d/steps/pm-answers.json"
  driver_fact_put "$t" fix PM_ANSWERS "$(_driver_fix_pm_fact "$d/steps/pm-answers.json")"

  driver_say "   fix round $((round + 1)): $n red gate(s) from self-check to repair"
  rc=0; driver_ai_step "$t" fix || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  driver_format_changed "$t" "$wt" fix || true
  driver_state_bump "$t" fix
  ans="$d/steps/fix.json"
  jq -c '(.replacedTests // [])[]' "$ans" >> "$d/steps/replaced.jsonl" 2>/dev/null || true

  ids=$(jq -r '.[].id' "$f")
  for bid in $ids; do
    jq -e --arg b "$bid" '([.gateFixes[]?.blockerId] + [.cleared[]?.blockerId] + [.deferred[]?.blockerId]) | index($b) != null' \
      "$ans" >/dev/null 2>&1 || unanswered="$unanswered $bid"
  done
  if [ -n "$unanswered" ]; then
    driver_say "✋ fix: red gate(s)${unanswered} appear in no answer. A gate nobody repaired is still red."
    driver_state_set "$t" park_note "the fix round left the red gate(s)${unanswered} unanswered: $(jq -r '[.[] | "\(.id) `\(.command)` exit \(.exit)"] | join("; ")' "$f")"
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$(jq -r '[.deferred[]?] | length' "$ans" 2>/dev/null)" != "0" ]; then
    driver_say "✋ fix: a red gate was deferred — $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    driver_state_set "$t" park_note "the fix round says a red gate is not this change's to repair: $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_REFUSED"
  fi
  # The commit named is a commit on this branch, or the repair is somewhere else.
  for c in $(jq -r '.gateFixes[]?.commit' "$ans"); do
    if ! git -C "$wt" merge-base --is-ancestor "$c" HEAD 2>/dev/null; then
      driver_say "✋ fix: the gate repair names commit $c, which is not on this branch."
      bad=1
    fi
  done
  if [ "$bad" -ne 0 ]; then
    driver_state_set "$t" park_note "the gate fix round named a commit that is not on the branch: $(jq -r '[.gateFixes[]?.commit] | join(" ")' "$ans")"
    return "$DRIVER_E_REFUSED"
  fi
  # Answered once. Self-check re-runs every gate next and is the proof.
  mv "$f" "$d/steps/self-check.findings.answered.json"
  driver_say "   fix: $n red gate(s) repaired — self-check re-runs every gate next"
  return "$DRIVER_OK"
}

# _driver_fix_pm_answers <ticket> <out> — the ticket's `## PM answer` comments as
# [{ref, createdAt, body}], oldest first; [] when there are none or none could be read.
# An answer already on the ticket is a call already made, and a fixer never shown it
# deferred three findings the PM had accepted a non-test proof for.
_driver_fix_pm_answers() { # <ticket> <out>
  local j
  j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json comments 2>/dev/null) || j=""
  [ -n "$j" ] || j='{}'
  printf '%s' "$j" | jq -c '[(.comments // []) | to_entries[]
      | select((.value.body // "") | test("^\\s*## PM answer"))
      | {ref: (.value.url // "comment \(.key + 1)"), createdAt: (.value.createdAt // ""), body: .value.body}]' \
    > "$2" 2>/dev/null || printf '[]' > "$2"
}

_driver_fix_pm_fact() { # <answers.json>
  local n; n=$(jq 'length' "$1" 2>/dev/null)
  if [ "${n:-0}" -eq 0 ]; then
    printf '(none — the ticket carries no comment headed "## PM answer", so every finding is cleared with a test or deferred)'
    return 0
  fi
  jq -r '.[] | "- ref: \(.ref)\(if .createdAt != "" then " (\(.createdAt))" else "" end)\n\(.body | split("\n") | map("    " + .) | join("\n"))"' "$1"
}

# _driver_fix_pm_allows <answers.json> <blocker> <kind> — the refs, one a line, of the
# PM answers that name the finding as a word and accept that kind of proof.
_driver_fix_pm_allows() { # <answers.json> <blocker> <kind>
  local re='mutation' i n body
  [ "$3" = commit ] && re='commit'
  n=$(jq 'length' "$1" 2>/dev/null); i=0
  while [ "$i" -lt "${n:-0}" ]; do
    body=$(jq -r --argjson i "$i" '.[$i].body' "$1")
    if printf '%s' "$body" | grep -qwF -- "$2" && printf '%s' "$body" | grep -qi -- "$re"; then
      jq -r --argjson i "$i" '.[$i].ref' "$1"
    fi
    i=$((i+1))
  done
}

# _driver_fix_pm_proof <tree> <answers.json> <review.json> <entry> — proves one
# pmProofs entry, printing why. Exit as driver_prove_by_break; 3 = not allowed or not
# checkable. A non-test proof is accepted only when a PM answer names the finding,
# accepts that kind, and the driver has checked it here.
_driver_fix_pm_proof() { # <tree> <answers.json> <review.json> <entry-json>
  local wt="$1" pa="$2" review="$3" e="$4" bid ref kind c body cs named="" tok tf
  bid=$(jq -r '.blockerId // ""' <<<"$e"); ref=$(jq -r '.pmAnswer // ""' <<<"$e")
  kind=$(jq -r '.kind // ""' <<<"$e"); c=$(jq -r '.commit // ""' <<<"$e")
  body=$(jq -r --arg r "$ref" '[.[] | select(.ref == $r) | .body] | last // empty' "$pa" 2>/dev/null)
  if [ -z "$body" ]; then
    printf 'cites PM answer "%s", which is not a ## PM answer comment on the ticket\n' "$ref"; return 3
  fi
  if ! _driver_fix_pm_allows "$pa" "$bid" "$kind" | grep -qxF -- "$ref"; then
    printf 'PM answer %s does not name %s and accept a %s proof for it\n' "$ref" "$bid" "$kind"; return 3
  fi
  cs=$(git -C "$wt" rev-parse --verify -q "$c^{commit}" 2>/dev/null) || {
    printf 'commit %s does not resolve\n' "$c"; return 3; }
  git -C "$wt" merge-base --is-ancestor "$cs" HEAD 2>/dev/null || {
    printf 'commit %s is not on this branch\n' "$(printf '%s' "$c" | cut -c1-10)"; return 3; }
  case "$kind" in
    mutation)
      driver_prove_by_break "$wt" "$(jq -r '.testFile // ""' <<<"$e")" "$cs" \
        "$(jq -r '.break.file // ""' <<<"$e")" "$(jq -r '.break.find // ""' <<<"$e")" \
        "$(jq -r '.break.replace // ""' <<<"$e")" "$(jq -r '.command // ""' <<<"$e")"
      return $? ;;
    commit)
      for tok in $(printf '%s' "$body" | grep -oE '[0-9a-f]{7,40}'); do
        [ "$(git -C "$wt" rev-parse --verify -q "$tok^{commit}" 2>/dev/null)" = "$cs" ] && { named=1; break; }
      done
      [ -n "$named" ] || { printf 'PM answer %s names no commit that is %s\n' "$ref" "$(printf '%s' "$c" | cut -c1-10)"; return 3; }
      tf=$(jq -r --arg b "$bid" '[.findings[]? | select(.id == $b) | .file] | first // ""' "$review" 2>/dev/null)
      if [ -z "$tf" ] || ! git -C "$wt" show --name-only --format= "$cs" 2>/dev/null | grep -qxF -- "$tf"; then
        printf 'commit %s does not touch %s, the file the finding names\n' "$(printf '%s' "$c" | cut -c1-10)" "${tf:-(none)}"; return 3
      fi
      printf 'commit %s is on the branch, is the one PM answer %s names, and touches %s\n' "$(printf '%s' "$c" | cut -c1-10)" "$ref" "$tf"
      return 0 ;;
  esac
  printf 'kind "%s" is neither mutation nor commit\n' "$kind"; return 3
}

_driver_fix_diff() { # <tree>
  local wt="$1" r trunk="" diff=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  [ -z "$trunk" ] || diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)
  printf '%s' "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
}

driver_step_fix() { # <ticket>
  local t="${1:?driver_step_fix: need a ticket}"
  local d review round wt trunk r diff blockers n rc ans i ncleared
  local tfile tcmd tsha isha why prc bad=0 bid
  export DRIVER_TICKET="$t"
  d=$(driver_state_dir "$t")
  review="$d/steps/review.json"

  # A RED SELF-CHECK COMES HERE TOO. A gate failure the model can repair — a test
  # that does not compile, a lint error — ended the run with nothing tried. The gate
  # output is the finding; the proof of the fix is self-check re-running every gate
  # straight after this step, so nothing is pushed past a red one.
  if [ -s "$d/steps/self-check.findings.json" ]; then
    _driver_fix_gates "$t"
    return $?
  fi

  if [ ! -f "$review" ]; then
    driver_say "   fix: no review has run yet, so there is nothing to fix."
    return "$DRIVER_OK"
  fi

  # ONE READER FOR "WHAT BLOCKS". The review step's own selector, so the list this
  # step is handed and the list that sent the work back cannot differ.
  n=$(jq -r "[.findings[]? | $(driver_blocking_select)] | length" "$review" 2>/dev/null)
  if [ "${n:-0}" -eq 0 ]; then
    driver_say "   fix: the review graded nothing that blocks, so there is nothing to fix."
    return "$DRIVER_OK"
  fi

  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  diff=""
  [ -z "$trunk" ] || diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)

  # VERBATIM, WITH THE GRADE AND THE PROPOSED FIX. A finding summarised on the way
  # here is a finding the fixer answers a paraphrase of.
  # THE CONTRACT'S OWN KEYS, with no alternates. `id`, `file`, `line`, `summary`,
  # `reason` and `fix` are all required by briefs/schemas/review.json, so a `//`
  # fallback to a second spelling would be this driver reading a shape the contract
  # forbids — the exact defect that made the plan step refuse its own valid example.
  blockers=$(jq -r '
    [.findings[]? | '"$(driver_blocking_select)"'
     | "- id \(.id) · \(.grade) · \(.file):\(.line)\n  \(.summary)\n  why: \(.reason)\n  proposed: \(.fix)"]
    | join("\n")' "$review" 2>/dev/null)

  round=$(driver_state_count "$t" fix)
  local proofnote; proofnote=$(driver_state_get "$t" fix_proof_note)
  [ -z "$proofnote" ] || blockers="$blockers

THE LAST FIX ROUND'S PROOF FAILED, so answer again. For each cleared finding: commit the test alone first (testCommit) so it FAILS at that commit, then commit the fix (implCommit) so it passes, and make sure the change type-checks. The test file is run whole, in the version implCommit holds, at implCommit's parent (it must fail) and at implCommit (it must pass): so implCommit is the commit where every case in that file passes, and each finding's case goes in its own test commit, straight before its own fix, so no other finding's case is red at its change. What failed:
$proofnote"
  driver_fact_put "$t" fix BLOCKERS "$blockers"
  local pa="$d/steps/pm-answers.json"
  _driver_fix_pm_answers "$t" "$pa"
  driver_fact_put "$t" fix PM_ANSWERS "$(_driver_fix_pm_fact "$pa")"
  driver_fact_put "$t" fix DIFF \
    "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
  driver_fact_put "$t" fix ROUND "$((round + 1))"

  driver_say "   fix round $((round + 1)): $n blocking finding(s) to clear"
  rc=0; driver_ai_step "$t" fix || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  driver_format_changed "$t" "$wt" fix || true
  driver_state_bump "$t" fix
  ans="$d/steps/fix.json"
  # The tests this round reworded or removed, on the same ledger build appends to.
  jq -c '(.replacedTests // [])[]' "$ans" >> "$d/steps/replaced.jsonl" 2>/dev/null || true

  # EVERY BLOCKER IS ACCOUNTED FOR. A Critical or a Major is not deferrable, so a
  # finding that is in neither `cleared` nor `deferred` is one nobody answered —
  # and the step would otherwise report a clean round about it.
  local unanswered=""
  while IFS= read -r bid; do
    [ -n "$bid" ] || continue
    jq -e --arg b "$bid" '([.cleared[]?.blockerId] + [.pmProofs[]?.blockerId] + [.deferred[]?.blockerId]) | index($b) != null' \
      "$ans" >/dev/null 2>&1 || unanswered="$unanswered $bid"
  done <<EOB
$(jq -r "[.findings[]? | $(driver_blocking_select) | (.id // empty)] | .[]" "$review" 2>/dev/null)
EOB
  if [ -n "$unanswered" ]; then
    driver_say "✋ fix: finding(s)${unanswered} appear in neither cleared nor deferred. A blocker nobody answered is a blocker that ships."
    driver_state_set "$t" park_note "the fix round left${unanswered} unanswered — a blocking finding is neither cleared nor deferrable"
    return "$DRIVER_E_REFUSED"
  fi
  # AND A BLOCKER IS NOT DEFERRABLE. The contract has a `deferred` shape because a
  # reviewer can raise something outside this ticket; it is not a way past a grade
  # that blocks, and the ship step refuses while one is open anyway.
  # A DEFERRAL THE PM HAS ALREADY ANSWERED is asked once more, told which answer
  # covers it: parking it put the owner on a call already made on the ticket.
  local pmdue="" k ref
  for bid in $(jq -r '.deferred[]?.blockerId' "$ans" 2>/dev/null); do
    for k in mutation commit; do
      ref=$(_driver_fix_pm_allows "$pa" "$bid" "$k" | tail -1)
      [ -z "$ref" ] || { pmdue="$pmdue- $bid: deferred, but PM answer $ref names it and accepts a $k proof — answer it in pmProofs citing that ref, not in deferred
"; break; }
    done
  done
  if [ -n "$pmdue" ] && [ -z "$proofnote" ]; then
    driver_state_set "$t" fix_proof_note "$pmdue"
    driver_say "↩ fix: a deferred finding is one a PM answer on the ticket already accepts a non-test proof for — asking the fix step once more, with which answer"
    rc=0; driver_step_fix "$t" || rc=$?
    driver_state_set "$t" fix_proof_note ""
    return "$rc"
  fi
  if [ "$(jq -r '[.deferred[]?] | length' "$ans" 2>/dev/null)" != "0" ]; then
    driver_say "✋ fix: $(jq -r '[.deferred[]?] | length' "$ans") of the findings were deferred, and a blocking finding is not deferrable — $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    driver_state_set "$t" park_note "the fix round deferred a blocking finding: $(jq -r '[.deferred[]? | "\(.blockerId): \(.reason)"] | join("; ")' "$ans")"
    # A PERSON DECIDES WHETHER A BLOCKER IS REALLY ONE. The fixer disagreeing with
    # a grade is a legitimate answer and it is not the driver's to settle; parking
    # it as the driver's own would leave the ticket resumable and the next round
    # free to defer it again.
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_REFUSED"
  fi

  ncleared=$(jq -r '[.cleared[]?] | length' "$ans")
  local fails="" rec="$d/steps/fix.proofs.jsonl"
  : > "$rec"
  i=0
  while [ "$i" -lt "${ncleared:-0}" ]; do
    bid=$(jq -r --argjson i "$i" '.cleared[$i].blockerId // "?"' "$ans")
    tfile=$(jq -r --argjson i "$i" '.cleared[$i].test.file // ""' "$ans")
    tcmd=$(jq -r  --argjson i "$i" '.cleared[$i].command // ""' "$ans")
    tsha=$(jq -r  --argjson i "$i" '.cleared[$i].testCommit // ""' "$ans")
    isha=$(jq -r  --argjson i "$i" '.cleared[$i].implCommit // ""' "$ans")
    i=$((i+1))
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ fix '$bid' names no test to prove it (test.file, command, testCommit and implCommit)."
      fails="$fails- $bid: names no test.file, command, testCommit and implCommit
"
      bad=1; continue
    fi
    why=""; prc=0
    why=$(driver_prove_red_green "$wt" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    case "$prc" in
      0) driver_say "   fix $bid — $why"
         jq -nc --arg b "$bid" --arg w "$why" '{blockerId:$b, proof:"red-green", pmAnswer:null, why:$w}' >> "$rec" ;;
      5) driver_say "✋ fix $bid — $why"
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_REFUSED" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) driver_say "✋ fix $bid — $why"; bad=1
         fails="$fails- $bid: $(printf '%s' "$why" | cut -c1-1000)
" ;;
    esac
  done

  # A NON-TEST PROOF ONLY WHERE A PM ANSWER ALLOWS IT, AND ONLY ONCE CHECKED HERE.
  local npm e kind
  npm=$(jq -r '[.pmProofs[]?] | length' "$ans" 2>/dev/null)
  i=0
  while [ "$i" -lt "${npm:-0}" ]; do
    e=$(jq -c --argjson i "$i" '.pmProofs[$i]' "$ans"); i=$((i+1))
    bid=$(jq -r '.blockerId // "?"' <<<"$e"); ref=$(jq -r '.pmAnswer // ""' <<<"$e"); kind=$(jq -r '.kind // ""' <<<"$e")
    why=""; prc=0
    why=$(_driver_fix_pm_proof "$wt" "$pa" "$review" "$e") || prc=$?
    case "$prc" in
      0) driver_say "   fix $bid — $kind proof allowed by PM answer $ref — $why"
         jq -nc --arg b "$bid" --arg k "$kind" --arg r "$ref" --arg w "$why" '{blockerId:$b, proof:$k, pmAnswer:$r, why:$w}' >> "$rec" ;;
      5) driver_say "✋ fix $bid — $why"
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_REFUSED" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) driver_say "✋ fix $bid — the $kind proof is not accepted: $why"; bad=1
         fails="$fails- $bid: the $kind proof (PM answer $ref) is not accepted: $(printf '%s' "$why" | cut -c1-1000)
" ;;
    esac
  done
  jq -s . "$rec" > "$d/steps/fix.proofs.json" 2>/dev/null; rm -f "$rec"

  # ONE MORE TRY, TOLD WHY. A typecheck error or a test committed with its fix is
  # the model's to repair; parking it put a person on a mechanical mistake.
  if [ "$bad" -ne 0 ] && [ -z "$proofnote" ]; then
    driver_state_set "$t" fix_proof_note "$fails"
    driver_say "↩ fix: a cleared finding is not proved red-then-green — asking the fix step once more, with why"
    rc=0; driver_step_fix "$t" || rc=$?
    driver_state_set "$t" fix_proof_note ""
    return "$rc"
  fi
  driver_state_set "$t" fix_proof_note ""
  if [ "$bad" -ne 0 ]; then
    # NOT A REWORK. A rework rewinds to here, so returning one from here is a loop
    # with this step at both ends; the reviewer's findings have not changed and a
    # second pass would be handed the same list. It parks with what could not be
    # proved.
    driver_say "✋ fix: a cleared finding is not proved by its own test. A fix whose test is green before the fix is a fix nothing pins."
    driver_state_set "$t" park_note "the fix round cleared $ncleared finding(s) and at least one is not proved red-then-green by the test it names, after one retry told why: $(printf '%s' "$fails" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi

  driver_say "   fix: $((ncleared + ${npm:-0})) finding(s) cleared — $ncleared proved red before green, ${npm:-0} by a proof a PM answer allowed and the driver checked"
  return "$DRIVER_OK"
}
