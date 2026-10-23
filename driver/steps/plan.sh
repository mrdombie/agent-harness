#!/usr/bin/env bash
# steps/plan.sh — the AI writes the plan; the driver decides whether it is one it
# can enforce, and puts it where the next reader will find it.
#
#   driver_step_plan <ticket>
#
# Two checks, both from the approved design's guarantee table:
#
#   NO NEW TABLE WITHOUT AN APPROVED DESIGN SPEC. A plan that changes the schema
#   must name the reviewed data model it is changing it to. A database change
#   invented inside a ticket is the one kind of mistake a later ticket cannot
#   undo cheaply, so this refuses rather than asks.
#
#   A PLAN WITH NO TESTS IS NOT A PLAN THIS DRIVER CAN ENFORCE. Every guarantee
#   downstream is built on the build step proving a test red then green. A plan
#   that names none has removed the only thing the driver can check.
#
# And one piece of bookkeeping: the plan is posted as a comment on the ticket,
# never committed into the product repo as a per-ticket document. The comment
# outlives the worktree, which the document would not.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ai-step.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tier.sh" || exit 1

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/size-rules.sh" || exit 1

# _driver_plan_split <ticket> <plan.json> <max> — one ticket per build task, each inheriting the
# parent's priority, area, screen, project and repo labels, filed ready in the plan's order; the
# parent is told and closed as split. 0 when every part was filed; 2 when the ticket is itself a
# part of a split (it builds: a part is never split again). Nothing has been built yet.
_driver_plan_split() {
  local t="$1" ans="$2" max="$3" meta title inherit n i url c kids="" task body l args
  meta=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title,labels,comments 2>/dev/null) || return 1
  title=$(jq -r '.title // ""' <<<"$meta")
  if printf '%s' "$title" | grep -qE ' — part [0-9]+ of [0-9]+: '; then
    driver_say "   plan: $(jq '[.tasks[]?] | length' "$ans") build tasks, but #$t is itself a part of a split — it builds"; return 2
  fi
  inherit=$(jq -r '[.labels[]?.name | select(test("^P[0-9]$|^(area|screen|project|repo|effort):"))] | .[]' <<<"$meta")
  n=$(jq '[.tasks[]?] | length' "$ans")
  # WHAT THE PARENT ALREADY HAS, CARRIED BY LINK, NEVER BY COPY. An approved picture lives in
  # the parent's own comment; a part that re-posted it would be an agent approving its own
  # picture. So the part names it, and picture-fetch.sh follows "split from #<parent>" to that
  # comment, checked there as on the parent. The parent's PM and owner answers ride quoted.
  local carried
  carried=$(jq -r '
    def link: (.url // "") | if . == "" then "" else " (" + . + ")" end;
    [(.comments // [])[] | select((.body // "") | startswith("**Picture for any machine**"))] as $pics
    | [(.comments // [])[] | select((.body // "") | test("^\\*\\*(The owner answered|PM answer|The PM answered)"; "i"))] as $ans
    | (if ($pics | length) > 0 then
         "\n**Approved picture — the parent'"'"'s, by link:** the approval is #'"$t"''"'"'s comment" + ($pics | last | link)
         + ((($pics | last | .body) | capture("picture-approve: sha256=(?<s>[0-9a-f]{64}) file=(?<f>[^ ]+)")?) // {} | if .s then ", `" + .f + "`, sha256 `" + .s[0:12] + "…`" else "" end)
         + ". This part is bound by it; the picture step reads it there.\n"
       else "" end)
    + (if ($ans | length) > 0 then
         "\n**Answers already given on #'"$t"'** (quoted, not asked again):\n"
         + ($ans | map("> " + ((.body // "") | split("\n") | join("\n> ")) + "\n> — " + (.url // "")) | join("\n\n")) + "\n"
       else "" end)' <<<"$meta" 2>/dev/null)
  i=0
  while [ "$i" -lt "$n" ]; do
    task=$(jq -c --argjson i "$i" '.tasks[$i]' "$ans")
    body=$(printf 'Part %s of %s, split from #%s before it was built: its plan had %s build tasks, over `driver.split.maxTasks` (%s). One change, merged on its own.
%s

**This part:** %s

**Files:** %s

**Tests:** %s

Refs #%s
' \
      "$((i+1))" "$n" "$t" "$n" "$max" "$carried" "$(jq -r '.title // "(untitled)"' <<<"$task")" \
      "$(jq -r '[.files[]? | (.path // .) | tostring] | join(", ") | if . == "" then "(none named)" else . end' <<<"$task")" \
      "$(jq -r '[.tests[]? | (.file // .name // .behaviour // .) | tostring] | join("; ") | if . == "" then "(none named)" else . end' <<<"$task")" "$t")
    args=(issue create --repo "$REPO_SLUG" --title "$title — part $((i+1)) of $n: $(jq -r '.title // ""' <<<"$task" | cut -c1-80)" --body "$body" --label "$LBL_READY")
    while IFS= read -r l; do [ -n "$l" ] && args+=(--label "$l"); done <<<"$inherit"
    url=$(swarm_gh "${args[@]}" 2>/dev/null) || { driver_state_set "$t" park_note "split needed: filing part $((i+1)) of $n failed after ${kids:-none} were filed"; return 1; }
    c=${url##*/}; case "$c" in ''|*[!0-9]*) driver_state_set "$t" park_note "split needed: part $((i+1)) came back as '$url'"; return 1 ;; esac
    kids="${kids:+$kids }#$c"
    i=$((i+1))
  done
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "**Split** into $kids — one change each, in this order. Its plan had $n build tasks, over \`driver.split.maxTasks\` ($max), so nothing was built here. Closed as split." >/dev/null 2>&1 || true
  swarm_gh issue close "$t" --repo "$REPO_SLUG" --reason "not planned" >/dev/null 2>&1 || true
  driver_state_set "$t" noop_note "was split into $kids before it built: its plan had $n build tasks, over driver.split.maxTasks ($max)"
  driver_say "✂ plan: $n build tasks, over driver.split.maxTasks ($max) — split into $kids, the parent closed as split"
}

driver_step_plan() { # <ticket>
  local t="${1:?driver_step_plan: need a ticket}"
  local rc ans schema spec ntests
  export DRIVER_TICKET="$t"

  rc=0; driver_ai_step "$t" plan || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$(driver_state_dir "$t")/steps/plan.json"

  # A SCREEN CHANGE WRITES ITS CHECKLIST UP FRONT: per screen state it touches, how it
  # handles loading, failure, a retry in flight, empty and phone width. Sent back once;
  # the review holds the build to it. ~38 of 64 Majors since 22 Oct were these states.
  rc=0; _driver_screen_checklist_due "$t" plan "$ans" \
    "$(jq -r '[.tasks[]?.files[]?.path] | .[]' "$ans")" "$(jq -r '.screenChange // ""' "$ans")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # THE KEYS ARE THE CONTRACT'S KEYS. This read four names briefs/schemas/plan.json
  # does not have — `.schema_change`, `.data_model_spec`, `.tests` and `.files` — and
  # the contract is `additionalProperties: false`, so an answer carrying them was
  # refused by the validator and an answer meeting the contract was refused here.
  # Measured on the 2026-09-27 trial: the kit's own valid example and both real
  # plans all validated, all read `.tests` as length 0, and all three parked on
  # "it names no test". Tests and files live under each task; the schema flag and
  # its model are declared properties, and the contract now carries the rule as
  # well, so the two cannot drift apart again.
  schema=$(jq -r '.schemaChange // false' "$ans")
  spec=$(jq -r '.dataModelSpec // ""' "$ans")
  if [ "$schema" = "true" ] && [ -z "$spec" ]; then
    driver_say "✋ plan: it changes the schema and names no approved data model. A database change comes from a reviewed model, never from inside a ticket."
    return "$DRIVER_E_REFUSED"
  fi

  ntests=$(jq -r '[.tasks[]?.tests[]?] | length' "$ans")
  if [ "${ntests:-0}" -eq 0 ]; then
    driver_say "✋ plan: it names no test. Every guarantee after this one is the build step proving a test red then green; a plan with no test has nothing to prove."
    return "$DRIVER_E_REFUSED"
  fi

  # MORE THAN driver.split.maxTasks BUILD TASKS: split before anything is built. A repair, a
  # resume past build, or a part of an earlier split never is.
  local ntasks tmax
  ntasks=$(jq '[.tasks[]?] | length' "$ans" 2>/dev/null); tmax=$(driver_split_max_tasks)
  case "$ntasks" in ''|*[!0-9]*) ntasks=0 ;; esac
  if [ "$tmax" -gt 0 ] && [ "$ntasks" -gt "$tmax" ] && [ "$(driver_state_get "$t" mode)" != repair ] \
     && [ -z "$(git -C "$(driver_state_get "$t" worktree)" log --oneline -1 "origin/$INTEGRATION_BRANCH..HEAD" 2>/dev/null)" ]; then
    local src=0; _driver_plan_split "$t" "$ans" "$tmax" || src=$?
    case "$src" in
      0) return "$DRIVER_E_NOOP" ;;
      2) ;;
      *) driver_state_set "$t" park_cause pm; return "$DRIVER_E_REFUSED" ;;
    esac
  fi

  # THE BINDING PICTURE IS READ ON THIS MACHINE, or the run goes back on the queue.
  # A designRef that is a path where the picture was drawn finds nothing on any other
  # machine; the ticket's "Picture for any machine" comment carries the file, which is
  # fetched, checked against its sha256 and committed into the tree. None reachable is
  # nobody's question: requeued with the reason, never parked, never asked.
  local dref dwt dout drc=0 derr route rwhy
  dref=$(jq -r '.designRef // ""' "$ans")
  # AN EXISTING SCREEN BINDS NO PICTURE (tier.sh, the screen route): CI diffs it against
  # its last approved shots, so a picture the plan names is not fetched, not waited for
  # and not compared. A screen:new or screen:redesign ticket keeps all of it.
  IFS=$'\t' read -r route rwhy <<<"$(driver_screen_route "$t")"
  if [ "$route" = baseline ] && { [ -n "$(printf '%s' "$dref" | tr -d '[:space:]')" ] || [ "$(jq -r '.designSource // ""' "$ans")" = approved-picture ]; }; then
    driver_say "   plan: $rwhy — the picture it names (${dref:-none}) does not bind it. Label it screen:redesign to hold the build to a picture."
    jq '.designRef = "" | (if .designSource == "approved-picture" then .designSource = "ticket-body" else . end)' "$ans" > "$ans.tmp" && mv "$ans.tmp" "$ans"
    dref=""
  fi
  dwt=$(driver_state_get "$t" worktree)
  if [ -n "$(printf '%s' "$dref" | tr -d '[:space:]')" ] && [ -n "$dwt" ] && [ -d "$dwt" ]; then
    derr="$(driver_state_dir "$t")/steps/picture-fetch.err"
    dout=$(bash "$KIT_ROOT/scripts/picture-fetch.sh" "$t" "$dref" "$dwt" 2>"$derr") || drc=$?
    if [ "$drc" -ne 0 ]; then
      driver_say "⏳ plan: the approved picture could not be read on this machine — $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //'). Back on the queue until it is published, not parked."
      driver_state_set "$t" park_note "the approved picture is not readable on this machine: $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //')"
      return "$DRIVER_E_REQUEUE"
    fi
    if [ "$dout" != "$dref" ]; then
      if ! { git -C "$dwt" add -- "$dout" && git -C "$dwt" commit -q --no-verify -m "chore(design): the approved picture for #$t, from its published copy" -- "$dout"; } >/dev/null 2>&1; then
        driver_say "✋ plan: the approved picture was fetched to $dout and could not be committed."
        driver_state_set "$t" park_note "the approved picture was fetched to $dout in $dwt and could not be committed"
        return "$DRIVER_E_REFUSED"
      fi
      driver_say "   plan: $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //'), committed"
      jq --arg r "$dout" '.designRef = $r' "$ans" > "$ans.tmp" && mv "$ans.tmp" "$ans"
    fi
  fi

  # Where the design goes. On the ticket, not into the repo: the comment outlives
  # the worktree and is what the next reader — or the next agent — opens.
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(
    printf '**Plan** (driver step 2 of 7)\n\n```json\n%s\n```\n' "$(cat "$ans")"
  )" >/dev/null 2>&1 || true

  # The ticket stood in for brainstorming — an unattended agent never calls it,
  # because it waits on a person. Say which, rather than leaving it to be guessed.
  # THE PLAN SAYS WHICH. `designSource` is a required property of the contract with
  # three values, and writing a constant here threw away the only one of the three
  # the driver cannot work out for itself — a bug ticket whose plan followed a
  # reproduction is `debugged`, and /finish cross-checks that against the spec gate.
  driver_state_set "$t" design_source "$(jq -r '.designSource // "ticket-body"' "$ans")"
  # AND WHAT IT POINTS AT. `approved-picture` is the value this project's process
  # turns on — a design a person approved before the build — and the compare step
  # holds the renders against exactly this reference. The contract requires the two
  # together, so reading one without the other is how they come apart.
  driver_state_set "$t" design_ref "$(jq -r '.designRef // ""' "$ans")"
  # The screen states the change shows in, for the renderer to capture exactly.
  driver_state_set "$t" screen_states "$(jq -c '.screenStates // []' "$ans")"
  driver_state_set "$t" screen_change "$(jq -r '.screenChange // ""' "$ans")"
  # REPO SETTINGS ARE THE PM'S, AFTER THE MERGE. A build changed the live develop
  # ruleset from inside a step (2026-10-20); the step's gh now refuses that, and a
  # plan that needs one hands it on here instead of leaving a build to try.
  local pm
  pm=$(jq -r '(.pmAfterMerge // [])[] | "- " + .' "$ans" 2>/dev/null)
  driver_state_set "$t" pm_after_merge "$pm"
  if [ -n "$pm" ]; then
    swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(
      printf '**PM step after merge** — repository settings this ticket needs. A build never changes them; the PM makes these once the pull request has merged.

%s
' "$pm"
    )" >/dev/null 2>&1 || true
    driver_say "   plan: $(printf '%s
' "$pm" | grep -c .) repo-settings change(s) handed to the PM for after the merge"
  fi
  driver_say "   plan: $(jq -r '[.tasks[]?] | length' "$ans") task(s), $(jq -r '[.tasks[]?.files[]?] | length' "$ans") file(s), $ntests test(s); posted on #$t"
  return "$DRIVER_OK"
}
