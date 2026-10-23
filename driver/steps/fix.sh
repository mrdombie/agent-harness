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
# The review's own defer: what a round does not block goes on the polish list one way.
command -v _driver_review_defer >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review.sh" || exit 1

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
  driver_git_actions "$t" "$wt" "$d/steps/fix.json" fix || return "$DRIVER_E_REFUSED"
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

# _driver_fix_auto_proof <tree> <trunk> <review.json> <entry> — proves one autoProofs
# entry, printing why. Exit as driver_prove_by_break; 3 = the commit is not that kind.
# A finding no red-then-green pair can show, fixed by a commit that is only docs, only
# comments, only wording or only tests, had one answer from the PM every time; it is
# the machine's now. The class is read off the commit's diff by scripts/proof-class.py,
# never taken from the fixer, and a test-only fix also carries a mutation the driver
# plants in non-test code: the test must go red, then green once the code is restored.
_driver_fix_auto_proof() { # <tree> <trunk> <review.json> <entry-json>
  local wt="$1" trunk="$2" review="$3" e="$4" bid kind c cs tf why rc tfile bfile
  bid=$(jq -r '.blockerId // ""' <<<"$e"); kind=$(jq -r '.kind // ""' <<<"$e"); c=$(jq -r '.commit // ""' <<<"$e")
  tfile=$(jq -r '.testFile // ""' <<<"$e"); bfile=$(jq -r '.break.file // ""' <<<"$e")
  cs=$(git -C "$wt" rev-parse --verify -q "$c^{commit}" 2>/dev/null) || {
    printf 'commit %s does not resolve\n' "${c:-(none)}"; return 3; }
  git -C "$wt" merge-base --is-ancestor "$cs" HEAD 2>/dev/null || {
    printf 'commit %s is not on this branch\n' "$(printf '%s' "$c" | cut -c1-10)"; return 3; }
  tf=$(jq -r --arg b "$bid" '[.findings[]? | select(.id == $b) | .file] | first // ""' "$review" 2>/dev/null)
  [ -n "$tf" ] || { printf 'the review names no file for %s, so the commit cannot be held to it\n' "$bid"; return 3; }
  rc=0
  why=$(python3 -I "$KIT_ROOT/scripts/proof-class.py" check --repo "$wt" --commit "$cs" --kind "$kind" \
          --file "$tf" ${trunk:+--trunk "$trunk"} --cfg "${HARNESS_CFG:-}" \
          ${tfile:+--test-file "$tfile"} ${bfile:+--break-file "$bfile"} 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$why"; return 3; fi
  [ "$kind" = test-only ] || { printf '%s\n' "$why"; return 0; }
  local by brc=0
  by=$(driver_prove_by_break "$wt" "$tfile" "$cs" "$bfile" "$(jq -r '.break.find // ""' <<<"$e")" \
         "$(jq -r '.break.replace // ""' <<<"$e")" "$(jq -r '.command // ""' <<<"$e")") || brc=$?
  printf '%s; %s\n' "$why" "$by"
  return "$brc"
}

# A park that asks for the proof the driver now checks itself: "no red/green pair is
# possible — will you accept a mutation proof / the fixing commit?"
DRIVER_FIX_AUTO_ASK_RE='mutation proof|commit proof|no red.{0,12}green|red.then.green pair|(wording|comment|docs?|test)[- ]only'

# _driver_fix_critic_head <pr> — the head the critic last FAILED, from the judge's own
# ledger (pr, head, set, verdict, state, url); nothing when it has none.
_driver_fix_critic_head() { # <pr>
  [ -n "$1" ] || return 0
  awk -F'\t' -v p="$1" '$1 == p && $5 == "failure" { h = $2 } END { if (h != "") print h }' \
    "${CRITIC_JUDGE_DIR:-$STATE_DIR/swarm/critic-judge}/verdicts.tsv" 2>/dev/null
}

# _driver_fix_stale_check <tree> <judged-head> <sha…> — 0 when every cited commit is on
# this branch and none is in the head the critic failed: the finding was judged on a
# tree without them, so the critic judging the pushed head again is the proof.
_driver_fix_stale_check() { # <tree> <judged-head> <sha…>
  local wt="$1" jh="$2" c cs jhs; shift 2
  [ -n "$jh" ] || { printf "the critic's failing verdict is not in its ledger, so \"after the critic's run\" cannot be checked\n"; return 1; }
  jhs=$(git -C "$wt" rev-parse --verify -q "$jh^{commit}" 2>/dev/null) || {
    printf 'the head the critic judged (%s) is not in this clone\n' "$(printf '%s' "$jh" | cut -c1-10)"; return 1; }
  for c in "$@"; do
    cs=$(git -C "$wt" rev-parse --verify -q "$c^{commit}" 2>/dev/null) || { printf 'commit %s does not resolve\n' "$c"; return 1; }
    git -C "$wt" merge-base --is-ancestor "$cs" HEAD 2>/dev/null || { printf 'commit %s is not on this branch\n' "$c"; return 1; }
    if git -C "$wt" merge-base --is-ancestor "$cs" "$jhs" 2>/dev/null; then
      printf 'commit %s was already in %s, the head the critic failed\n' "$c" "$(printf '%s' "$jh" | cut -c1-10)"; return 1
    fi
  done
  printf 'commit(s) %s are on the branch and came after %s, the head the critic failed: the critic judges the pushed head again\n' "$*" "$(printf '%s' "$jh" | cut -c1-10)"
}

# _driver_fix_pr_body_now <pr> <out> — the description GitHub holds now, written to
# <out>; prints the PR's labels, space-separated. 1 when it cannot be read.
_driver_fix_pr_body_now() { # <pr> <out>
  local j
  [ -n "$1" ] || return 1
  j=$(swarm_gh pr view "$1" --repo "$REPO_SLUG" --json body,labels 2>/dev/null) || return 1
  printf '%s' "$j" | jq -e 'has("body")' >/dev/null 2>&1 || return 1
  printf '%s' "$j" | jq -r '.body // ""' > "$2" || return 1
  printf '%s' "$j" | jq -r '[(.labels // [])[].name] | join(" ")'
}

# _driver_fix_pr_body_at <pr> <epoch> <out> — the description as GitHub's edit history
# held it at <epoch>: the newest recorded version no later than it. A description never
# edited has no history, so it is the current one. 1 when it cannot be read.
_driver_fix_pr_body_at() { # <pr> <epoch> <out>
  local j
  [ -n "$1" ] || return 1
  j=$(swarm_gh api graphql \
        -f query='query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p){userContentEdits(first:100){nodes{editedAt diff}}}}}' \
        -f o="${REPO_SLUG%%/*}" -f n="${REPO_SLUG#*/}" -F p="$1" 2>/dev/null) || return 1
  printf '%s' "$j" | jq -e '.data.repository.pullRequest.userContentEdits.nodes | type == "array"' >/dev/null 2>&1 || return 1
  if [ "$(printf '%s' "$j" | jq '.data.repository.pullRequest.userContentEdits.nodes | length')" = 0 ]; then
    _driver_fix_pr_body_now "$1" "$3" >/dev/null; return $?
  fi
  printf '%s' "$j" | jq -e -r --argjson t "$2" '[.data.repository.pullRequest.userContentEdits.nodes[]
      | select((.editedAt | sub("\\.[0-9]+"; "") | fromdateiso8601) <= $t)]
      | max_by(.editedAt) // error("none") | .diff | strings' > "$3" 2>/dev/null
}

