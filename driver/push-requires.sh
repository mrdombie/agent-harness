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
# `{{SHA}}` and `{{BASE}}` are substituted in `record` — the commit the reviewer
# looked at, and the trunk the diff is taken against. A bare string in place of the
# object is the `owed` command alone, which is the shape that shipped first; such a
# row is advisory here and enforced by finish.
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

driver_push_requires() { # <ticket>
  local t="${1:?driver_push_requires: need a ticket}"
  local wt trunk r ptype names half name review record d out rc sha before after
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
  # Only the rows that name BOTH halves. A row carrying `owed` alone is the shape
  # that shipped first: finish enforces it, and this walk has nothing to run for it.
  names=$(jq -r '(.review.attest // {}) | to_entries[]
                 | select((.value | type) == "object")
                 | select(((.value.review // "") != "") and ((.value.record // "") != ""))
                 | .key' "$HARNESS_CFG" 2>/dev/null)
  # A row that names ONE half is a requirement nobody can satisfy and nobody would
  # see: named, never dropped in silence.
  half=$(jq -r '(.review.attest // {}) | to_entries[]
                | select((.value | type) == "object")
                | select((((.value.review // "") == "") != (((.value.record // "") == ""))))
                | .key' "$HARNESS_CFG" 2>/dev/null)
  if [ -n "$half" ]; then
    driver_say "✋ push-requires: review.attest row(s) $(printf '%s' "$half" | tr '\n' ' ')name one of review/record and not the other, so that reviewer can be run and not recorded, or recorded and never run."
    driver_state_set "$t" park_note "harness.json's review.attest names one of review/record and not the other for: $(printf '%s' "$half" | tr '\n' ' ')"
    return "$DRIVER_E_REFUSED"
  fi
  [ -n "$names" ] || return 0

  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    review=$(jq -r --arg k "$name" '.review.attest[$k].review // ""' "$HARNESS_CFG" 2>/dev/null)
    record=$(jq -r --arg k "$name" '.review.attest[$k].record // ""' "$HARNESS_CFG" 2>/dev/null)

    # The reviewer, in the ticket's worktree, with its output kept whole.
    out="$d/verdict-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-').txt"
    # A STEP OF THE WALK, NOT A PERSON'S TURN. The reviewer is its own `claude -p`,
    # so without this the kit's sign-off Stop hook fires on it and its whole answer
    # comes back as the banner: no VERDICT line, and a test-only ticket parked here
    # after passing every other step (trial 3, 2026-09-30).
    ( cd "$wt" && export HARNESS_DRIVER_RUN="$t:attest-$name" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$review" ) > "$out" 2>&1; rc=$?
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
  done <<EON
$names
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
