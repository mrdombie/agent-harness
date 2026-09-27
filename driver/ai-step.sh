#!/usr/bin/env bash
# ai-step.sh — the one place the driver hands control to a model, and therefore
# the one place it has to be suspicious.
#
#   driver_ai_step <ticket> <step> [context-file…]
#
# It runs the step's brief, keeps the transcript, and then checks three things
# before it believes the answer:
#
#   1. THE NAMED SKILL ACTUALLY RAN. A brief's front matter names one Skill —
#      `skill: superpowers:subagent-driven-development` on the build brief. The
#      driver greps the run log for that Skill call and parks the ticket when it
#      is absent. (Dom, 2026-09-27.) This is the difference between a discipline
#      and a wish: the "mandatory" Superpowers steps were used in 3 of 161 runs
#      precisely because nothing ever looked. A model that answers in the right
#      shape without running the skill is the failure this catches, and the JSON
#      alone cannot tell you it happened.
#   2. IT ANSWERED RATHER THAN ASKED. Any step may return a question instead;
#      that parks the ticket with it, which is the design's "always asks rather
#      than guesses".
#   3. THE ANSWER MATCHES ITS SCHEMA, when one exists. `briefs/schemas/<step>.json`
#      belongs to the briefs ticket. Absent is normal and not an error — the
#      driver must work before those land — but present and unmatched is a refusal.
#
# The checks are in that order on purpose. An answer that never ran its skill is
# not made trustworthy by being well-shaped, so the shape is checked last.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1

# The Skill the brief names, from its front matter. Empty when it names none —
# a brief without a skill is held to no skill, rather than to a guess.
driver_brief_skill() { sed -n '1,20{/^skill:[[:space:]]*/s///p;}' "$1" | head -1 | tr -d '[:space:]'; }

# Every Skill the transcript shows being invoked, one per line. `claude -p
# --output-format stream-json` emits one JSON object per line; a Skill call is a
# tool_use block named Skill whose input carries the skill's name.
driver_log_skills() {
  jq -r 'select(.type=="assistant")
         | .message.content[]?
         | select(.type=="tool_use" and .name=="Skill")
         | (.input.skill // .input.name // empty)' "$1" 2>/dev/null
}

# The model's final answer, unwrapped. A fenced block is still an answer: models
# fence JSON by habit, and refusing one would be refusing the right answer for
# its packaging.
# The LAST result OBJECT, not the last line: an answer is routinely several lines
# of JSON, and `| tail -1` on the text would have handed back its closing brace.
driver_log_result() {
  jq -r -s '[.[] | select(.type=="result")] | last | (.result // "")' "$1" 2>/dev/null \
    | sed -e '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d'
}

# driver_check_schema <schema.json> <answer.json> — `required` and each named
# property's `type`, and nothing more.
#
# Deliberately not a JSON Schema implementation. The kit cannot take an npm
# dependency for this, and the half a validator that a shell can honestly do is
# worth more than the whole one it would fake: these two rules catch a missing
# key and a string where an array belongs, which is every shape failure seen so
# far. What it does NOT check, it does not claim to.
driver_check_schema() {
  local schema="$1" answer="$2" missing wrong
  # Bound to $k: inside `has()` the dot is the object being asked, not the key,
  # so the unbound form silently asked whether the answer has itself — and every
  # missing key passed.
  missing=$(jq -r --slurpfile a "$answer" \
    '(.required // [])[] as $k | select(($a[0] | has($k)) | not) | $k' "$schema" 2>/dev/null)
  [ -z "$missing" ] || { printf 'missing: %s' "$(printf '%s' "$missing" | tr '\n' ' ')"; return 1; }
  wrong=$(jq -r --slurpfile a "$answer" '
    (.properties // {}) | to_entries[]
    | select(.value.type != null)
    | . as $p
    | ($a[0][$p.key]) as $v
    | select($v != null)
    | ($v | type) as $t
    | select( if $p.value.type == "integer" then ($t != "number") else ($t != $p.value.type) end )
    | "\($p.key) is \($t), wanted \($p.value.type)"' "$schema" 2>/dev/null)
  [ -z "$wrong" ] || { printf '%s' "$(printf '%s' "$wrong" | tr '\n' '; ')"; return 1; }
  return 0
}

driver_ai_step() { # <ticket> <step> [context-file…]
  local t="${1:?driver_ai_step: need a ticket}" step="${2:?driver_ai_step: need a step}"; shift 2
  local d brief log ans skill_want skill_saw result why
  d=$(driver_state_dir "$t"); mkdir -p "$d/steps"
  brief="$DRIVER_BRIEFS/$step.md"
  log="$d/steps/$step.log"; ans="$d/steps/$step.json"

  if [ ! -f "$brief" ]; then
    driver_say "✋ $step: no brief at $brief — the briefs are a separate deliverable and this step cannot run without one."
    return "$DRIVER_E_NO_BRIEF"
  fi
  skill_want=$(driver_brief_skill "$brief")

  # The prompt is the brief plus whatever the earlier steps produced. Passing it
  # on a file rather than inline keeps the step's input reproducible: the same
  # file is what a person re-reads when the answer looks wrong.
  local prompt="$d/steps/$step.prompt"
  { cat "$brief"; local c; for c in "$@"; do [ -f "$c" ] && { printf '\n---\n'; cat "$c"; }; done; } > "$prompt"

  "$DRIVER_CLAUDE" -p "$(cat "$prompt")" \
    --output-format stream-json --verbose --name "$step" > "$log" 2>"$log.err" || true

  if [ ! -s "$log" ]; then
    driver_say "✋ $step: the agent produced no transcript — $(head -3 "$log.err" 2>/dev/null | tr '\n' ' ')"
    return "$DRIVER_E_SCHEMA"
  fi

  # 1. the named Skill
  if [ -n "$skill_want" ]; then
    skill_saw=$(driver_log_skills "$log")
    if ! printf '%s\n' "$skill_saw" | grep -qxF "$skill_want"; then
      driver_say "✋ $step: the brief names $skill_want and the run log does not contain that Skill call (saw: ${skill_saw:-none}). Inside a ticket Superpowers does the work; a step that skipped it has not run."
      return "$DRIVER_E_NO_SKILL"
    fi
    driver_say "   $step: $skill_want ran"
  fi

  result=$(driver_log_result "$log")
  if [ -z "$result" ]; then
    driver_say "✋ $step: the agent ended without an answer."
    return "$DRIVER_E_SCHEMA"
  fi
  if ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
    driver_say "✋ $step: the answer is not JSON — $(printf '%s' "$result" | head -c 120)"
    return "$DRIVER_E_SCHEMA"
  fi
  printf '%s\n' "$result" | jq . > "$ans"

  # 2. a question instead of an answer
  local q; q=$(jq -r '(.question // .park // empty)' "$ans" 2>/dev/null)
  if [ -n "$q" ] && [ "$q" != "null" ] && [ "$q" != "false" ]; then
    driver_say "✋ $step asked rather than guessed: $q"
    return "$DRIVER_E_QUESTION"
  fi

  # 3. the schema, when the briefs ticket has landed one
  if [ -f "$DRIVER_SCHEMAS/$step.json" ]; then
    if ! why=$(driver_check_schema "$DRIVER_SCHEMAS/$step.json" "$ans"); then
      driver_say "✋ $step: the answer does not match briefs/schemas/$step.json — $why"
      return "$DRIVER_E_SCHEMA"
    fi
  fi

  return "$DRIVER_OK"
}
