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
# judges pictures: with no render on the record it refuses instead of running.
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
    printf '## Renders of the screens it touches\n\n%s\n\n' "${renders:-(none were taken)}"
    printf '## The diff\n\n```diff\n%s\n```\n' "$diff"
  } > "$prompt"
  driver_lean_args "$wt" "attest"
  ( cd "$wt" && export HARNESS_DRIVER_RUN="$t:$slot" && \
    driver_bounded_argv "$DRIVER_CMD_TIMEOUT" "$prompt" "$DRIVER_CLAUDE" -p --output-format stream-json --verbose \
      --name "$slot" --agent "$agent" --permission-mode "$DRIVER_PERMISSION_MODE" "${DRIVER_LEAN_ARGS[@]}" --add-dir "$wt" \
  ) > "$log" 2>"$log.err" || rc=$?
  driver_record_usage "$t" "$slot" "$log" "$prompt"
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
  local rows owed orc
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

    # A REVIEWER THAT JUDGES PICTURES IS NOT RUN WITHOUT ANY. Handed "(none were
    # taken)", it is being asked to guess, and a guess recorded as SHIP is the
    # attestation nobody earned. `needsRenders` makes that a refusal, by name.
    if [ "$needs_renders" = "yes" ] && ! driver_state_get "$t" renders | awk -F'\t' '$3 == "light" || $3 == "dark" { found = 1 } END { exit !found }'; then
      driver_say "✋ push-requires: '$name' judges rendered screens and none were taken for this change, so only a person can earn it."
      driver_state_set "$t" park_note "this project's pre-push requires a '$name' verdict, '$name' judges rendered screens, and no render was taken for this change: $(driver_state_get "$t" renders | head -1 | cut -c1-300)"
      return "$DRIVER_E_REFUSED"
    fi

    # The reviewer, in the ticket's worktree, with its output kept whole.
    out="$d/verdict-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-').txt"
    # A STEP OF THE WALK, NOT A PERSON'S TURN. The reviewer is its own `claude -p`,
    # so without this the kit's sign-off Stop hook fires on it and its whole answer
    # comes back as the banner: no VERDICT line, and a test-only ticket parked here
    # after passing every other step (trial 3, 2026-09-30).
    if [ -n "$agent" ]; then
      rc=0; _driver_attest_agent "$t" "$name" "$agent" "$wt" "$trunk" "$out" || rc=$?
    else
      ( cd "$wt" && export HARNESS_DRIVER_RUN="$t:attest-$name" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$review" ) > "$out" 2>&1; rc=$?
    fi
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
      driver_say "✋ push-requires: '$name' could not be recorded — $(tr '\n' ' ' < "$out.recorded" | cut -c1-400)"
      driver_state_set "$t" park_note "this project's pre-push requires a '$name' verdict and the recorder refused it: $(tr '\n' ' ' < "$out.recorded" | cut -c1-400)"
      return "$DRIVER_E_REFUSED"
    fi
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