_driver_fix_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# _driver_fix_body_proof <tree> <trunk> <pr> <review.json> <entry> <keep-dir> — proves one
# bodyProofs entry, printing why. The driver reads both descriptions from GitHub and runs
# the named check on each, the branch's changed paths on stdin: it must fail on the one
# the review judged and pass on the one now, so the edit is the only thing that varies.
# 0 proved, 3 not proved, 4 the check timed out.
_driver_fix_body_proof() { # <tree> <trunk> <pr> <review.json> <entry-json> <keep-dir>
  local wt="$1" trunk="$2" pr="$3" review="$4" e="$5" keep="$6" cmd bid at labels tmp rc_old rc_new changed=""
  bid=$(jq -r '.blockerId // ""' <<<"$e"); cmd=$(jq -r '.command // ""' <<<"$e")
  [ -n "$cmd" ] || { printf 'names no check command\n'; return 3; }
  [ -n "$pr" ] || { printf 'the run has no pull request, so there is no description to check\n'; return 3; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/driver-body-proof-XXXXXX")
  labels=$(_driver_fix_pr_body_now "$pr" "$tmp/now.md") || {
    rm -rf "$tmp"; printf 'the description of PR #%s could not be read from GitHub\n' "$pr"; return 3; }
  at=$(_driver_fix_mtime "$review")
  if [ -z "$at" ] || ! _driver_fix_pr_body_at "$pr" "$at" "$tmp/was.md"; then
    rm -rf "$tmp"; printf 'the description PR #%s had when the review judged it could not be read from its edit history\n' "$pr"; return 3
  fi
  cp "$tmp/now.md" "$keep/fix.body-now.$bid.md" 2>/dev/null || true
  cp "$tmp/was.md" "$keep/fix.body-reviewed.$bid.md" 2>/dev/null || true
  [ -z "$trunk" ] || changed=$(git -C "$wt" diff --name-only "$trunk"...HEAD 2>/dev/null)
  _driver_fix_body_run() { # <body-file> <out>
    ( cd "$wt" || exit 2
      export BODY_FILE="$1" LABELS="$labels" ROOT="$wt"
      printf '%s\n' "$changed" | driver_run_project "$DRIVER_CMD_TIMEOUT" "$cmd" ) >"$2" 2>&1
  }
  rc_new=0; _driver_fix_body_run "$tmp/now.md" "$tmp/now.out" || rc_new=$?
  rc_old=0; _driver_fix_body_run "$tmp/was.md" "$tmp/was.out" || rc_old=$?
  if [ "$rc_new" -eq 124 ] || [ "$rc_old" -eq 124 ]; then
    rm -rf "$tmp"; printf 'the check `%s` timed out after %ss\n' "$cmd" "$DRIVER_CMD_TIMEOUT"; return 4
  fi
  if [ "$rc_new" -ne 0 ]; then
    printf 'the check `%s` fails on the description now (exit %s): %s\n' "$cmd" "$rc_new" "$(_driver_fail_lines "$tmp/now.out")"
    rm -rf "$tmp"; return 3
  fi
  if [ "$rc_old" -eq 0 ]; then
    rm -rf "$tmp"
    printf 'the check `%s` already passes on the description the review judged, so the edit proved nothing\n' "$cmd"; return 3
  fi
  rm -rf "$tmp"
  printf 'the check `%s` fails on the description the review judged (exit %s) and passes on the description now, both read from PR #%s\n' "$cmd" "$rc_old" "$pr"
}

_driver_fix_diff() { # <tree>
  local wt="$1" r trunk="" diff=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  [ -z "$trunk" ] || diff=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)
  printf '%s' "${diff:-(none — nothing to diff: no $INTEGRATION_BRANCH resolves in $wt, or the branch carries no change)}"
}

