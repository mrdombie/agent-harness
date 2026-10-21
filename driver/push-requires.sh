#!/usr/bin/env bash
# push-requires.sh — the reviews a project's own pre-push insists on, run and
# recorded by the driver rather than left for a person.
#
#   driver_push_requires <ticket>   0 = every requirement satisfied
#
# WHY THIS EXISTS. On 2026-09-28 the step-runner built a screen ticket test-first,
# proved two tasks red-then-green, and then could not push a single commit:
#
#   ✗ check:ui-gate-attested — this diff touches UI with no matching verdict.
#
# That project requires a `UI-Gate:` and a `Design-Critic:` trailer on any branch
# whose diff touches a screen, written from an INDEPENDENT reviewer's own output.
# No step in the order produced one, so `park` and `ship` both failed to push for
# every screen ticket there has ever been, and nine commits stayed inside a
# worktree.
#
# A PROJECT'S PRE-PUSH REQUIREMENTS ARE A PROJECT FACT, exactly like its gates and
# its `worktree.prepare`. They live in the SAME row of harness.json that
# `/agent-harness:finish` reads, because an interactive finish and this unattended
# walk ask different questions of the SAME reviewer, and two keys naming the same
# set of reviewers is two places for them to disagree about which exist:
#
#   "review": { "attest": {
#     "ui-gate": {
#       "owed":   "<the command finish runs: is this reviewer owed, and at what fingerprint>",
#       "review": "<a command that runs this project's reviewer and prints its verdict>",
#       "record": "<a command that reads that output on stdin and writes the trailer>"
#   } } }
#
# In place of `review`, a row may name an `agent` ("agent-harness:frontend-gate"):
# the driver then runs that reviewer itself — one `claude -p --agent`, the lean flags
# every step carries, the diff and renders on stdin, its spend under
# usage["attest-<name>"] — and hands its answer to `record` exactly as a `review`
# command's output would be (#11172). `"needsRenders": true` marks a reviewer that
# judges pictures: the driver never runs it — its verdict is owed on the pull request
# to the independent critic (scripts/critic-judge.sh), and recorded as attest_after_push.
#
# `{{SHA}}` and `{{BASE}}` are substituted in `owed` and `record` — the commit the
# reviewer looked at, and the trunk the diff is taken against. A bare string in
# place of the object is the `owed` command alone, which is the shape that shipped
# first. `owed` is asked FIRST, per row: exit 0 means not owed on this diff (or
# already attested) and the reviewer is not run; anything else means owed. An owed
# row with no `review`/`record` is a refusal — the push would be — and
# `driver_push_requires_unpayable` asks that before the review step spends anything.
#
# THE DRIVER NEVER WRITES A VERDICT. It runs the project's reviewer, keeps that
# output verbatim, and hands it to the project's own recorder on stdin. The
# recorder is what decides whether there is a verdict and whether it is one that
# may be written down; a trailer an agent writes for itself is indistinguishable
# from one a reviewer earned, which is the whole reason the attestation exists.
# That is also why this is not `git commit -m "UI-Gate: SHIP"`: the driver has no
# opinion to record.
#
# AND IT IS READ BY EXIT CODE. A recorder that refuses — because the reviewer said
# SPIT-BACK, or said nothing, or reviewed a commit that is no longer HEAD — parks
# the ticket carrying the recorder's own words. A wrapped call here would hand back
# a branch that cannot be pushed and call it a hand-off.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tier.sh" || exit 1
# driver_record_usage: an agent-form reviewer is a model call, and its spend is recorded like one.
type driver_record_usage >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ai-step.sh" || exit 1

# _driver_owed <ticket> <name> <owed-cmd> <tree> <trunk> — the project's own "is
# this reviewer owed" check, bounded, its output kept in the run record and in
# DRIVER_OWED_OUT. Returns its exit code: 0 not owed (or attested), 124 a hang,
# anything else owed. `{{SHA}}` and `{{BASE}}` are filled as in `record`.
_driver_owed() {
  local t="$1" name="$2" owed="$3" wt="$4" trunk="$5" cmd f rc=0
  f="$(driver_state_dir "$t")/steps/owed-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-').txt"
  cmd=$(printf '%s' "$owed" | sed -e "s|{{SHA}}|$(git -C "$wt" rev-parse HEAD 2>/dev/null)|g" -e "s|{{BASE}}|$trunk|g")
  ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) > "$f" 2>&1 || rc=$?
  DRIVER_OWED_OUT="$f"
  if [ "$rc" -eq 124 ]; then
    driver_say "✋ push-requires: this project's check for whether '$name' is owed did not return within ${DRIVER_CMD_TIMEOUT}s."
    driver_state_set "$t" park_note "this project's '$name' owed check did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
  fi
  return "$rc"
}

