#!/usr/bin/env bash
# feature-list.sh — the feature list a plan writes, the way Anthropic's long-running
# harness keeps one: every item a behaviour a person sees or does, written `F<n>`, with
# the test steps that prove it, all starting as failing. Only `passes` ever changes.
# Editing or removing an item's steps is refused, because an item whose test can be
# rewritten can always be made to pass.
#
#   . driver/feature-list.sh
#   feature_list_problems <plan.json> [built.json]  what is wrong with how the plan builds its list; exit 1
#                                            when any. With built.json (feature_list_built), an item already
#                                            built needs no task, and each refusal names the file and the remedy
#   feature_list_built <plan.json> <tree> <brief|""> <shipped-ref|""> <record-dir>…
#                                            for each item no task writes the test of: is that test already built?
#                                            {"<test>": {state: passes|missing|fails|unproved, why}}
#   feature_list_kept <plan.json> <built.json>  the items kept as already built, `F<n><tab><test>` a line
#   feature_list_uncovered <plan.json> <body> each ticket item (ticket-parts.sh) no list item covers and
#                                            `outside` does not name by id (a `note` entry names none), and each
#                                            id covered that the ticket lacks
#   feature_list_of <plan.json> <ticket>     the list, every item failing, no part filed yet
#   feature_list_guard <old.json> <new.json> exit 0 when only passes changed (or a part was named once); 3 with why
#   feature_list_store <ticket> <list.json>  keep it in the ticket's driver state; 3 when it edits the one kept
#                                            once an item passes or a part is filed (before that it replaces it,
#                                            the old one kept as features.prev.json)
#   feature_list_set_pass <list.json> <Fn> [false]  the list with that item passing (or not)
#   feature_list_comment <list.json>         the comment that carries it on the ticket
#   feature_list_from_comments < comments    every list in a ticket's comments ([{body}]), oldest first, one a line
#
# The steps run as fast component or logic tests in the project's required test run
# (owner, 2026-10-31): a browser check is refused as a test step.
[ -z "${_DRIVER_FEATURE_LIST:-}" ] || return 0
_DRIVER_FEATURE_LIST=1
declare -F driver_state_dir >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || return 1

FEATURE_LIST_MARK='<!-- harness:feature-list -->'
FEATURE_LIST_BROWSER_RE='(^|/)(e2e|playwright|cypress)(/|$)|\.e2e\.|\.(cy|pw)\.[jt]sx?$'

# AN ITEM ALREADY BUILT NEEDS NO TASK. A fix round's plan has tasks only for the red checks
# handed to it, and every item of its list was built by the run that shipped the pull request.
# No test is run to tell: a whole suite an item would cost more than the plan. An item's test is
#   missing   not at the tree's head and not on the trunk;
#   fails     there, and named in the brief handed to this run (its red checks and findings);
#   passes    there, not named, and on record as proved: a kept list item that passes or a proved
#             task's test in one of the record dirs, or (a fix of an open pull request) a file at
#             the head that pull request shipped, which a build ships only once its list passes;
#   unproved  there, with no record.
feature_list_built() { # <plan.json> <tree> <brief-file|""> <shipped-ref|""> <record-dir>…
  local plan="$1" wt="$2" brief="${3:-}" shipped="${4:-}" trunk="" r d m proved test state why
  shift 4 2>/dev/null || shift $#
  for r in "origin/${INTEGRATION_BRANCH:-}" "${INTEGRATION_BRANCH:-}"; do
    [ "${r%/}" = "$r" ] && [ -n "$r" ] && git -C "$wt" rev-parse --verify -q "$r^{commit}" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  [ -z "$shipped" ] || git -C "$wt" rev-parse --verify -q "$shipped^{commit}" >/dev/null 2>&1 || shipped=""
  proved=$(for d in "$@"; do
      [ -n "$d" ] && [ -d "$d" ] || continue
      [ ! -s "$d/features.json" ] || jq -r '.items[]? | select(.passes == true) | .test' "$d/features.json" 2>/dev/null
      for m in "$d"/steps/build-task-*.proved; do
        [ ! -s "$m" ] || jq -r '.answer.testFirst.test.file // .answer.testOnly.test.file // empty' "$m" 2>/dev/null
      done
    done | sed 's|^\./||' | sort -u)
  jq -r '(.tasks // []) as $t | (.features // [])[] | . as $i
      | select([$t[] | select(.item == $i.id) | .tests[]?.file] | any(. == $i.test) | not) | .test' "$plan" 2>/dev/null \
    | sort -u | while IFS= read -r test; do
      [ -n "$test" ] || continue
      r="${test#./}"
      if ! git -C "$wt" cat-file -e "HEAD:$r" 2>/dev/null && { [ -z "$trunk" ] || ! git -C "$wt" cat-file -e "$trunk:$r" 2>/dev/null; }; then
        state=missing; why="which is not on the branch${trunk:+ or on ${trunk#origin/}}"
      elif [ -n "$brief" ] && [ -s "$brief" ] && grep -qF -- "$r" "$brief"; then
        state=fails; why="which is on the branch and named in the red checks and findings handed to this run"
      elif printf '%s\n' "$proved" | grep -qxF -- "$r"; then
        state=passes; why="it is on the branch and its steps passed on an earlier pass"
      elif [ -n "$shipped" ] && git -C "$wt" cat-file -e "$shipped:$r" 2>/dev/null; then
        state=passes; why="it is at the head the open pull request shipped, and no red check handed to this run names it"
      else
        state=unproved; why="which is on the branch with no record of its steps passing"
      fi
      jq -nc --arg k "$test" --arg s "$state" --arg w "$why" '{key: $k, value: {state: $s, why: $w}}'
    done | jq -s 'from_entries'
}

