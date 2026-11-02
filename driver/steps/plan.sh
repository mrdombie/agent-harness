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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/feature-list.sh" || exit 1

# SPLIT BY BEHAVIOUR, NEVER BY COUNT (owner, 2026-11-02, after Anthropic's long-running
# harness). It was ">3 tasks or >20 files, then chain": ~15 of 25 sampled parts were a layer
# or a chore, 86 parts sat waiting on a predecessor, and a feature took a median 14.6 h from
# first part filed to last merged. Now a plan writes a feature list, one behaviour a person
# sees or does per item, each with its test steps, all failing. Two or more items: one part
# per item, built side by side. A shared foundation goes first only with its reason, and only
# the items that need it wait for it; a clean-up part goes last. A mechanical change fans out
# like Claude Code's /batch: 5-30 independent units, no list.

# _driver_plan_carried <ticket> <meta> — what a part carries from the parent, by link, never by
# copy. An approved picture lives in the parent's own comment; a part that re-posted it would
# be an agent approving its own picture. So the part names it, and picture-fetch.sh follows
# "split from #<parent>" to that comment. The parent's PM and owner answers ride quoted.
_driver_plan_carried() {
  jq -r '
    def link: (.url // "") | if . == "" then "" else " (" + . + ")" end;
    [(.comments // [])[] | select((.body // "") | startswith("**Picture for any machine**"))] as $pics
    | [(.comments // [])[] | select((.body // "") | test("^\\*\\*(The owner answered|PM answer|The PM answered)"; "i"))] as $ans
    | (if ($pics | length) > 0 then
         "\n**Approved picture — the parent'"'"'s, by link:** the approval is #'"$1"''"'"'s comment" + ($pics | last | link)
         + ((($pics | last | .body) | capture("picture-approve: sha256=(?<s>[0-9a-f]{64}) file=(?<f>[^ ]+)")?) // {} | if .s then ", `" + .f + "`, sha256 `" + .s[0:12] + "…`" else "" end)
         + ". This part is bound by it; the picture step reads it there.\n"
       else "" end)
    + (if ($ans | length) > 0 then
         "\n**Answers already given on #'"$1"'** (quoted, not asked again):\n"
         + ($ans | map("> " + ((.body // "") | split("\n") | join("\n> ")) + "\n> — " + (.url // "")) | join("\n\n")) + "\n"
       else "" end)' <<<"$2" 2>/dev/null
}

# _driver_plan_files_tests <tasks JSON array> — the "**Files:** … **Tests:** …" lines of a part.
_driver_plan_files_tests() {
  jq -r '"**Files:** " + ([.[].files[]? | (.path // .) | tostring] | unique | join(", ") | if . == "" then "(none named)" else . end)
    + "\n\n**Tests:** " + ([.[].tests[]? | (.file // .name // .behaviour // .) | tostring] | unique | join("; ") | if . == "" then "(none named)" else . end)' <<<"$1"
}

# _driver_plan_file_part <title> <body> <status> <inherit> — files one part; prints its number.
_driver_plan_file_part() {
  local args url c l
  args=(issue create --repo "$REPO_SLUG" --title "$1" --body "$2" --label "$3")
  while IFS= read -r l; do [ -n "$l" ] && args+=(--label "$l"); done <<<"$4"
  url=$(swarm_gh "${args[@]}" 2>/dev/null) || return 1
  c=${url##*/}; case "$c" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$c"
}

# _driver_plan_close_split <ticket> <kids> <comment> <why> — the parent is told, closed as split
# (so nothing claims it again), and the waits naming it are re-pointed at its parts.
_driver_plan_close_split() {
  local t="$1" kids="$2"
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$3" >/dev/null 2>&1 || true
  swarm_gh issue close "$t" --repo "$REPO_SLUG" --reason "not planned" >/dev/null 2>&1 || true
  # shellcheck disable=SC2086  # the part numbers, split on purpose
  bash "${DRIVER_REPOINT:-$KIT_ROOT/scripts/unblock-waiting.sh}" --repoint "$t" ${kids//#/} >/dev/null 2>&1 \
    || driver_say "   plan: the waits naming #$t were not re-pointed at its parts; the unblocker still reads them through the split"
  driver_state_set "$t" noop_note "was split into $kids before it built: $4"
}

# _driver_plan_split_features <ticket> <plan.json> — one part per feature list item, built side
# by side; the foundation first when the plan names one, the clean-up last. The list, its parts
# named, is kept in the driver state and posted on the parent. 0 filed · 1 a filing failed.
_driver_plan_split_features() {
  local t="$1" ans="$2" meta title inherit carried n nf ni nc k=0 found="" kids="" items="" c body st wait
  local list i id beh test reason why tasks steps
  meta=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title,labels,comments 2>/dev/null) || return 1
  title=$(jq -r '.title // ""' <<<"$meta")
  inherit=$(jq -r '[.labels[]?.name | select(test("^P[0-9]$|^(area|screen|project|repo|effort):"))] | .[]' <<<"$meta")
  carried=$(_driver_plan_carried "$t" "$meta")
  nf=$(jq '[.tasks[]? | select(.item == "foundation")] | length | if . > 0 then 1 else 0 end' "$ans")
  ni=$(jq '.features | length' "$ans")
  nc=$(jq '[.tasks[]? | select(.item == "cleanup")] | length | if . > 0 then 1 else 0 end' "$ans")
  n=$((nf + ni + nc))
  list="$(driver_state_dir "$t")/features.json"
  reason=$(jq -r '.foundation.reason // ""' "$ans"); why=$(jq -r '.foundation.why // ""' "$ans")
  if [ "$nf" = 1 ]; then
    k=1; tasks=$(jq -c '[.tasks[] | select(.item == "foundation")]' "$ans")
    body=$(printf 'Part %s of %s, split from #%s before it was built: the shared foundation its behaviours build on. It goes first only because it names its reason, **%s**: %s. It changes nothing a person sees. One change, merged on its own.
%s
**This part:** foundation — %s

%s

Refs #%s' "$k" "$n" "$t" "$reason" "$why" "$carried" "$(jq -r '[.[].title] | join("; ")' <<<"$tasks")" "$(_driver_plan_files_tests "$tasks")" "$t")
    c=$(_driver_plan_file_part "$title — part $k of $n: foundation ($reason): $(jq -r '.[0].title' <<<"$tasks" | cut -c1-60)" "$body" "$LBL_READY" "$inherit") \
      || { driver_state_set "$t" park_note "split needed: filing the foundation part failed"; return 1; }
    found="$c"; kids="#$c"
  fi
  i=0
  while [ "$i" -lt "$ni" ]; do
    k=$((k+1))
    id=$(jq -r --argjson i "$i" '.features[$i].id' "$ans"); beh=$(jq -r --argjson i "$i" '.features[$i].behaviour' "$ans")
    test=$(jq -r --argjson i "$i" '.features[$i].test' "$ans")
    steps=$(jq -r --argjson i "$i" '.features[$i].steps | to_entries | map("\(.key + 1). \(.value)") | join("\n")' "$ans")
    tasks=$(jq -c --arg id "$id" '[.tasks[] | select(.item == $id)]' "$ans")
    st="$LBL_READY"; wait=""
    if [ -n "$found" ] && [ "$(jq -r --argjson i "$i" '.features[$i].needsFoundation // false' "$ans")" = true ]; then
      st="${LBL_GATED:-$LBL_READY}"
      wait=$(printf '\nBlocked until #%s merges: this behaviour builds on the foundation (%s), and the unblocker (scripts/unblock-waiting.sh) sets it ready when that has merged.' "$found" "$reason")
    fi
    body=$(printf 'Part %s of %s, split from #%s before it was built: one behaviour of the feature list of #%s. One change, merged on its own, built side by side with the other parts.
%s
**This part:** %s: %s

**Test steps** — they run in `%s`, a fast component or logic test in the required test run, and %s passes only when they do. They are fixed: never edit or remove them.
%s

%s

Refs #%s
<!-- harness:feature-item parent=%s id=%s test=%s -->%s' "$k" "$n" "$t" "$t" "$carried" "$id" "$beh" "$test" "$id" "$steps" "$(_driver_plan_files_tests "$tasks")" "$t" "$t" "$id" "$test" "$wait")
    c=$(_driver_plan_file_part "$title — part $k of $n: $id $(printf '%s' "$beh" | cut -c1-70)" "$body" "$st" "$inherit") \
      || { driver_state_set "$t" park_note "split needed: filing part $k of $n ($id) failed after ${kids:-none} were filed"; return 1; }
    kids="${kids:+$kids }#$c"; items="${items:+$items, }#$c"
    jq --arg id "$id" --argjson p "$c" '.items |= map(if .id == $id then .part = $p else . end)' "$list" > "$list.tmp" && mv "$list.tmp" "$list"
    i=$((i+1))
  done
  if [ "$nc" = 1 ]; then
    k=$((k+1)); tasks=$(jq -c '[.tasks[] | select(.item == "cleanup")]' "$ans")
    body=$(printf 'Part %s of %s, split from #%s before it was built: the clean-up (the switch removed, the old path deleted, the contract step). The feature of #%s is done only when every item of its list passes and this has merged. One change, merged on its own.
%s
**This part:** clean-up — %s

%s

Refs #%s
Blocked until %s merge: the clean-up goes last, once every behaviour has landed; the unblocker (scripts/unblock-waiting.sh) sets it ready then.' "$k" "$n" "$t" "$t" "$carried" "$(jq -r '[.[].title] | join("; ")' <<<"$tasks")" "$(_driver_plan_files_tests "$tasks")" "$t" "$items")
    c=$(_driver_plan_file_part "$title — part $k of $n: clean-up: $(jq -r '.[0].title' <<<"$tasks" | cut -c1-60)" "$body" "${LBL_GATED:-$LBL_READY}" "$inherit") \
      || { driver_state_set "$t" park_note "split needed: filing the clean-up part failed after $kids were filed"; return 1; }
    kids="$kids #$c"
    jq --argjson p "$c" '.cleanup.part = $p' "$list" > "$list.tmp" && mv "$list.tmp" "$list"
  fi
  [ -z "$found" ] || { jq --argjson p "$found" '.foundation.part = $p' "$list" > "$list.tmp" && mv "$list.tmp" "$list"; }
  swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(feature_list_comment "$list")" >/dev/null 2>&1 || true
  _driver_plan_close_split "$t" "$kids" "**Split by behaviour** into $kids — one part per item of its feature list, built side by side$([ -z "$found" ] || printf '; the foundation #%s goes first (%s), and only the items that build on it wait for it' "$found" "$reason")$([ "$nc" = 0 ] || printf '; the clean-up %s goes last' "${kids##* }"). Nothing was built here. Closed as split; the feature is done when every item passes and its clean-up part $([ "$nc" = 0 ] && printf '(none: nothing to remove)' || printf '%s' "${kids##* }") has merged (scripts/feature-close.sh marks it so)." \
    "its feature list has $ni behaviours, one part each"
  driver_say "✂ plan: $ni behaviours — split by behaviour into $n parts ($kids), side by side; the parent closed as split"
}

# _driver_plan_fan_out <ticket> <plan.json> — a mechanical change, one part per unit, every one
# ready at once (Claude Code's /batch): the units are independent, so none waits on another.
_driver_plan_fan_out() {
  local t="$1" ans="$2" meta title inherit carried n i unit body c kids="" recipe
  meta=$(driver_gh_read swarm_gh issue view "$t" --repo "$REPO_SLUG" --json title,labels,comments 2>/dev/null) || return 1
  title=$(jq -r '.title // ""' <<<"$meta")
  inherit=$(jq -r '[.labels[]?.name | select(test("^P[0-9]$|^(area|screen|project|repo|effort):"))] | .[]' <<<"$meta")
  carried=$(_driver_plan_carried "$t" "$meta")
  recipe=$(jq -r '[.tasks[]? | .title + (if (.tests // []) != [] then " (proved by " + ([.tests[].behaviour] | join("; ")) + ")" else "" end)] | join("; ")' "$ans")
  n=$(jq '.units | length' "$ans"); i=0
  while [ "$i" -lt "$n" ]; do
    unit=$(jq -c --argjson i "$i" '[.units[$i]]' "$ans")
    body=$(printf 'Part %s of %s, split from #%s before it was built: one unit of a mechanical change, fanned out like Claude Code'"'"'s /batch. Independent of the other units: they are built at once, one change each, with no feature list.
%s
**The change, which every unit follows:** %s

**This unit:** %s

%s

Refs #%s' "$((i+1))" "$n" "$t" "$carried" "$recipe" "$(jq -r '.[0].title' <<<"$unit")" "$(_driver_plan_files_tests "$unit")" "$t")
    c=$(_driver_plan_file_part "$title — part $((i+1)) of $n: $(jq -r '.[0].title' <<<"$unit" | cut -c1-80)" "$body" "$LBL_READY" "$inherit") \
      || { driver_state_set "$t" park_note "split needed: filing unit $((i+1)) of $n failed after ${kids:-none} were filed"; return 1; }
    kids="${kids:+$kids }#$c"; i=$((i+1))
  done
  _driver_plan_close_split "$t" "$kids" "**Split, fanned out like /batch,** into $kids — a mechanical change of $n independent units, one change each, all ready at once, with no feature list. Nothing was built here. Closed as split." \
    "a mechanical change of $n independent units"
  driver_say "✂ plan: a mechanical change — fanned out into $n units ($kids), all ready at once; the parent closed as split"
}

# _driver_plan_resend <ticket> <why> <problems> — the plan answered once more with what is wrong.
_driver_plan_resend() {
  local note; note="$(driver_state_dir "$1")/steps/plan.split-note.md"
  printf 'SENT BACK ONCE: %s\n\n%s\n\nGive the same answer again with these fixed. A feature list item is one behaviour a person sees or does, `F<n>`, with test steps run as a fast component or logic test in the required test run, and every task names the item it builds (`item`): F<n>, foundation or cleanup. Never split by layer.\n' \
    "$2" "$(printf '%s\n' "$3" | sed 's/^/- /')" > "$note"
  driver_say "↩ plan: $2 — asked once more"
  driver_ai_step "$1" plan "$note"
}

# _driver_plan_list_problems <ticket> <plan.json> <labels-csv> <title> <body> — what is wrong
# with how the plan splits, one a line. A part of a split checks only that its plan runs its
# item's steps; any other plan checks its list, and a feature ticket must have one.
_driver_plan_list_problems() {
  local t="$1" ans="$2" labels="$3" title="$4" body="$5" item id test l
  if printf '%s' "$title" | grep -qE ' — part [0-9]+ of [0-9]+: '; then
    item=$(printf '%s' "$body" | sed -nE 's/.*<!-- harness:feature-item parent=[0-9]+ id=(F[0-9]+) test=([^ ]+) -->.*/\1 \2/p' | tail -1)
    [ -n "$item" ] || return 0
    id=${item%% *}; test=${item#* }
    jq -e --arg f "$test" '[.tasks[]?.tests[]?.file] | any(. == $f)' "$ans" >/dev/null 2>&1 \
      || printf '%s\n' "this part builds $id of its parent's feature list, whose steps run in $test, and no task of this plan runs it: $id passes only when those steps pass"
    return 0
  fi
  feature_list_problems "$ans"
  [ "$(jq '((.features // []) | length) + ((.units // []) | length)' "$ans")" = 0 ] || return 0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case ",$labels," in *",$l,"*)
      printf '%s\n' "#$t is a feature ticket ($l) and the plan has no feature list: write \`features\`, one behaviour a person sees or does per item, each with its test steps"; return 0 ;;
    esac
  done <<<"$(driver_split_feature_labels)"
}

# _driver_plan_shape <ticket> <plan.json> — the list is checked (sent back once, then refused)
# and kept in the driver state, where a later plan may not edit or remove an item's steps.
_driver_plan_shape() {
  local t="$1" ans="$2" meta title labels body probs rc tmp why
  meta=$(driver_gh_read driver_ticket_view "$t" title,labels,body 2>/dev/null) || {
    driver_say "⏳ plan: #$t could not be read to tell a feature, a part of one or a mechanical change apart — back on the queue"
    return "$DRIVER_E_UNREAD"; }
  title=$(jq -r '.title // ""' <<<"$meta"); body=$(jq -r '.body // ""' <<<"$meta")
  labels=$(jq -r '[.labels[]?.name] | join(",")' <<<"$meta")
  probs=$(_driver_plan_list_problems "$t" "$ans" "$labels" "$title" "$body")
  if [ -n "$probs" ]; then
    rc=0; _driver_plan_resend "$t" "the plan does not split by behaviour" "$probs" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    probs=$(_driver_plan_list_problems "$t" "$ans" "$labels" "$title" "$body")
    if [ -n "$probs" ]; then
      driver_say "✋ plan: asked once and it still does not split by behaviour — $(printf '%s' "$probs" | paste -sd';' - | sed 's/;/; /g')"
      driver_state_set "$t" park_note "the plan does not split by behaviour: $(printf '%s' "$probs" | paste -sd';' -)"
      return "$DRIVER_E_REFUSED"
    fi
  fi
  [ "$(jq '(.features // []) | length' "$ans")" -gt 0 ] || return 0
  printf '%s' "$title" | grep -qE ' — part [0-9]+ of [0-9]+: ' && return 0
  tmp="$(driver_state_dir "$t")/steps/features.new.json"
  feature_list_of "$ans" "$t" > "$tmp" || return "$DRIVER_E_REFUSED"
  if ! why=$(feature_list_store "$t" "$tmp"); then
    driver_say "✋ plan: the feature list kept for #$t would change — $(printf '%s' "$why" | paste -sd';' -). Editing or removing an item's steps is refused: only passes changes."
    driver_state_set "$t" park_note "the plan edits the feature list kept for #$t: $(printf '%s' "$why" | paste -sd';' -)"
    return "$DRIVER_E_REFUSED"
  fi
  return 0
}

# _driver_plan_split_by_shape <ticket> <plan.json> — 0 builds here; DRIVER_E_NOOP split, nothing
# built; DRIVER_E_REFUSED a filing failed. A repair, a branch that already has commits and a part
# of an earlier split always build here: parts already in flight finish as they are.
_driver_plan_split_by_shape() {
  local t="$1" ans="$2" nf nu src=0 title
  nf=$(jq '(.features // []) | length' "$ans"); nu=$(jq '(.units // []) | length' "$ans")
  title=$(driver_gh_read driver_ticket_view "$t" title '.title' 2>/dev/null) || title=""
  if printf '%s' "$title" | grep -qE ' — part [0-9]+ of [0-9]+: '; then
    [ "$nf" -le 1 ] && [ "$nu" -eq 0 ] || driver_say "   plan: #$t is itself a part of a split — it builds"
    return 0
  fi
  if [ "$nf" -le 1 ] && [ "$nu" -eq 0 ]; then
    [ "$nf" -eq 0 ] || swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$(feature_list_comment "$(driver_state_dir "$t")/features.json")" >/dev/null 2>&1 || true
    return 0
  fi
  if [ "$(driver_state_get "$t" mode)" = repair ] \
     || [ -n "$(git -C "$(driver_state_get "$t" worktree)" log --oneline -1 "origin/$INTEGRATION_BRANCH..HEAD" 2>/dev/null)" ]; then
    driver_say "   plan: already in flight — it builds here as planned, not split"
    return 0
  fi
  if [ "$nu" -gt 0 ]; then _driver_plan_fan_out "$t" "$ans" || src=$?
  else _driver_plan_split_features "$t" "$ans" || src=$?; fi
  [ "$src" -eq 0 ] && return "$DRIVER_E_NOOP"
  driver_state_set "$t" park_cause pm; return "$DRIVER_E_REFUSED"
}

# _driver_plan_picture_miss <ticket> <ref> <why> — the approved picture is not readable here.
# The first miss goes back on the queue; driver.maxPictureMisses (2) in a row parks it for
# the PM, naming the file: 17008 was requeued at the front 43 times in 4 hours, each run
# re-planning, over a picture that existed only on the machine it was drawn on.
_driver_plan_picture_miss() {
  local t="$1" ref="$2" why="$3" n max
  max="${DRIVER_MAX_PICTURE_MISSES:-$(driver_opt driver.maxPictureMisses 2)}"
  case "$max" in ''|*[!0-9]*|0) max=2 ;; esac
  driver_state_bump "$t" picture_miss
  driver_state_set "$t" picture_miss_ref "$ref"
  n=$(driver_state_count "$t" picture_miss)
  if [ "${n:-0}" -ge "$max" ]; then
    driver_say "✋ plan: the approved picture ($ref) was not readable on this machine $n runs in a row — parked for the PM, not requeued again: $why"
    driver_state_set "$t" park_cause pm
    driver_state_set "$t" park_note "The approved picture is not readable on this machine, $n runs in a row: $ref ($why). Post it on this ticket as a \"Picture for any machine\" comment (scripts/picture-approve.sh) or commit it as the surface's mock, then clear \`$DRIVER_PM_LABEL\`."
    return "$DRIVER_E_QUESTION"
  fi
  driver_say "⏳ plan: the approved picture could not be read on this machine — $why. Back on the queue until it is published ($n of $max misses before it parks for the PM)."
  driver_state_set "$t" park_note "the approved picture is not readable on this machine: $why"
  return "$DRIVER_E_REQUEUE"
}
_driver_plan_picture_found() { # <ticket> — the misses were not in a row
  [ -z "$(driver_state_get "$1" picture_miss_ref)" ] && [ "$(driver_state_count "$1" picture_miss)" = 0 ] && return 0
  _driver_state_edit "$1" '.counters.picture_miss = 0 | .picture_miss_ref = ""'
}

driver_step_plan() { # <ticket>
  local t="${1:?driver_step_plan: need a ticket}"
  local rc ans schema spec ntests
  export DRIVER_TICKET="$t"

  # THE PICTURE THE LAST RUN MISSED IS LOOKED FOR BEFORE THE PLAN IS PAID FOR. A run that
  # would plan again only to miss it again costs a plan and a slot each time.
  local pref pwt perr prc=0
  pref=$(driver_state_get "$t" picture_miss_ref); pwt=$(driver_state_get "$t" worktree)
  if [ -n "$pref" ] && [ -n "$pwt" ] && [ -d "$pwt" ]; then
    perr="$(driver_state_dir "$t")/steps/picture-fetch.err"; mkdir -p "$(dirname "$perr")"
    bash "$KIT_ROOT/scripts/picture-fetch.sh" "$t" "$pref" "$pwt" >/dev/null 2>"$perr" || prc=$?
    if [ "$prc" -eq 3 ]; then
      _driver_plan_picture_miss "$t" "$pref" "$(tail -1 "$perr" 2>/dev/null | sed 's/^picture-fetch: //') (checked before planning; nothing spent)"
      return $?
    fi
    [ "$prc" -ne 0 ] || driver_say "   plan: the approved picture the last run missed is readable now — planning"
  fi

  rc=0; driver_ai_step "$t" plan || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  ans="$(driver_state_dir "$t")/steps/plan.json"

  # A SCREEN CHANGE WRITES ITS CHECKLIST UP FRONT: per screen state it touches, how it
  # handles loading, failure, a retry in flight, empty and phone width. Sent back once;
  # the review holds the build to it. ~38 of 64 Majors since 22 Oct were these states.
  rc=0; _driver_screen_checklist_due "$t" plan "$ans" \
    "$(jq -r '[.tasks[]?.files[]?.path] | .[]' "$ans")" "$(jq -r '.screenChange // ""' "$ans")" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # THE FEATURE LIST: checked against how the plan builds it, and kept.
  rc=0; _driver_plan_shape "$t" "$ans" || rc=$?
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

  # SPLIT BY BEHAVIOUR (above): one part per item of the feature list, or a mechanical fan-out.
  rc=0; _driver_plan_split_by_shape "$t" "$ans" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

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
    if [ "$drc" -eq 3 ]; then
      _driver_plan_picture_miss "$t" "$dref" "$(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //')"
      return $?
    elif [ "$drc" -ne 0 ]; then
      driver_say "⏳ plan: the approved picture could not be read on this machine — $(tail -1 "$derr" 2>/dev/null | sed 's/^picture-fetch: //'). Back on the queue, not parked."
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

  _driver_plan_picture_found "$t"

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