# _driver_fix_polish_back <ticket> <review.json> <polish-id> <why> — a ride-along polish
# item this change did not finish goes back free on its list (any take released), is
# noted in the PR's "Minor, deferred", and blocks nothing.
_driver_fix_polish_back() {
  local t="$1" review="$2" bid="$3" why="$4" x n it pl="${DRIVER_POLISH_LIST:-$KIT_ROOT/scripts/polish-list.sh}"
  x=$(jq -c --arg b "$bid" '[.findings[]? | select(.id == $b)] | first // empty' "$review" 2>/dev/null)
  [ -n "$x" ] || return 0
  n=$(printf '%s' "$x" | jq -r '.file // ""' | sed -n 's/.*#\([0-9][0-9]*\).*/\1/p')
  it=$(printf '%s' "$x" | jq -r '.summary // ""')
  [ -z "$n" ] || bash "$pl" forget "$t" "$n" "$it" >/dev/null 2>&1 || true
  printf '%s' "$x" | jq -c --arg l "#${n:-?}" --arg w "$why" --argjson r "$(driver_state_count "$t" review)" \
    '{grade, file, line, summary: (.summary + " — back on its list: " + $w), round: $r, list: $l}' \
    >> "$(driver_state_dir "$t")/steps/review.deferred.jsonl"
  driver_say "   fix: polish $bid is back on polish list #${n:-?} ($why) — it rides along with the next change there"
}