# _driver_attest_agent <ticket> <name> <agent> <tree> <trunk> <out> — run a named
# reviewer agent directly on this change, with the lean flags every step carries, and
# leave its final answer — verbatim, nothing added — in <out> for the project's
# recorder. Its spend is recorded under usage["attest-<name>"] and counted in .spend.
# Returns claude's exit code, or 124 on a hang.
_driver_attest_agent() {
  local t="$1" name="$2" agent="$3" wt="$4" trunk="$5" out="$6" d slot prompt log rc=0 diff renders
  d="$(driver_state_dir "$t")/steps"; slot="attest-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-')"
  prompt="$d/$slot.prompt"; log="$d/$slot.log"
  local cap full
  cap=$(driver_opt review.diffBytes 400000)
  case "$cap" in ''|*[!0-9]*|0) driver_say "⚠ push-requires: harness.json's review.diffBytes is '${cap}', which is not a number of bytes, so the default 400000 is used."; cap=400000 ;; esac
  full=$(git -C "$wt" diff "$trunk"...HEAD 2>/dev/null)
  diff=$(printf '%s' "$full" | head -c "$cap")
  # A CUT DIFF IS SAID. A reviewer handed part of a change reviews what it can see.
  [ "$(printf '%s' "$full" | wc -c)" -gt "$cap" ] && diff="$diff
