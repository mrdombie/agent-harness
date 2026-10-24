#!/usr/bin/env bash
# standard-answer.sh — MERGE FIRST: a question a standing rule already answers is never
# put to a person (the owner, 23 Oct: "builders take the standard merge-first answer
# instead of asking"). Sourced by ai-step.sh, so build-ticket and every step have it.
#
#   driver_standard_answer <ticket> <step> <text>   0 when a standard answer applies;
#       sets SA_CLASS (a–f), SA_NAME, SA_ANSWER, SA_ACTION (carry|base-wait|parent-wait|dependency-wait),
#       SA_PARENT (b's pull request) and SA_HOW (mechanical|model). 1: it parks as before.
#   driver_standard_answer_note <ticket> <step> <text>   logs "standard answer: <which>"
#       and writes it on the pull request, or the ticket while there is none.
#
# THE CLASSES AND PATTERNS ARE ONE SETTING: release.standardAnswers in harness.json, or
# this kit's driver/standard-answers.json when the key is absent; false turns it off. It
# is read only while release.mergeFirst is on, so it comes off with the switch.
#
# Mechanical first: a park pattern (data model, secrets, a Critical, a product or design
# call) parks with no model call; then the classes in order, first match, over the
# question text and the step's record (a base-red cache for a, the deferred findings'
# grades for c). Only text no pattern decides goes to one short model call, which must
# answer one of a b c d e park; anything else parks. b with no parent PR in the text parks.
_driver_sa_cfg() { # prints the setting as JSON, or nothing when it is off
  local cfg v kit
  kit="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/standard-answers.json"
  cfg=""; command -v _release_cfg >/dev/null 2>&1 && cfg=$(_release_cfg)
  [ -n "$cfg" ] || cfg="${HARNESS_CFG:-}"
  v='null'; [ -n "$cfg" ] && [ -f "$cfg" ] && v=$(jq -c '.release.standardAnswers' "$cfg" 2>/dev/null)
  case "${v:-null}" in
    false) return 0 ;;
    null) jq -c . "$kit" 2>/dev/null ;;
    *) printf '%s' "$v" ;;
  esac
}

