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
#   3. THE ANSWER MEETS ITS CONTRACT, when one exists. `briefs/schemas/<step>.json`
#      belongs to the briefs ticket. Absent is normal and not an error — the
#      driver must work before those land — but present and unmatched is a refusal,
#      and so is a contract that could not be READ: an unparseable schema, a schemas
#      directory that is not there, a path that is a directory or a dead symlink, a
#      validator that could not be reached. The check is one call to
#      `briefs/validate.sh`, which is the only thing here that reads a WHOLE schema.
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

  # 3. the contract, when the briefs ticket has landed one.
  #
  # ONE CALL, because the strictness is not in `required`. What used to sit here was
  # half a JSON Schema validator written in jq — top-level `required` plus top-level
  # property `type`, and nothing else. Measured over briefs/examples: it accepted 19
  # of the 24 invalid answers the contracts exist to refuse, two of them the epic's
  # headline guarantees — a build whose test passed BEFORE the change, and a review
  # that returns SHIP beside an open blocker. The rules that catch those live in
  # `additionalProperties: false`, in nested `required`, in `failedBefore` pinned to
  # `true`, and in an `if`/`then`; none of them is expressible in a shell.
  #
  # The reason it was hand-rolled — the kit cannot take an npm dependency — does not
  # hold: validate.sh runs `npx --yes ajv-cli@5` on demand, nothing enters a manifest,
  # and BRIEFS_AJV points at an installed copy where one exists.
  #
  # EXIT 2 IS NOT A PASS. A validator answering 0 when it validated nothing reads
  # exactly like one that validated everything, so a contract that could not be read
  # parks the ticket as well — and the park carries what could not be done rather than
  # a question about the brief's Return section.
  # AND A CONTRACT THAT CANNOT BE REACHED IS NOT A CONTRACT THAT IS ABSENT. `-f`
  # alone answers "no schema, which is normal" to three states that are not that:
  # a DRIVER_SCHEMAS pointing one directory off — which disables all seven steps at
  # once — a schema path that is a directory, and a dangling symlink. Each returned
  # 0 with nothing said, which is this call's own thesis left standing somewhere
  # else. The directory has to exist; a path inside it that exists and is not a
  # readable file is a refusal; only a genuinely missing file is the normal absence.
  local vout vrc validator="${DRIVER_VALIDATE:-}"
  # DRIVER_VALIDATE unbound is reachable: line 29 skips sourcing driver-env.sh when
  # DRIVER_DIR is already exported, so a shell carrying an older driver-env's exports
  # has DRIVER_DIR and not this. Unguarded, `bash "$DRIVER_VALIDATE"` died under
  # `set -u` with status 1 — the "your answer is wrong" branch, about a valid answer.
  [ -n "$validator" ] || validator="$DRIVER_HOME/../briefs/validate.sh"
  if [ ! -d "$DRIVER_SCHEMAS" ]; then
    driver_say "✋ $step: there are no contracts at $DRIVER_SCHEMAS, so NOTHING about this answer was checked."
    driver_state_set "$t" park_note "the $step answer was never checked: DRIVER_SCHEMAS names $DRIVER_SCHEMAS and no such directory exists"
    return "$DRIVER_E_SCHEMA"
  fi
  if { [ -e "$DRIVER_SCHEMAS/$step.json" ] || [ -L "$DRIVER_SCHEMAS/$step.json" ]; } \
     && [ ! -f "$DRIVER_SCHEMAS/$step.json" ]; then
    driver_say "✋ $step: briefs/schemas/$step.json is there and is not a readable file, so NOTHING about this answer was checked."
    driver_state_set "$t" park_note "the $step answer was never checked: $DRIVER_SCHEMAS/$step.json is not a readable file"
    return "$DRIVER_E_SCHEMA"
  fi
  if [ -f "$DRIVER_SCHEMAS/$step.json" ]; then
    vout=$(BRIEFS_SCHEMAS="$DRIVER_SCHEMAS" bash "$validator" "$step" "$ans" 2>&1); vrc=$?
    why=$(printf '%s' "$vout" | tr '\n' ' ' | cut -c1-400)
    if [ "$vrc" -eq 1 ]; then
      driver_say "✋ $step: the answer does not match briefs/schemas/$step.json — $why"
      driver_state_set "$t" park_note "$step answered outside briefs/schemas/$step.json: $why"
      return "$DRIVER_E_SCHEMA"
    elif [ "$vrc" -ne 0 ]; then
      driver_say "✋ $step: briefs/schemas/$step.json could not be read, so NOTHING about this answer was checked — $why"
      driver_state_set "$t" park_note "the $step answer was never checked against briefs/schemas/$step.json (validate.sh exited $vrc): $why"
      return "$DRIVER_E_SCHEMA"
    fi
  fi

  return "$DRIVER_OK"
}