(diff cut at $cap bytes — run \`git diff $trunk...HEAD\` in this tree for the rest)"
  renders=$(driver_state_get "$t" renders)
  {
    printf 'You are the %s reviewer for ticket #%s. Review this change in the worktree you are in (the diff is against %s).\n\n' "$name" "$t" "$trunk"
    printf 'Your whole answer is handed, verbatim, to this project'"'"'s recorder. Lead with exactly one line, `VERDICT: SHIP` or `VERDICT: SPIT-BACK`, then your findings, each graded Critical, Major, Minor or Nit with a file and line.\n\n'
    # THE ROUND'S RULE, the one the review step applies: a reviewer that blocks on a Minor
    # the round defers parks a run the review step would have shipped (#13044).
    printf '## What blocks in this round\n\nThis is review round %s. In it, only %s findings block: say SPIT-BACK when at least one of those is open, and SHIP otherwise. Still list every lower-graded finding under its grade; the driver puts it on the screen'"'"'s polish list, and a Nit is dropped.\n\n' \
      "${DRIVER_ATTEST_ROUND:-1}" "$(driver_blocking_grades "${DRIVER_ATTEST_GROUND:-1}" | sed 's/ /, /g')"
    if [ -s "$(_driver_attest_deferred_file "$t" "$name")" ]; then
      printf '## Already deferred this round\n\nYour last answer said SPIT-BACK on these alone, and none blocks in this round. They are on the polish list; do not count them toward the verdict:\n\n%s\n\n' "$(cat "$(_driver_attest_deferred_file "$t" "$name")")"
    fi
    printf '## Renders of the screens it touches\n\n%s\n\n' "${renders:-(none were taken)}"
    printf '## The diff\n\n```diff\n%s\n```\n' "$diff"
  } > "$prompt"
  driver_lean_args "$wt" "attest"
  # An API error is retried once and then is the machine's, as every step's call is.
  local try err
  for try in 1 2; do
    rc=0
    ( cd "$wt" && export HARNESS_DRIVER_RUN="$t:$slot" && \
      driver_bounded_argv "$DRIVER_CMD_TIMEOUT" "$prompt" "$DRIVER_CLAUDE" -p --output-format stream-json --verbose \
        --name "$slot" --agent "$agent" --permission-mode "$DRIVER_PERMISSION_MODE" "${DRIVER_LEAN_ARGS[@]}" --add-dir "$wt" \
    ) > "$log" 2>"$log.err" || rc=$?
    driver_record_usage "$t" "$slot" "$log" "$prompt"
    driver_usage_wall "$t" "$slot" "$log" && return "$DRIVER_E_USAGE"
    [ "$rc" -ne 124 ] || break
    err=$(driver_api_error "$log") || break
    if [ "$try" -eq 2 ]; then
      driver_say "✋ push-requires: the '$name' reviewer's call failed at the API twice — $err. A machine fault, not a question."
      driver_state_set "$t" park_note "machine fault, nothing to answer: this project's '$name' reviewer call failed at the API twice ($err). The next run tries again."
      return "$DRIVER_E_MACHINE"
    fi
    driver_say "↻ push-requires: the '$name' reviewer's call failed at the API — $err. Trying once more in ${DRIVER_API_RETRY_SEC:-30}s."
    sleep "${DRIVER_API_RETRY_SEC:-30}"
  done
  jq -Rrs '[ split("\n")[] | fromjson? // empty | select(.type == "result") ] | last | .result // empty' "$log" > "$out" 2>/dev/null
  return "$rc"
}

# _driver_first_line <file> — the first line that says something: a ✗/✓ line when
# there is one, else the first non-blank line, cut to fit a park note.
_driver_first_line() {
  local l; l=$(grep -m1 -E '✗|✓' "$1" 2>/dev/null)
  [ -n "$l" ] || l=$(grep -m1 -v '^[[:space:]]*$' "$1" 2>/dev/null)
  printf '%s' "${l:-(it printed nothing)}" | sed 's/^[[:space:]]*//' | cut -c1-300
}

# _driver_attest_graded <reviewer-output> — the reviewer's findings, one JSON object per
# line {grade, file, line, summary}, read off its grade headings ("**Major (2):**",
# "## 🔴 Major (0)"). A heading's count caps its section; a section with fewer cited
# files than its count is padded with the answer itself. No heading at all prints nothing.
_driver_attest_graded() {
  awk '
    function flush() { while (sec != "" && got < want) { emit("", 0, verdict); } }
    function emit(f, l, s) { gsub(/\t/, " ", s); printf "%s\t%s\t%s\t%s\n", sec, f, l, substr(s, 1, 240); got++ }
    function clean(x) { gsub(/[`*|#]/, " ", x); gsub(/[[:space:]]+/, " ", x); sub(/^ /, "", x); sub(/ $/, "", x); return x }
    NR == 1 || verdict == "" { if ($0 ~ /VERDICT:/) { verdict = $0; sub(/.*VERDICT:[^A-Za-z]*[A-Za-z-]+[^A-Za-z]*/, "", verdict); verdict = clean(verdict) } }
    {
      h = $0; sub(/^[^A-Za-z]*/, "", h)
      if (match(h, /^(Critical|Major|Minor|Nit)s?[*:[:space:]]*\([0-9]+\)/)) {
        flush()
        g = substr(h, 1, RLENGTH); n = g; sub(/\).*/, "", n); sub(/.*\(/, "", n)
        sub(/[s*:[:space:]]*\(.*/, "", g); sec = tolower(g); want = n + 0; got = 0; pend = ""
        next
      }
      if (sec == "" || got >= want) next
      if (pend != "") { t = clean($0); sub(/^(What is wrong|What.s wrong|What happens|Problem|Issue|Why)[[:space:]:]*/, "", t)
                        if (t != "") { emit(pf, pl, (lbl ? t : pend " — " t)); pend = "" }; next }
      if (match($0, /[][A-Za-z0-9_.\/@-]+\.[A-Za-z0-9]+:[0-9]+/)) {
        ref = substr($0, RSTART, RLENGTH); f = ref; sub(/:[0-9]+$/, "", f); l = ref; sub(/.*:/, "", l)
        rest = $0; sub(/[][A-Za-z0-9_.\/@-]+\.[A-Za-z0-9]+:[0-9]+/, "", rest); rest = clean(rest)
        lbl = (rest ~ /^(Where|File|Location)([^A-Za-z]|$)/)
        if (length(rest) < 24 || lbl) { pend = (rest == "" || lbl ? ref : rest); pf = f; pl = l } else emit(f, l, rest)
      }
    }
    END { if (pend != "") emit(pf, pl, pend); flush() }
  ' "$1" 2>/dev/null | jq -Rc 'split("\t") | {grade: .[0], file: (if .[1] == "" then null else .[1] end),
                               line: (.[2] | tonumber? // 0), summary: .[3]}' 2>/dev/null
}

# _driver_spitback_to_fix <ticket> <name> <reviewer-output> — what a SPIT-BACK costs is
# its GRADES, read as the review step reads its own (the owner, 2026-10-20): round 1
# blocks on Critical, Major and Minor; later rounds on Critical and Major, a Minor goes
# on its screen's polish list, a Nit is dropped. Returns
#   0                 not a SPIT-BACK the fix step can take: the caller parks as before
#   DRIVER_E_REWORK   a blocking finding is on the review record for fix, round left
#   99                nothing in it blocks this round: the rest was deferred, run the
#                     reviewer again (the caller does, once) — never recorded as SHIP
# A finding tagged `auto-fixable: no` is still the fix step's: the tag means "not
# mechanical", and the fix step is a model. Parking on it parked #13044 on one Minor.
_driver_spitback_to_fix() {
  local t="$1" name="$2" out="$3" d round maxr ground block graded blocking defer nb nd
  grep -m1 -E 'VERDICT:' "$out" 2>/dev/null | grep -q 'SPIT-BACK' || return 0
  case " ${DRIVER_STEPS:-} " in *" fix "*) ;; *) return 0 ;; esac
  round="${DRIVER_ATTEST_ROUND:-$(driver_state_count "$t" review)}"; ground="${DRIVER_ATTEST_GROUND:-$round}"
  maxr="${DRIVER_ATTEST_MAXR:-$DRIVER_MAX_REVIEW_ROUNDS}"
  block=$(driver_blocking_grades "$ground")
  d=$(driver_state_dir "$t")
  graded=$(_driver_attest_graded "$out" | jq -sc '.')
  # UNGRADED IS A MAJOR. A SPIT-BACK naming no grade still refused the push.
  [ "$(printf '%s' "$graded" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null \
    || graded=$(jq -nc --arg s "$(grep -m1 -v '^[[:space:]]*$' "$out" | cut -c1-240)" '[{grade: "major", file: null, line: 0, summary: $s}]')
  blocking=$(printf '%s' "$graded" | jq -c --arg b "$block" '[.[] | select(.grade as $g | ($b | split(" ")) | index($g))]')
  defer=$(printf '%s' "$graded" | jq -c --arg b "$block" '[.[] | select(.grade != "nit" and (.grade as $g | ($b | split(" ")) | index($g) | not))]')
  nb=$(printf '%s' "$blocking" | jq 'length'); nd=$(printf '%s' "$defer" | jq 'length')
  # ONCE A ROUND: the run again does not put the same Minor on the list twice.
  [ -s "$(_driver_attest_deferred_file "$t" "$name")" ] && { defer='[]'; nd=0; }
  if [ "$nb" -gt 0 ] && [ "${round:-0}" -gt "$maxr" ]; then
    driver_say "   push-requires: '$name' said SPIT-BACK with $nb blocking ($block) finding(s) and the $maxr review round(s) are spent — parking with its findings"
    return 0
  fi
  [ -f "$d/steps/review.json" ] || return 0
  local fallback; fallback="(the '$name' reviewer's answer)"
  jq --argjson add "$(printf '%s' "$blocking $defer" | jq -sc 'add')" --arg name "$name" --arg r "$round" \
     --arg fb "$fallback" --arg body "$(head -c 12000 "$out")" \
     '.findings = ((.findings // []) + [$add | to_entries[] | .value as $x | {
        id: ("attest-\($name)-\($r)-\(.key)"), file: ($x.file // $fb), line: ($x.line // 0), grade: $x.grade,
        summary: ("\($name): " + ($x.summary // "said SPIT-BACK")),
        reason: ("this project'"'"'s pre-push refuses the push until the \($name) reviewer passes the change"),
        fix: ("Clear this finding as the reviewer proposes. Its whole answer:\n" + $body)}])' \
     "$d/steps/review.json" > "$d/steps/review.json.tmp" 2>/dev/null \
    && mv "$d/steps/review.json.tmp" "$d/steps/review.json" || { rm -f "$d/steps/review.json.tmp"; return 0; }
  # THE REVIEW STEP'S OWN DEFERRAL, so a gate's Minor lands where a review's does —
  # once a round (set above).
  if [ "$nd" -gt 0 ]; then
    if type _driver_review_defer >/dev/null 2>&1; then
      _driver_review_defer "$t" "$d/steps/review.json" "$ground"
    else
      printf '%s' "$defer" | jq -c --argjson r "$round" '.[] | {grade, file, line, summary, round: $r, list: ""}' >> "$d/steps/review.deferred.jsonl"
      jq --argjson n "$nd" '.findings = ((.findings // [])[: ((.findings | length) - $n)])' "$d/steps/review.json" > "$d/steps/review.json.tmp" \
        && mv "$d/steps/review.json.tmp" "$d/steps/review.json"
    fi
    printf '%s' "$defer" | jq -r '.[] | "- [\(.grade)] \(.file // "?"):\(.line // 0) — \(.summary // "")"' > "$(_driver_attest_deferred_file "$t" "$name")"
  fi
  if [ "$nb" -eq 0 ]; then
    driver_say "↻ push-requires: '$name' said SPIT-BACK on nothing that blocks in review round $round ($block) — $nd deferred, the reviewer runs again"
    return 99
  fi
  jq '.verdict = "BLOCKED"' "$d/steps/review.json" > "$d/steps/review.json.tmp" && mv "$d/steps/review.json.tmp" "$d/steps/review.json"
  driver_say "↩ push-requires: '$name' said SPIT-BACK with $nb blocking ($block) finding(s) (review round $round of $maxr) — they go to fix, then the review and '$name' run again"
  return "$DRIVER_E_REWORK"
}

# _driver_attest_deferred_file <ticket> <name> — this round's deferred findings, told to
# the reviewer when it runs again.
_driver_attest_deferred_file() {
  printf '%s/steps/attest-%s.deferred.txt' "$(driver_state_dir "$1")" "$(printf '%s' "$2" | tr -cs 'A-Za-z0-9._-' '-')"
}

driver_push_requires() { # <ticket>
  local t="${1:?driver_push_requires: need a ticket}"
  local wt trunk r ptype half name review record d out rc sha before after
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  d="$(driver_state_dir "$t")/steps"; mkdir -p "$d"

  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  # THE SHAPE FIRST. Written as a list or a bare string, `to_entries` errors, the
  # read comes back empty, and an empty read used to mean "this project attests
  # nothing" — a requirement list nothing ran, reporting exactly like a project that
  # has none.
  # `.review.attest` alone is not enough to ask: a `review` written as a STRING
  # makes jq error out, the read comes back empty, and the empty arm below then
  # blames an unreadable harness.json for a file that parses perfectly.
  ptype=$(jq -r '
    (.review // null) as $r
    | if $r == null then "absent"
      elif ($r | type) != "object" then "review is a \($r | type)"
      else (($r.attest // null) | type) end' "$HARNESS_CFG" 2>/dev/null)
  case "$ptype" in
    absent|null) return 0 ;;
    object) : ;;
    '')   driver_say "✋ push-requires: harness.json could not be read ($HARNESS_CFG), so NOTHING this project's pre-push insists on was run."
          driver_state_set "$t" park_note "harness.json could not be read for review.attest ($HARNESS_CFG)"
          return "$DRIVER_E_REFUSED" ;;
    *)    driver_say "✋ push-requires: harness.json says $ptype, and the driver reads an object at review.attest of reviewer name to { owed, review, record }. Nothing ran."
          driver_state_set "$t" park_note "harness.json says $ptype and the driver reads an object at review.attest of reviewer name to { owed, review, record }"
          return "$DRIVER_E_REFUSED" ;;
  esac
  # A row that names ONE half is a requirement nobody can satisfy and nobody would
  # see: named, never dropped in silence.
  half=$(jq -r '(.review.attest // {}) | to_entries[]
                | select((.value | type) == "object")
                | select(((((.value.review // "") + (.value.agent // "")) == "") != (((.value.record // "") == ""))))
                | .key' "$HARNESS_CFG" 2>/dev/null)
  # BOTH A COMMAND AND AN AGENT is two reviewers for one verdict, and only one could run.
  local both; both=$(jq -r '(.review.attest // {}) | to_entries[] | select((.value | type) == "object")
                 | select(((.value.review // "") != "") and ((.value.agent // "") != "")) | .key' "$HARNESS_CFG" 2>/dev/null)
  if [ -n "$both" ]; then
    driver_say "✋ push-requires: review.attest row(s) $(printf '%s\n' "$both" | tr '\n' ' ')name both a review command and an agent. Name one: the driver will not pick for you."
    driver_state_set "$t" park_note "harness.json's review.attest names both review and agent for: $(printf '%s\n' "$both" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi
  if [ -n "$half" ]; then
    driver_say "✋ push-requires: review.attest row(s) $(printf '%s\n' "$half" | tr '\n' ' ')name one of review/agent and record and not the other, so that reviewer can be run and not recorded, or recorded and never run."
    driver_state_set "$t" park_note "harness.json's review.attest names one of review/agent and record and not the other for: $(printf '%s\n' "$half" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi

  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"

  # EVERY ROW, AND THE PROJECT SAYS WHICH ARE OWED. The `owed` command is the
  # project's own answer to "does this diff need this reviewer" — the same one
  # finish asks and the pre-push enforces. Exit 0 is "not owed, or already
  # attested"; anything else is owed. Running every reviewer regardless sent a
  # test-only diff to ui-gate on trial 3 (2026-09-30), the reviewer rightly said
  # there was no UI and gave no verdict, and a ticket the pre-push would have let
  # through parked here. A row with no `owed` is run on every ticket, as before.
  local rows owed orc tier
  # A BUILD THAT DRAWS NOTHING OWES NO PICTURE VERDICT (tier.sh): the critic judges pixels.
  tier=$(driver_change_tier "$t" "$wt" "$trunk" | cut -f1)
  # An existing screen on the baseline route owes no critic verdict: CI's baseline diff decides.
  local route=picture
  [ "$tier" != screen ] || route=$(driver_screen_route "$t" | cut -f1)
  # THE REVIEW ROUND THESE VERDICTS SIT IN, graded as the review step grades it: a
  # tooling build gets one round, read as a later one.
  DRIVER_ATTEST_ROUND=$(driver_state_count "$t" review); DRIVER_ATTEST_GROUND="$DRIVER_ATTEST_ROUND"
  DRIVER_ATTEST_MAXR="$DRIVER_MAX_REVIEW_ROUNDS"
  if [ "$tier" = tooling ]; then DRIVER_ATTEST_MAXR=1; [ "${DRIVER_ATTEST_GROUND:-0}" -ge 2 ] || DRIVER_ATTEST_GROUND=2; fi
  export DRIVER_ATTEST_ROUND DRIVER_ATTEST_GROUND DRIVER_ATTEST_MAXR
  DRIVER_ATTEST_BLOCKING=$(driver_blocking_grades "$DRIVER_ATTEST_GROUND"); export DRIVER_ATTEST_BLOCKING
  rows=$(jq -r '(.review.attest // {}) | to_entries[]
                | (if (.value | type) == "string" then {owed: .value} else .value end) as $v
                | [.key, ($v.owed // ""), ($v.review // ""), ($v.record // ""), ($v.agent // ""), (if $v.needsRenders == true then "yes" else "" end)] | join("\u001f")' "$HARNESS_CFG" 2>/dev/null)
  [ -n "$rows" ] || return 0

  # A UNIT SEPARATOR, NOT A TAB. Tab is whitespace to `read`, so an empty field
  # between two tabs collapses and every later field shifts left: a row with no
  # `review` read its recorder as the reviewer and ran it (#11172).
  while IFS=$'\x1f' read -r name owed review record agent needs_renders; do
    [ -n "$name" ] || continue
    [ -n "$owed$review$agent" ] || continue
    # AN AGENT IS A REVIEWER THE DRIVER RUNS ITSELF. `review` is a command the project
    # wrote; `agent` names the reviewer, and the driver runs it directly — one session,
    # the same lean flags as every step, its spend on the record (#11172). The command
    # form ran `claude -p /agent-harness:ui-gate`, a whole session whose job was to
    # start the frontend-gate agent: two fixed loads for one review, the first unseen.
    [ -n "$agent" ] && review="agent:$agent"

    if { [ "$needs_renders" = "yes" ] || [ "$agent" = "agent-harness:design-critic" ]; } && [ "$tier" != screen ]; then
      driver_say "   push-requires: '$name' judges screens, and this is a $tier build that changes none — not owed"
      continue
    fi
    if { [ "$needs_renders" = "yes" ] || [ "$agent" = "agent-harness:design-critic" ]; } && [ "$route" = baseline ]; then
      driver_say "   push-requires: '$name' judges screens, and this existing screen takes the baseline route — CI diffs it against its last approved shots, so not owed"
      continue
    fi

    if [ -n "$owed" ]; then
      orc=0; _driver_owed "$t" "$name" "$owed" "$wt" "$trunk" || orc=$?
      case "$orc" in
        0)  driver_say "   push-requires: '$name' is not owed on this diff — $(_driver_first_line "$DRIVER_OWED_OUT")"
            continue ;;
        124) return "$DRIVER_E_TIMEOUT" ;;
      esac
      # OWED, AND NOTHING HERE CAN PAY IT. A row carrying `owed` alone is the shape
      # that shipped first: finish runs it with a person. Unattended, it was skipped
      # in silence, and a screen ticket learned at the push — after review, after
      # the spend — that it needed a verdict no step produces (#10955, trial 3).
      if [ -z "$review" ]; then
        driver_say "✋ push-requires: '$name' is owed on this diff and harness.json gives the driver no review/record to run for it — $(_driver_first_line "$DRIVER_OWED_OUT")"
        driver_state_set "$t" park_note "this project's pre-push requires a '$name' verdict on this diff, and harness.json's review.attest.$name names no review/record the driver can run, so only a person can earn it: $(_driver_first_line "$DRIVER_OWED_OUT")"
        return "$DRIVER_E_REFUSED"
      fi
    fi

    # A REVIEWER THAT JUDGES PICTURES IS NEVER RUN BY THE BUILD. Its verdict comes from
    # the independent critic (scripts/critic-judge.sh, started by the coordinator), on
    # CI's pinned shots of the head, after the push. On one PR the repair run ran the
    # critic on what it chose to show it and committed SHIP; the independent critic on
    # CI's shots of the same fingerprint said SLOP with four Majors. A verdict written by
    # the run whose work it judges is an agent clearing its own sign-off — so this run
    # neither takes the pictures for it nor records it, whatever renders it holds.
    if [ "$needs_renders" = "yes" ] || [ "$agent" = "agent-harness:design-critic" ]; then
      driver_state_set "$t" attest_after_push "$name"
      driver_say "⏳ push-requires: '$name' judges screens, so its verdict is owed on the pull request to the independent critic, on CI's pinned shots after the push — never recorded by this run"
      continue
    fi

    # The reviewer, in the ticket's worktree, with its output kept whole.
    out="$d/verdict-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-').txt"
    rm -f "$(_driver_attest_deferred_file "$t" "$name")"
    local again=0
    # ONCE MORE, AT MOST: a SPIT-BACK on nothing this round blocks is run again with
    # the deferral stated, and only the reviewer's own SHIP is ever recorded.
    while :; do
    export DRIVER_ATTEST_DEFERRED; DRIVER_ATTEST_DEFERRED="$(_driver_attest_deferred_file "$t" "$name")"
    # A STEP OF THE WALK, NOT A PERSON'S TURN. The reviewer is its own `claude -p`,
    # so without this the kit's sign-off Stop hook fires on it and its whole answer
    # comes back as the banner: no VERDICT line, and a test-only ticket parked here
    # after passing every other step (trial 3, 2026-09-30).
    if [ -n "$agent" ]; then
      rc=0; _driver_attest_agent "$t" "$name" "$agent" "$wt" "$trunk" "$out" || rc=$?
    else
      ( cd "$wt" && export HARNESS_DRIVER_RUN="$t:attest-$name" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$review" ) > "$out" 2>&1; rc=$?
    fi
    [ "$rc" -ne "$DRIVER_E_USAGE" ] || return "$DRIVER_E_USAGE"
    [ "$rc" -ne "$DRIVER_E_MACHINE" ] || return "$DRIVER_E_MACHINE"
    if [ "$rc" -eq 124 ]; then
      driver_say "✋ push-requires: the '$name' reviewer did not return within ${DRIVER_CMD_TIMEOUT}s."
      driver_state_set "$t" park_note "this project's '$name' reviewer did not return within ${DRIVER_CMD_TIMEOUT}s: $review"
      return "$DRIVER_E_TIMEOUT"
    fi
    if [ ! -s "$out" ]; then
      # A REVIEWER THAT SAID NOTHING IS NOT A REVIEWER THAT APPROVED. Handing an
      # empty file to the recorder would make its refusal read as the recorder's
      # fault rather than the reviewer's.
      driver_say "✋ push-requires: the '$name' reviewer produced no output (exit $rc), so there is no verdict to record."
      driver_state_set "$t" park_note "this project's '$name' reviewer ('$review') exited $rc and printed nothing, so no verdict exists to record"
      return "$DRIVER_E_REFUSED"
    fi
    driver_say "   push-requires: the '$name' reviewer ran (exit $rc), $(wc -l < "$out" | tr -d ' ') line(s) of output"

    # The recorder, reading that output on stdin. Its exit code is the verdict on
    # the verdict.
    sha=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    before="$sha"
    local cmd; cmd=$(printf '%s' "$record" | sed -e "s|{{SHA}}|$sha|g" -e "s|{{BASE}}|$trunk|g")
    rc=0
    ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" < "$out" ) > "$out.recorded" 2>&1 || rc=$?
    if [ "$rc" -eq 124 ]; then
      # A HANG IS NOT A REFUSAL, on this side of the call as much as on the other.
      # Read as one, the park says the recorder refused a verdict it never saw, and
      # the operator goes looking for a finding that does not exist.
      driver_say "✋ push-requires: the '$name' recorder did not return within ${DRIVER_CMD_TIMEOUT}s."
      driver_state_set "$t" park_note "this project's '$name' recorder did not return within ${DRIVER_CMD_TIMEOUT}s: $cmd"
      return "$DRIVER_E_TIMEOUT"
    fi
    if [ "$rc" -ne 0 ]; then
      # A SPIT-BACK IS THE GATE WORKING, so it goes to fix like a review's own finding:
      # #13461 and #13305 parked on one. Its findings go on the
      # review record at their grades, and the walk loops review -> fix -> re-review in the
      # round limit. It parks only past the limit with a blocking finding left.
      local srv; srv=0; _driver_spitback_to_fix "$t" "$name" "$out" || srv=$?
      if [ "$srv" -eq 99 ] && [ "$again" -eq 0 ]; then again=1; continue; fi
      [ "$srv" -eq 0 ] || [ "$srv" -eq 99 ] || return "$srv"
      driver_say "✋ push-requires: '$name' could not be recorded — $(tr '\n' ' ' < "$out.recorded" | cut -c1-400)"
      driver_state_set "$t" park_note "this project's pre-push requires a '$name' verdict and the recorder refused it: $(tr '\n' ' ' < "$out.recorded" | cut -c1-400)"
      return "$DRIVER_E_REFUSED"
    fi
    break
    done
    after=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
    if [ "$after" = "$before" ]; then
      driver_say "   push-requires: '$name' recorded nothing new — $(tr '\n' ' ' < "$out.recorded" | cut -c1-200)"
    else
      driver_say "   push-requires: '$name' recorded at $(printf '%s' "$after" | cut -c1-8) — $(tr '\n' ' ' < "$out.recorded" | cut -c1-200)"
    fi

    # RECORDED IS NOT ATTESTED. The recorder exiting 0 says it wrote something; the
    # project's own check is what the push will ask, so it is asked here too. A
    # trailer at the wrong fingerprint, or on a commit the check does not read,
    # records cleanly and is refused at the push after everything else is spent.
    if [ -n "$owed" ]; then
      orc=0; _driver_owed "$t" "$name" "$owed" "$wt" "$trunk" || orc=$?
      case "$orc" in
        0)  : ;;
        124) return "$DRIVER_E_TIMEOUT" ;;
        *)  driver_say "✋ push-requires: '$name' was recorded and this project's own check still says it is owed — $(_driver_first_line "$DRIVER_OWED_OUT")"
            driver_state_set "$t" park_note "the '$name' verdict was recorded, and this project's check ('$owed') still says it is owed: $(_driver_first_line "$DRIVER_OWED_OUT")"
            return "$DRIVER_E_REFUSED" ;;
      esac
    fi
  done <<EON
$rows
EON
  # THE HEAD THESE VERDICTS DESCRIBE. A recorder binds a verdict to the commit it
  # reviewed, so a later commit — a park's own work-in-progress commit is the one
  # that actually happens — makes every trailer on the branch describe a diff that
  # is not the diff being pushed. The ship step compares this against HEAD and
  # runs the requirements again when they differ; without it a resumed run walks
  # straight to `ship`, the push is refused for ever, and nothing re-records.
  driver_state_set "$t" push_requires_at "$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  return "$DRIVER_OK"
}

# driver_push_requires_unpayable <ticket> — 0 unless a row the driver cannot run
# (`owed` and no `review`/`record`) is owed on this diff. Cheap: it runs only those
# rows' `owed` commands. The review step asks it before the model, because the full
# requirement run comes after the review is paid for, and #10955 learned it needed
# a design-critic verdict nobody could give only when its push was refused.
driver_push_requires_unpayable() { # <ticket>
  local t="${1:?driver_push_requires_unpayable: need a ticket}" wt trunk rows name owed orc
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  mkdir -p "$(driver_state_dir "$t")/steps"
  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"
  rows=$(jq -r '(.review // {}) | if type == "object" then (.attest // {}) else {} end
                | if type == "object" then to_entries[] else empty end
                | (if (.value | type) == "string" then {owed: .value} elif (.value | type) == "object" then .value else {} end) as $v
                | select(($v.owed // "") != "" and ($v.review // "") == "" and ($v.agent // "") == "" and ($v.record // "") == "")
                | [.key, $v.owed] | @tsv' "$HARNESS_CFG" 2>/dev/null)
  while IFS=$'\t' read -r name owed; do
    [ -n "$name" ] || continue
    orc=0; _driver_owed "$t" "$name" "$owed" "$wt" "$trunk" || orc=$?
    case "$orc" in
      0)   : ;;
      124) return "$DRIVER_E_TIMEOUT" ;;
      *)   driver_say "✋ push-requires: '$name' is owed on this diff and harness.json gives the driver no review/record to run for it — $(_driver_first_line "$DRIVER_OWED_OUT"). Stopping before the review is paid for."
           driver_state_set "$t" park_note "this project's pre-push requires a '$name' verdict on this diff, and harness.json's review.attest.$name names no review/record the driver can run, so only a person can earn it: $(_driver_first_line "$DRIVER_OWED_OUT")"
           return "$DRIVER_E_REFUSED" ;;
    esac
  done <<EON
$rows
EON
  return "$DRIVER_OK"
}