# _driver_sa_match <setting> <text> <ctx-json> — the mechanical verdict: a class, park, or nothing.
_driver_sa_match() {
  jq -rn --argjson s "$1" --arg q "$2" --argjson ctx "$3" '
    def m($p): $q | test($p; "i");
    if any(($s.park // [])[]; m(.)) then "park"
    else first(($s.order // ($s.classes | keys))[] as $k | $s.classes[$k] as $c
           | select($c != null)
           | select(
               ((($c.any // []) | length) > 0 and any($c.any[]; m(.)))
               or ((($c.all // []) | length) > 0 and all($c.all[]; m(.)))
               or ($c.context == "baseRed" and $ctx.baseRed and m("\\b(wait|fix)"))
               or ($c.context == "deferredGrades" and $ctx.deferredMinorMajor))
           | $k) // "" end' 2>/dev/null
}

# _driver_sa_model <ticket> <text> <setting> — one short classification call; prints a class or park.
_driver_sa_model() {
  local t="$1" q="$2" s="$3" p out model secs
  [ "$(jq -r '.classifier.enabled // false' <<<"$s")" = true ] || { echo park; return 0; }
  model=$(jq -r '.classifier.model // "opus"' <<<"$s"); secs=$(jq -r '.classifier.timeoutSec // 90' <<<"$s")
  p="$(driver_state_dir "$t")/steps/standard-answer.prompt"; mkdir -p "$(dirname "$p")"
  {
    printf 'A build step stopped to ask a person this. Until the release a standing merge-first rule answers some questions. Reply with ONE token and nothing else: a, b, c, d, e, f or park.\n\n'
    jq -r '.classes | to_entries[] | "\(.key): \(.value.name) — \(.value.answer)"' <<<"$s"
    printf 'park: anything else, or a product, design, data-model, secrets or Critical question, or when unsure.\n\nThe question:\n%s\n' "$q"
  } > "$p"
  out=$(driver_bounded_argv "$secs" "$p" "${DRIVER_SA_CLAUDE:-$DRIVER_CLAUDE}" -p --model "$model" --max-turns 1 \
          --output-format text --name standard-answer 2>/dev/null | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  case "$out" in a|b|c|d|e|f) [ "$(jq -r --arg k "$out" '.classes[$k] // empty | .action' <<<"$s")" != "" ] && echo "$out" || echo park ;; *) echo park ;; esac
}

driver_standard_answer() { # <ticket> <step> <text>
  local t="$1" step="$2" q="$3" s ctx cls how=mechanical d review ans br
  SA_CLASS=""; SA_NAME=""; SA_ANSWER=""; SA_ACTION=""; SA_PARENT=""; SA_HOW=""
  driver_merge_first || return 1
  [ -n "$q" ] || return 1
  s=$(_driver_sa_cfg); [ -n "$s" ] || return 1
  d=$(driver_state_dir "$t"); review="$d/steps/review.json"; ans="$d/steps/$step.json"
  br="false"; [ -n "$(driver_state_get "$t" base_red)$(driver_state_get "$t" base_red_tests)" ] && br="true"
  # c's record: every finding the step deferred is a Minor or a Major in the review.
  ctx=$(jq -cn --argjson br "$br" --slurpfile a <(jq -c . "$ans" 2>/dev/null || echo '{}') \
              --slurpfile r <(jq -c . "$review" 2>/dev/null || echo '{}') '
    ([$a[0].deferred[]?.blockerId]) as $ids
    | ([$r[0].findings[]? | {key: (.id // ""), value: ((.grade // "") | ascii_downcase)}] | from_entries) as $g
    | {baseRed: $br,
       deferredMinorMajor: (($ids | length) > 0 and all($ids[]; ($g[.] // "") | test("^(minor|major)$")))}' 2>/dev/null)
  [ -n "$ctx" ] || ctx='{"baseRed":false,"deferredMinorMajor":false}'
  cls=$(_driver_sa_match "$s" "$q" "$ctx")
  if [ -z "$cls" ]; then
    # One call per question: a resumed step asking the same thing reads the first verdict.
    local key cache="$d/steps/standard-answer.cache"
    key=$(printf '%s' "$q" | cksum | cut -d' ' -f1)
    cls=$(awk -F'\t' -v k="$key" '$1 == k { v = $2 } END { print v }' "$cache" 2>/dev/null)
    if [ -z "$cls" ]; then
      cls=$(_driver_sa_model "$t" "$q" "$s"); how=model
      mkdir -p "$d/steps"; printf '%s\t%s\n' "$key" "$cls" >> "$cache"
    else how=model; fi
  fi
  case "$cls" in a|b|c|d|e|f) : ;; *) driver_say "   standard answer: none — $([ "$cls" = park ] && echo "a question still for a person" || echo "undecided"), so it parks"; return 1 ;; esac
  SA_CLASS="$cls"; SA_HOW="$how"
  SA_NAME=$(jq -r --arg k "$cls" '.classes[$k].name // ""' <<<"$s")
  SA_ANSWER=$(jq -r --arg k "$cls" '.classes[$k].answer // ""' <<<"$s")
  SA_ACTION=$(jq -r --arg k "$cls" '.classes[$k].action // ""' <<<"$s")
  case "$SA_ACTION" in carry|base-wait|parent-wait|dependency-wait) : ;; *) SA_CLASS=""; return 1 ;; esac
  # No pull request yet: nothing to hold, so the base's red is left to the base and the step carries on.
  if [ "$SA_ACTION" = base-wait ] && [ -z "$(driver_state_get "$t" pr)" ]; then
    SA_ACTION=carry; SA_ANSWER="$SA_ANSWER There is no pull request to hold yet, so carry on with this change and leave the base's red alone; CI is the gate."
  fi
  # (f) every ticket the question names is what this one waits for; a range "#a–#b" is each.
  if [ "$SA_ACTION" = dependency-wait ]; then
    SA_PARENT=$(jq -rn --arg q "$q" --arg t "$t" '
      ([$q | scan("#([0-9]+)\\s*[–—-]\\s*#?([0-9]+)") | (.[0] | tonumber) as $a | (.[1] | tonumber) as $b
         | select($b >= $a and $b - $a <= 10) | range($a; $b + 1) | tostring]
       + [$q | scan("#([0-9]+)") | .[0]]) | map(select(. != $t)) | unique | join(" ")' 2>/dev/null)
    [ -n "$SA_PARENT" ] || { driver_say "   standard answer: (f) reads as a wait on a dependency, and the question names no ticket — it parks"; SA_CLASS=""; return 1; }
  fi
  if [ "$SA_ACTION" = parent-wait ]; then
    SA_PARENT=$(jq -rn --arg q "$q" --arg t "$t" '
      [$q | (scan("(?i)pr #([0-9]+)"), scan("#([0-9]+) (?i:hasn|has not|isn|is not|never)"),
             scan("(?i)(?:into|until|for) (?:pr )?#([0-9]+)")) | .[0] | select(. != $t)] | first // ""' 2>/dev/null)
    # A wait on a parent nobody can name is no answer.
    [ -n "$SA_PARENT" ] || { driver_say "   standard answer: (b) reads as a wait on a parent, and the question names no pull request — it parks"; SA_CLASS=""; return 1; }
  fi
  return 0
}

driver_standard_answer_note() { # <ticket> <step> <text>
  local t="$1" step="$2" q="$3" pr br body where
  driver_say "   standard answer: ($SA_CLASS) $SA_NAME — $SA_ANSWER [$SA_HOW]"
  driver_state_set "$t" standard_answer "$SA_CLASS $step $(swarm_stamp 2>/dev/null)"
  body=$(printf '**standard answer: (%s) %s** — release.mergeFirst\n\n%s\n\nThe %s step asked: %s\n\nA standing rule answers this until the release, so it was not put to a person.' \
    "$SA_CLASS" "$SA_NAME" "$SA_ANSWER" "$step" "$(printf '%s' "$q" | tr '\n' ' ' | cut -c1-600)")
  pr=$(driver_state_get "$t" pr)
  if [ -z "$pr" ] && br=$(driver_state_get "$t" branch) && [ -n "$br" ]; then
    pr=$(swarm_gh pr list --repo "$REPO_SLUG" --head "$br" --state open --json number -q '.[0].number // empty' 2>/dev/null)
  fi
  if [ -n "$pr" ]; then where="pr comment $pr"; swarm_gh pr comment "$pr" --repo "$REPO_SLUG" --body "$body" >/dev/null 2>&1 || where=""
  else where="issue comment $t"; swarm_gh issue comment "$t" --repo "$REPO_SLUG" --body "$body" >/dev/null 2>&1 || where=""; fi
  [ -n "$where" ] || driver_say "   standard answer: it could not be written on ${pr:+PR #$pr}${pr:-#$t}"
  return 0
}