feature_list_kept() { # <plan.json> <built.json>
  jq -r --slurpfile b "$2" '(.tasks // []) as $t | (.features // [])[] | . as $i
    | select([$t[] | select(.item == $i.id) | .tests[]?.file] | any(. == $i.test) | not)
    | select(($b[0][$i.test].state // "") == "passes") | "\(.id)\t\(.test)"' "$1" 2>/dev/null
}

feature_list_problems() { # <plan.json> [built.json]
  local out built='{}' known=false
  if [ -n "${2:-}" ] && [ -s "$2" ] && jq -e 'type == "object"' "$2" >/dev/null 2>&1; then built=$(cat "$2"); known=true; fi
  out=$(jq -r --arg br "$FEATURE_LIST_BROWSER_RE" --argjson built "$built" --argjson known "$known" '
    (.features // []) as $f | (.tasks // []) as $t | ([$f[].id]) as $ids
    | ([$t[] | select(.item == "foundation")] | length) as $nf
    | if ($f | length) == 0 then empty else
      (if $ids != [range($f | length) | "F\(. + 1)"] then
         "the ids run F1, F2, … in order, one per behaviour; this list has \($ids | join(", "))" else empty end),
      ($t | to_entries[] | (.key + 1) as $k | .value
        | if (.item // "") == "" then "task \($k) (\(.title)) names no item: say which behaviour it delivers (F<n>), or foundation, or cleanup"
          elif (.item | startswith("F")) and (.item as $it | $ids | any(. == $it) | not) then "task \($k) (\(.title)) names \(.item), which the list does not have"
          else empty end),
      ($f[] | . as $i | [$t[] | select(.item == $i.id)] as $mine
        | ($built[$i.test] // null) as $b
        | if ([$mine[].tests[]?.file] | any(. == $i.test)) then empty
          elif $known and $b != null then
            (if $b.state == "passes" then empty
             else "\($i.id) runs its steps in \($i.test), \($b.why), and no task of \($i.id) writes it: add a task with item \($i.id) whose tests name \($i.test)" end)
          elif ($mine | length) == 0 then "\($i.id) has no task: each item is built by its own tasks"
          else "\($i.id) runs its steps in \($i.test), and no task of \($i.id) writes it" end),
      ($f[] | select(.test | test($br)) | "\(.id) runs its steps in \(.test), a browser check: the steps run as fast component or logic tests in the required test run"),
      (if $nf > 0 and (.foundation == null) then "the plan has foundation tasks and no `foundation`: a shared foundation goes first only with its reason (expand-contract, refactor or hidden-backend); otherwise fold it into the item that uses it" else empty end),
      (if $nf == 0 and (.foundation != null) then "it names a `foundation` and no task builds it (no task has item foundation)" else empty end),
      ($f[] | select(.needsFoundation == true and $nf == 0) | "\(.id) needs a foundation and the plan has none"),
      (if (.foundation.reason // "") == "expand-contract" and ([$t[] | select(.item == "cleanup")] | length) == 0
           then "an expand-contract foundation has no clean-up: the contract step (the old path removed) is a task with item cleanup" else empty end),
      (if (.units // []) != [] then "it has units and a feature list: a mechanical change fans out with no feature list" else empty end)
      end' "$1" 2>/dev/null) || { printf 'the plan could not be read as JSON\n'; return 1; }
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"; return 1
}

# A list mapped against the ticket it builds: every numbered change item and acceptance item
# is some item's, or named outside it with why.
feature_list_uncovered() { # <plan.json> <body-file>
  local items out
  [ "$(jq '(.features // []) | length' "$1" 2>/dev/null)" -gt 0 ] 2>/dev/null || return 0
  declare -F ticket_parts_items >/dev/null 2>&1 || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ticket-parts.sh" || return 0
  items=$(ticket_parts_items "$2" | jq -Rn '[inputs | split("\t") | {id: .[0], text: (.[1] // "")}]')
  out=$(jq -r --argjson items "$items" '
    ([(.features // [])[] | (.covers // [])[]] + [(.outside // [])[] | .item // empty]) as $named
    | ($items | map(.id)) as $ids
    | ($items[] | select(.id as $i | $named | index($i) | not)
        | "\(.id) (“\(.text[0:140])”) is in no item'"'"'s covers and not in outside: say which behaviour delivers it, or put it in outside with why"),
      ([(.features // [])[] | . as $f | (.covers // [])[] | select(. as $c | $ids | index($c) | not) | "\($f.id) covers \(.), which the ticket does not have (its items: \(if $ids == [] then "none" else $ids | join(", ") end))"] | unique[])' "$1" 2>/dev/null) || return 0
  [ -z "$out" ] && return 0
  printf '%s\n' "$out"; return 1
}

feature_list_of() { # <plan.json> <ticket>
  jq --arg t "$2" '{ticket: ($t | tonumber? // $t),
      items: [(.features // [])[] | {id, behaviour, steps, test, needsFoundation: (.needsFoundation // false), covers: (.covers // []), passes: false, part: null}],
      outside: (.outside // []),
      foundation: (if .foundation then (.foundation + {part: null}) else null end),
      cleanup: (if ([(.tasks // [])[] | select(.item == "cleanup")] | length) > 0 then {part: null} else null end)}' "$1"
}

# What may never change: each item's id, behaviour, steps, test and whether it waits on
# the foundation. A part number may be named once, never moved.
feature_list_guard() { # <old.json> <new.json>
  local why
  why=$(jq -rn --slurpfile o "$1" --slurpfile n "$2" '
    def fixed: {id, behaviour, steps, test, needsFoundation: (.needsFoundation // false)};
    ($o[0].items // []) as $a | ($n[0].items // []) as $b
    | ($a[] | . as $x | ([$b[] | select(.id == $x.id)] | first) as $y
       | if $y == null then "\($x.id) was removed: an item, once listed, stays until it passes"
         elif ($x | has("covers")) and ($x.covers != $y.covers) then "\($x.id) was edited: the ticket items it covers are fixed once listed"
         elif ($x | fixed) != ($y | fixed) then "\($x.id) was edited: its behaviour, steps and test are fixed once listed; only passes may change"
         elif ($x.part != null) and ($y.part != $x.part) then "\($x.id) moved from part #\($x.part) to \($y.part // "none")"
         else empty end),
      ($b[] | . as $y | select(([$a[] | select(.id == $y.id)] | length) == 0) | "\($y.id) was added after the list was written: a new behaviour is a new ticket")
  ' 2>/dev/null) || { printf 'the feature list could not be read as JSON\n'; return 3; }
  [ -z "$why" ] && return 0
  printf '%s\n' "$why"; return 3
}

feature_list_store() { # <ticket> <list.json>
  local f why; f="$(driver_state_dir "$1")/features.json"
  mkdir -p "$(dirname "$f")"
  if [ -s "$f" ]; then
    # Nothing passed and no part filed: a fresh plan replaces it; an unreadable list stays guarded.
    if [ "$(jq '[.. | objects | select(has("passes") or has("part")) | (.passes == true) or (.part != null)] | any' "$f" 2>/dev/null)" = false ]; then
      cp "$f" "$(dirname "$f")/features.prev.json"
    else
      why=$(feature_list_guard "$f" "$2") || { printf '%s\n' "$why"; return 3; }
    fi
  fi
  jq . "$2" > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
}

feature_list_set_pass() { # <list.json> <Fn> [true|false]
  local v="${3:-true}"
  jq -e --arg id "$2" '[.items[] | select(.id == $id)] | length == 1' "$1" >/dev/null 2>&1 \
    || { printf 'feature list: no item %s\n' "$2" >&2; return 1; }
  jq --arg id "$2" --argjson v "$v" '.items |= map(if .id == $id then .passes = $v else . end)' "$1"
}

feature_list_comment() { # <list.json>
  jq -r --arg m "$FEATURE_LIST_MARK" '
    ([.items[].part, .cleanup.part?] | map(select(. != null)) | length > 0) as $parts
    | "**Feature list** — " + (if $parts then "one behaviour a part" else "one behaviour an item, built here as one change" end) + ", each passing only when its test steps pass. Only `passes` changes; an item'"'"'s steps are never edited or removed. " + (if $parts then "The feature is done when every item passes and its clean-up part has merged." else "The feature is done when every item passes and this change has merged." end) + "\n\n"
    + ([.items[] | "- " + (if .passes then "✅" else "⬜" end) + " **" + .id + "** " + .behaviour
        + (if .part then " — #\(.part)" else "" end) + (if .passes then " (passes)" else " (failing)" end)] | join("\n"))
    + (if ((.outside // []) | length) > 0 then "\n\nLeft out, with why:\n" + ([.outside[] | "- " + (.item // .note // "?") + ": " + (.why // "")] | join("\n")) else "" end)
    + "\n\n```json\n" + (. | tojson) + "\n```\n" + $m' "$1"
}

feature_list_from_comments() { # stdin: [{body}] — each list, oldest first
  jq -c --arg m "$FEATURE_LIST_MARK" '
    .[]? | (.body // "") | select(contains($m))
    | (capture("```json\\n(?<j>[^\\n]+)\\n```") | .j | fromjson?) // empty'
}