# _driver_fix_drop_nonblocking <ticket> <fix.json> <graded json> <round> — a deferral of a
# finding this round does not block leaves `deferred` and never refuses: a Minor from
# round 2 is on its screen's polish list (_driver_review_defer put it there), a Nit was
# dropped, and one the driver already deferred this cycle (review.deferred.jsonl) is on
# its list. The grade is the one the review recorded, never the fixer's wording; an id
# found in neither stays, unless the critic's check only warns until the release.
_driver_fix_drop_nonblocking() {
  local t="$1" ans="$2" graded="$3" round="$4" late dj kept dropped
  late=$(driver_blocking_grades "$round")
  dj="$(driver_state_dir "$t")/steps/review.deferred.jsonl"
  [ -s "$dj" ] && graded=$(jq -c --slurpfile x "$dj" '. + [$x[] | select((.id // "") != "") | {id, grade: (.grade // ""), was: "deferred"}]' <<<"$graded" 2>/dev/null || printf '%s' "$graded")
  # Not a review finding while the critic's check warns until the release: the critic
  # handed this round nothing (driver_fact_critic_findings), so it is no blocker either.
  local warn=""
  command -v release_check_nonblocking >/dev/null 2>&1 \
    && release_check_nonblocking "$(driver_opt review.judge.context "Design critic")" && warn=1
  dropped=$(jq -c --argjson g "$graded" --arg late "$late" --arg warn "$warn" '[.deferred[]? | .blockerId as $b
      | ([$g[] | select(.id == $b)] | first) as $f
      | if $f == null then (select($warn != "") | . + {grade: "a check that warns until the release"})
        else (select($f.was == "deferred" or (($late | split(" ")) | index($f.grade)) == null) | . + {grade: $f.grade}) end]' "$ans" 2>/dev/null)
  [ "${dropped:-[]}" != "[]" ] && [ -n "$dropped" ] || return 0
  kept=$(jq -c --argjson x "$dropped" '[.deferred[]? | .blockerId as $b | select([$x[].blockerId] | index($b) | not)]' "$ans")
  jq --argjson d "$kept" '.deferred = $d' "$ans" > "$ans.t" && mv "$ans.t" "$ans"
  driver_say "   fix: $(jq -r 'length' <<<"$dropped") deferred finding(s) do not block in review round $round ($late) — $(jq -r '[.[] | "\(.blockerId) (\(.grade))"] | join(", ")' <<<"$dropped"): a Minor is on its screen's polish list, a Nit was dropped; no refusal"
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
  driver_drop_critic_findings "$review" fix || true

  # WHAT BLOCKS IS THE ROUND'S, HERE AS IN THE REVIEW. Read off the review round the
  # driver counted and the grade the review recorded, never the fixer's wording: from
  # round 2 a Minor goes on its screen's polish list, before the fixer and after it.
  local fround bsel graded
  fround=$(driver_state_count "$t" review); [ "${fround:-0}" -ge 1 ] 2>/dev/null || fround=1
  bsel=$(driver_blocking_select "$fround")
  graded=$(jq -c '[.findings[]? | {id: (.id // ""), grade: (.grade // "")}]' "$review" 2>/dev/null)
  [ -n "$graded" ] || graded='[]'
  _driver_review_defer "$t" "$review" "$fround"

  # ONE READER FOR "WHAT BLOCKS". The review step's own selector, so the list this
  # step is handed and the list that sent the work back cannot differ.
  n=$(jq -r "[.findings[]? | $bsel] | length" "$review" 2>/dev/null)
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
    [.findings[]? | '"$bsel"'
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
  # A QUESTION THE MACHINE ANSWERS IS NOT A PARK. "No red/green pair is possible —
  # accept the commit / a mutation?" had one answer from the PM every time; it is
  # asked once more, pointed at autoProofs, and the driver checks what comes back.
  local autokinds; autokinds=$(driver_auto_proof_kinds)
  if [ "$rc" -eq "$DRIVER_E_QUESTION" ] && [ -z "$proofnote" ] && [ -n "$autokinds" ] \
     && jq -r '.question // ""' "$d/steps/fix.json" 2>/dev/null | grep -qiE -- "$DRIVER_FIX_AUTO_ASK_RE"; then
    driver_state_set "$t" fix_proof_note "- you asked: $(jq -r '.question' "$d/steps/fix.json" | tr '\n' ' ' | cut -c1-600)
  That is not a question for a person. A finding no red-then-green pair can show, fixed by a commit that is only $autokinds, goes in autoProofs naming the kind and the commit (test-only also names testFile, command and a break in non-test code). The driver reads the commit's diff itself and, for test-only, plants the break: red, then green once restored."
    driver_say "↩ fix: asked whether a docs/comment/wording/test-only fix can be accepted without a red-then-green pair — the driver checks that itself; asking the fix step once more, pointed at autoProofs"
    rc=0; driver_step_fix "$t" || rc=$?
    driver_state_set "$t" fix_proof_note ""
    return "$rc"
  fi
  [ "$rc" -eq 0 ] || return "$rc"
  driver_git_actions "$t" "$wt" "$d/steps/fix.json" fix || return "$DRIVER_E_REFUSED"
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
    jq -e --arg b "$bid" '([.cleared[]?.blockerId] + [.pmProofs[]?.blockerId] + [.autoProofs[]?.blockerId] + [.bodyProofs[]?.blockerId] + [.deferred[]?.blockerId]) | index($b) != null' \
      "$ans" >/dev/null 2>&1 || unanswered="$unanswered $bid"
  done <<EOB
$(jq -r "[.findings[]? | $bsel | (.id // empty)] | .[]" "$review" 2>/dev/null)
EOB
  # A RIDE-ALONG POLISH ITEM IS NOT A BLOCKER OF THIS TICKET. One the fixer left, or
  # deferred, goes back free on its list, noted in the PR, and the run goes on.
  local pb kept_unanswered=""
  for bid in $unanswered $(jq -r '.deferred[]?.blockerId' "$ans" 2>/dev/null); do
    case "$bid" in
      polish-*) _driver_fix_polish_back "$t" "$review" "$bid" "not finished by this change" ;;
      *) case " $unanswered " in *" $bid "*) kept_unanswered="$kept_unanswered $bid" ;; esac ;;
    esac
  done
  unanswered="$kept_unanswered"
  pb=$(jq -c '[.deferred[]? | select((.blockerId // "") | startswith("polish-") | not)]' "$ans" 2>/dev/null)
  [ -z "$pb" ] || { jq --argjson d "$pb" '.deferred = $d' "$ans" > "$ans.t" && mv "$ans.t" "$ans"; }
  _driver_fix_drop_nonblocking "$t" "$ans" "$graded" "$fround"
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
  if [ -n "$autokinds" ]; then
    for bid in $(jq -r '.deferred[]? | select((.reason // "") | test($re; "i")) | .blockerId' --arg re "$DRIVER_FIX_AUTO_ASK_RE" "$ans" 2>/dev/null); do
      case "$pmdue" in *"- $bid:"*) continue ;; esac
      pmdue="$pmdue- $bid: deferred as having no red-then-green pair, but a fix that is only $autokinds needs no PM answer — answer it in autoProofs with the kind and the commit; the driver reads the commit's diff (and plants the break for test-only)
