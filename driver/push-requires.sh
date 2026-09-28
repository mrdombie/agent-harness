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
# its `worktree.prepare`. harness.json declares them:
#
#   "push": { "requires": [
#     { "name":   "ui-gate",
#       "review": "<a command that runs this project's reviewer and prints its verdict>",
#       "record": "<a command that reads that output on stdin and writes the trailer>" }
#   ]}
#
# `{{SHA}}` and `{{BASE}}` are substituted in `record` — the commit the reviewer
# looked at, and the trunk the diff is taken against.
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
  local wt trunk r ptype n i name review record d out rc sha before after
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  d="$(driver_state_dir "$t")/steps"; mkdir -p "$d"

  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  # THE SHAPE FIRST. Written as a bare string or an object, `length` still answers
  # and every per-element read errors into /dev/null — a requirement list nothing
  # ran, reporting exactly like a project that has none.
  # `.push.requires` alone is not enough to ask: a `push` written as a STRING makes
  # jq error out, the read comes back empty, and the empty arm below then blames an
  # unreadable harness.json for a file that parses perfectly. Each shape is named as
  # what it is.
  ptype=$(jq -r '
    (.push // null) as $p
    | if $p == null then "absent"
      elif ($p | type) != "object" then "push is a \($p | type)"
      else (($p.requires // null) | type) end' "$HARNESS_CFG" 2>/dev/null)
  case "$ptype" in
    absent|null) return 0 ;;
    array) : ;;
    '')   driver_say "✋ push-requires: harness.json could not be read ($HARNESS_CFG), so NOTHING this project's pre-push insists on was run."
          driver_state_set "$t" park_note "harness.json could not be read for push.requires ($HARNESS_CFG)"
          return "$DRIVER_E_REFUSED" ;;
    *)    driver_say "✋ push-requires: harness.json says $ptype, and the driver reads a list at push.requires — a list of {name, review, record}. Nothing ran."
          driver_state_set "$t" park_note "harness.json says $ptype and the driver reads a list at push.requires, of {name, review, record}"
          return "$DRIVER_E_REFUSED" ;;
  esac
  n=$(jq -r '.push.requires | length' "$HARNESS_CFG" 2>/dev/null)
  case "${n:-0}" in ''|*[!0-9]*|0) return 0 ;; esac

  trunk="origin/$INTEGRATION_BRANCH"
  git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1 || trunk="$INTEGRATION_BRANCH"

  i=0
  while [ "$i" -lt "$n" ]; do
    name=$(jq -r --argjson i "$i"   '.push.requires[$i].name   // ""' "$HARNESS_CFG" 2>/dev/null)
    review=$(jq -r --argjson i "$i" '.push.requires[$i].review // ""' "$HARNESS_CFG" 2>/dev/null)
    record=$(jq -r --argjson i "$i" '.push.requires[$i].record // ""' "$HARNESS_CFG" 2>/dev/null)
    i=$((i+1))
    if [ -z "$name" ] || [ -z "$review" ] || [ -z "$record" ]; then
      driver_say "✋ push-requires: entry $i of $n names no {name, review, record}, so it did not run."
      driver_state_set "$t" park_note "harness.json's push.requires entry $i of $n is missing name, review or record, so that requirement was never satisfied"
      return "$DRIVER_E_REFUSED"
    fi

    # The reviewer, in the ticket's worktree, with its output kept whole.
    out="$d/verdict-$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-').txt"
    ( cd "$wt" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$review" ) > "$out" 2>&1; rc=$?
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
  done
  return "$DRIVER_OK"
}