"
    done
  fi
  if [ -n "$pmdue" ] && [ -z "$proofnote" ]; then
    driver_state_set "$t" fix_proof_note "$pmdue"
    driver_say "↩ fix: a deferred finding is one a PM answer on the ticket already accepts a non-test proof for — asking the fix step once more, with which answer"
    rc=0; driver_step_fix "$t" || rc=$?
    driver_state_set "$t" fix_proof_note ""
    return "$rc"
  fi
  # A FINDING SAID TO BE STALE IS RE-CHECKED, NEVER THE OWNER'S. A deferral of a
  # finding that is not the review's own (a critic's) and that cites commits says the
  # critic judged a tree without them. Every cited commit on the branch and absent
  # from the head the critic failed: the critic judges the pushed head again, and its
  # status blocks the merge while it still fails. Anything else is refused, for the PM.
  local rids stale_ids="" stale_recs="" stale_bad="" shas sw src pr jh
  rids=$(jq -c '[.findings[]?.id]' "$review" 2>/dev/null); [ -n "$rids" ] || rids='[]'
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" critic_pr)
  jh=$(_driver_fix_critic_head "$pr")
  i=0
  while [ "$i" -lt "$(jq -r '[.deferred[]?] | length' "$ans" 2>/dev/null)" ]; do
    bid=$(jq -r --argjson i "$i" '.deferred[$i].blockerId' "$ans")
    shas=$(jq -r --argjson i "$i" '.deferred[$i].reason' "$ans" | grep -oE '(^|[^0-9a-zA-Z])[0-9a-f]{7,40}([^0-9a-zA-Z]|$)' | grep -oE '[0-9a-f]{7,40}' | sort -u | tr '\n' ' ')
    i=$((i+1))
    jq -e --arg b "$bid" --argjson r "$rids" '$r | index($b) != null' -n >/dev/null 2>&1 && continue
    [ -n "$shas" ] || continue
    src=0; sw=$(_driver_fix_stale_check "$wt" "$jh" $shas) || src=$?
    if [ "$src" -eq 0 ]; then
      driver_say "   fix $bid — said not outstanding, and re-checked: $sw"
      stale_ids="$stale_ids $bid"
      stale_recs="$stale_recs$(jq -nc --arg b "$bid" --arg w "$sw" '{blockerId:$b, proof:"critic-recheck", pmAnswer:null, why:$w}')
"
    else
      stale_bad="$stale_bad- $bid: said not outstanding, and the re-check failed: $sw
"
    fi
  done
  local left
  left=$(jq -c --arg s "$stale_ids $(printf '%s' "$stale_bad" | sed -n 's/^- \([^:]*\):.*/\1/p' | tr '\n' ' ')" \
    '[.deferred[]? | select(.blockerId as $b | ($s | split(" ") | index($b)) == null)]' "$ans" 2>/dev/null)
  if [ "${left:-[]}" = "[]" ] && [ -n "$stale_bad" ]; then
    driver_say "✋ fix: a finding said to be stale could not be re-checked — $(printf '%s' "$stale_bad" | tr '\n' ' ')"
    driver_state_set "$t" park_note "the fix round said a critic finding is not outstanding and the driver could not confirm it: $(printf '%s' "$stale_bad" | tr '\n' ' ')"
    # THE PM'S, NOT THE OWNER'S. Whether commits cover a finding is not a product call.
    driver_state_set "$t" park_cause pm
    return "$DRIVER_E_REFUSED"
  fi
  if [ "${left:-[]}" != "[]" ]; then
    driver_say "✋ fix: $(jq -r 'length' <<<"$left") of the findings were deferred, and a blocking finding is not deferrable — $(jq -r '[.[] | "\(.blockerId): \(.reason)"] | join("; ")' <<<"$left")"
    driver_state_set "$t" park_note "the fix round deferred a blocking finding: $(jq -r '[.[] | "\(.blockerId): \(.reason)"] | join("; ")' <<<"$left")$([ -z "$stale_bad" ] || printf '; %s' "$(printf '%s' "$stale_bad" | tr '\n' ' ')")"
    # A PERSON DECIDES WHETHER A BLOCKER IS REALLY ONE. The fixer disagreeing with
    # a grade is a legitimate answer and it is not the driver's to settle; parking
    # it as the driver's own would leave the ticket resumable and the next round
    # free to defer it again.
    driver_state_set "$t" park_cause person
    return "$DRIVER_E_REFUSED"
  fi

  ncleared=$(jq -r '[.cleared[]?] | length' "$ans")
  local fails="" rec="$d/steps/fix.proofs.jsonl"
  printf '%s' "$stale_recs" > "$rec"
  i=0
  while [ "$i" -lt "${ncleared:-0}" ]; do
    bid=$(jq -r --argjson i "$i" '.cleared[$i].blockerId // "?"' "$ans")
    tfile=$(jq -r --argjson i "$i" '.cleared[$i].test.file // ""' "$ans")
    tcmd=$(jq -r  --argjson i "$i" '.cleared[$i].command // ""' "$ans")
    tsha=$(jq -r  --argjson i "$i" '.cleared[$i].testCommit // ""' "$ans")
    isha=$(jq -r  --argjson i "$i" '.cleared[$i].implCommit // ""' "$ans")
    i=$((i+1))
    if { [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; } && [ "${bid#polish-}" != "$bid" ]; then
      _driver_fix_polish_back "$t" "$review" "$bid" "cleared with no test to prove it"; continue
    fi
    if [ -z "$tfile" ] || [ -z "$tcmd" ] || [ -z "$tsha" ] || [ -z "$isha" ]; then
      driver_say "✋ fix '$bid' names no test to prove it (test.file, command, testCommit and implCommit)."
      fails="$fails- $bid: names no test.file, command, testCommit and implCommit
"
      bad=1; continue
    fi
    why=""; prc=0
    why=$(driver_prove_red_green "$wt" "$tfile" "$tsha" "$isha" "$tcmd") || prc=$?
    case "$prc" in
      8) driver_say "🛑 fix $bid — $why. Back on the queue, not sent round again."
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_BUSY" ;;
      0) driver_say "   fix $bid — $why"
         jq -nc --arg b "$bid" --arg w "$why" '{blockerId:$b, proof:"red-green", pmAnswer:null, why:$w}' >> "$rec" ;;
      5) driver_say "✋ fix $bid — $why"
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_REFUSED" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) if [ "${bid#polish-}" != "$bid" ]; then
           _driver_fix_polish_back "$t" "$review" "$bid" "its test did not prove it red then green"; continue
         fi
         driver_say "✋ fix $bid — $why"; bad=1
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
      8) driver_say "🛑 fix $bid — $why. Back on the queue, not sent round again."
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_BUSY" ;;
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
  # A NON-TEST PROOF THE MACHINE CHECKS: the commit is only docs, comments, wording or
  # tests, read off its diff; a test-only one also turns its test red with a mutation.
  local nauto
  nauto=$(jq -r '[.autoProofs[]?] | length' "$ans" 2>/dev/null)
  i=0
  while [ "$i" -lt "${nauto:-0}" ]; do
    e=$(jq -c --argjson i "$i" '.autoProofs[$i]' "$ans"); i=$((i+1))
    bid=$(jq -r '.blockerId // "?"' <<<"$e"); kind=$(jq -r '.kind // ""' <<<"$e")
    why=""; prc=0
    why=$(_driver_fix_auto_proof "$wt" "$trunk" "$review" "$e") || prc=$?
    case "$prc" in
      8) driver_say "🛑 fix $bid — $why. Back on the queue, not sent round again."
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_BUSY" ;;
      0) driver_say "   fix $bid — $kind, checked by the driver — $why"
         jq -nc --arg b "$bid" --arg k "$kind" --arg c "$(jq -r '.commit' <<<"$e")" --arg w "$why" \
           '{blockerId:$b, proof:(if $k == "test-only" then "mutation" else "commit" end), kind:$k, commit:$c, pmAnswer:null, why:$w}' >> "$rec" ;;
      5) driver_say "✋ fix $bid — $why"
         driver_state_set "$t" park_note "$why"
         return "$DRIVER_E_REFUSED" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) driver_say "✋ fix $bid — the $kind proof is not accepted: $why"; bad=1
         fails="$fails- $bid: the $kind proof is not accepted: $(printf '%s' "$why" | cut -c1-1000)
" ;;
    esac
  done
  # A FINDING CLEARED BY EDITING THE DESCRIPTION is proved on the description: both
  # versions read from GitHub here, never the fixer's own run of the check.
  local nbody bpr
  nbody=$(jq -r '[.bodyProofs[]?] | length' "$ans" 2>/dev/null)
  bpr=$(driver_state_get "$t" pr)
  i=0
  while [ "$i" -lt "${nbody:-0}" ]; do
    e=$(jq -c --argjson i "$i" '.bodyProofs[$i]' "$ans"); i=$((i+1))
    bid=$(jq -r '.blockerId // "?"' <<<"$e")
    why=""; prc=0
    why=$(_driver_fix_body_proof "$wt" "$trunk" "$bpr" "$review" "$e" "$d/steps") || prc=$?
    case "$prc" in
      0) driver_say "   fix $bid — proved on the PR description: $why"
         jq -nc --arg b "$bid" --arg w "$why" --arg c "$(jq -r '.command' <<<"$e")" '{blockerId:$b, proof:"pr-body", pmAnswer:null, command:$c, why:$w}' >> "$rec" ;;
      4) driver_say "✋ fix $bid — $why"
         return "$DRIVER_E_TIMEOUT" ;;
      *) driver_say "✋ fix $bid — the description proof is not accepted: $why"; bad=1
         fails="$fails- $bid: the description proof is not accepted: $(printf '%s' "$why" | cut -c1-1000)
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

  driver_say "   fix: $((ncleared + ${npm:-0} + ${nauto:-0} + ${nbody:-0})) finding(s) cleared — $ncleared proved red before green, ${npm:-0} by a proof a PM answer allowed and the driver checked, ${nauto:-0} by a docs/comment/wording/test-only proof the driver checked, ${nbody:-0} on the PR description"
  return "$DRIVER_OK"
}
