#!/usr/bin/env bash
# ai-step.sh — the one place the driver hands control to a model, and therefore
# the one place it has to be suspicious.
#
#   driver_ai_step <ticket> <step> [--as <slot>] [context-file…]
#
# It fills the brief's placeholders, runs the step INSIDE the ticket's worktree,
# keeps the transcript, and then checks four things before it believes the answer:
#
#   0. THE BRIEF WAS ACTUALLY FILLED IN. briefs/README.md: "substitute all of them
#      before sending … a placeholder left unfilled reaches the model literally."
#      Nothing substituted, so on the 2026-09-27 trial the plan prompt was
#      byte-identical for two different tickets and six placeholders reached the
#      model as text. A placeholder with no value is now a refusal, because an odd
#      prompt cannot be seen from outside and a stopped step can.
#   1. THE NAMED SKILLS ACTUALLY RAN. This used to read a `skill:` front-matter
#      line, and no shipped brief has one — so `skill_want` was empty, exit 21
#      could never fire, and all three AI steps were ungated. It was invisible
#      because the fixture WROTE that front matter into its own briefs. The set now
#      comes from briefs/facts.json, which is where the briefs declare it, and the
#      answer's own `skills` array is cross-checked against the log as well: a
#      skill claimed in the answer and absent from the transcript is a failed step.
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
#
# WHERE THE ANSWER IS READ FROM. `structured_output` on the result object, not the
# last message. The kit's own Stop hook (signoff-backstop) replaces the final
# message with the sign-off banner, and on the trial that made every AI answer
# unreadable: the whole of `.result` was four lines of banner with no JSON in it.
# Measured 2026-09-28: with `--json-schema` passed, `structured_output` carries the
# answer and survives that nag intact. The hook is also told to stand down through
# HARNESS_DRIVER_RUN — both halves, because either one alone leaves a way for an
# instruction meant for a person to rewrite a machine's answer.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/facts.sh" || exit 1

# The Skill a brief names in its own front matter, when it has one. Kept because a
# brief MAY pin one, and the fixtures that write it are testing a real feature —
# but it is no longer the only source, and it was never present on a shipped brief.
driver_brief_skill() { sed -n '1,20{/^skill:[[:space:]]*/s///p;}' "$1" | head -1 | tr -d '[:space:]'; }

# The skills briefs/facts.json declares for a step: the machine-readable list the
# briefs own and the driver never read. Empty when there is no facts.json, which is
# normal for a fixture pointing DRIVER_BRIEFS at a directory of its own.
driver_declared_skills() { # <step>
  local f="$DRIVER_BRIEFS/facts.json"
  [ -f "$f" ] || return 0
  jq -r --arg s "$1" '(.steps[$s].skills // [])[]' "$f" 2>/dev/null
}

# THE SKILLS THAT ARE NEVER A TOOL CALL, and therefore can never appear in a
# transcript however faithfully they were followed. `superpowers:using-superpowers`
# is Superpowers' own introduction: it arrives in the system prompt, so an answer
# naming it among its skills is describing something true that the log structurally
# cannot show.
#
# Measured on the 2026-09-28 trial: build task 3 of 6 answered
# ["superpowers:using-superpowers","superpowers:subagent-driven-development",
#  "superpowers:test-driven-development"], the line above it recorded both of the
# declared skills running, and the claim check parked the ticket anyway — 73 minutes
# and 9 unpushed commits lost to which phrasing the model happened to pick. Tasks 1
# and 2 did not name it and passed, which is the definition of a coin flip.
#
# briefs/facts.json already carried this list under `notInvoked` and nothing read it.
driver_never_invoked_skills() {
  local f="$DRIVER_BRIEFS/facts.json"
  [ -f "$f" ] || return 0
  jq -r '(.notInvoked // {}) | keys[]' "$f" 2>/dev/null
}

# Every Skill the transcript shows being invoked, one per line. `claude -p
# --output-format stream-json` emits one JSON object per line; a Skill call is a
# tool_use block named Skill whose input carries the skill's name.
driver_log_skills() {
  jq -r 'select(.type=="assistant")
         | .message.content[]?
         | select(.type=="tool_use" and .name=="Skill")
         | (.input.skill // .input.name // empty)' "$1" 2>/dev/null
}

# The model's final answer.
#
# `structured_output` FIRST. It is the validated tool output the `--json-schema`
# run produces, and it is the only field a Stop hook cannot rewrite. `.result` is
# the fallback, for a run with no contract to bind and for every recorded fixture
# written before this field existed.
#
# A fenced block is still an answer: models fence JSON by habit, and refusing one
# would be refusing the right answer for its packaging.
# The LAST result OBJECT, not the last line: an answer is routinely several lines
# of JSON, and `| tail -1` on the text would have handed back its closing brace.
driver_log_result() {
  local so
  so=$(jq -r -s '[.[] | select(.type=="result") | .structured_output? // empty] | last // empty' "$1" 2>/dev/null)
  if [ -n "$so" ] && [ "$so" != "null" ]; then printf '%s' "$so"; return 0; fi
  jq -r -s '[.[] | select(.type=="result")] | last | (.result // "")' "$1" 2>/dev/null \
    | sed -e '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d'
}

driver_ai_step() { # <ticket> <step> [--as <slot>] [context-file…]
  local t="${1:?driver_ai_step: need a ticket}" step="${2:?driver_ai_step: need a step}"; shift 2
  local slot="$step"
  while [ $# -gt 0 ]; do
    case "$1" in
      --as) slot="${2:?--as needs a name}"; shift 2 ;;
      *) break ;;
    esac
  done
  local d brief log ans prompt schema_for_model wt unfilled
  local skill_want skill_saw want claimed result why
  d=$(driver_state_dir "$t"); mkdir -p "$d/steps"
  brief="$DRIVER_BRIEFS/$step.md"
  log="$d/steps/$slot.log"; ans="$d/steps/$slot.json"

  if [ ! -f "$brief" ]; then
    driver_say "✋ $step: no brief at $brief — the briefs are a separate deliverable and this step cannot run without one."
    return "$DRIVER_E_NO_BRIEF"
  fi

  # 0. the brief, filled in. The step gathers its own facts before calling; the
  # common ones are gathered here so no step can forget them.
  driver_facts_common "$t" "$slot"
  prompt="$d/steps/$slot.prompt"
  unfilled=$(driver_substitute "$brief" "$(driver_fact_dir "$t" "$slot")" "$prompt") || {
    driver_say "✋ $step: the brief still carries unfilled placeholders — $unfilled. A placeholder with no value reaches the model as text, which is how two different tickets got the same prompt."
    driver_state_set "$t" park_note "the $step brief was sent with nothing in $unfilled — briefs/facts.json declares them and the driver had no value"
    return "$DRIVER_E_REFUSED"
  }
  local c; for c in "$@"; do [ -f "$c" ] && { printf '\n---\n'; cat "$c"; } >> "$prompt"; done

  # The contract, relaxed, so the model is BOUND to the answer's shape rather than
  # asked for it in prose. Derived from the contract by prompt-schema.jq — never a
  # second schema kept beside it.
  schema_for_model=""
  if [ -f "$DRIVER_SCHEMAS/$step.json" ] && [ -f "$DRIVER_HOME/prompt-schema.jq" ]; then
    schema_for_model="$d/steps/$slot.schema.json"
    jq -f "$DRIVER_HOME/prompt-schema.jq" "$DRIVER_SCHEMAS/$step.json" > "$schema_for_model" 2>/dev/null \
      || schema_for_model=""
    [ -s "${schema_for_model:-/nonexistent}" ] || schema_for_model=""
  fi

  # IN THE TICKET'S WORKTREE. With no cd the build agent edits the shared checkout
  # on whatever branch a peer left checked out, and the plan agent reads that tree
  # instead of the one the ticket was cut into.
  wt=$(driver_state_get "$t" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { wt="$MAIN_REPO"; driver_say "   $step: no worktree on the record, running in $MAIN_REPO"; }

  # THE PROMPT GOES ON STDIN, NOT IN ARGV. `-p "$(cat …)"` puts the whole prompt in
  # the argument list, and that list has a ceiling: measured on this machine ARG_MAX
  # is 1,048,576 bytes and a 1.5 MB prompt comes back as `Argument list too long`
  # with no transcript — which the driver then reports as "the agent produced no
  # answer" under exit 22, "the answer did not meet its contract". Both name the
  # wrong thing, and every retry hits it again. Before the briefs were substituted
  # the prompt was a few KB and this could not happen; now it carries the ticket,
  # this project's facts and the review step's whole diff, so it can.
  (
    cd "$wt" || exit 1
    # The Stop hook stands down for a driver step: the sign-off banner is an
    # instruction to a person's terminal, and here it rewrites a machine's answer.
    export HARNESS_DRIVER_RUN="${DRIVER_TICKET:-$t}:$step"
    if [ -n "$schema_for_model" ]; then
      "$DRIVER_CLAUDE" -p \
        --output-format stream-json --verbose --name "$step" \
        --add-dir "$wt" --json-schema "$(cat "$schema_for_model")" \
        < "$prompt" > "$log" 2>"$log.err"
    else
      "$DRIVER_CLAUDE" -p \
        --output-format stream-json --verbose --name "$step" \
        --add-dir "$wt" < "$prompt" > "$log" 2>"$log.err"
    fi
  ) || true

  # The step's own tooling writes a working plan into the tree; it is not the change.
  # Swept before anything reads the tree, so no later step has to know about it.
  #
  # ONLY A TICKET WORKTREE. `wt` falls back to the SHARED checkout above when this
  # run has none on the record, and the shared checkout is where peer windows work —
  # sweeping there moves another agent's untracked files out from under them.
  if [ -n "$(driver_state_get "$t" worktree)" ]; then
    driver_sweep_scratch "$t" "$wt"
  fi

  if [ ! -s "$log" ]; then
    driver_say "✋ $step: the agent produced no transcript — $(head -3 "$log.err" 2>/dev/null | tr '\n' ' ')"
    return "$DRIVER_E_SCHEMA"
  fi

  # 1. the skills. The declared set first — at least one of a step's own skills has
  # to appear, or the step did not run. Then the answer's claims, below, once there
  # is an answer to read them from.
  skill_saw=$(driver_log_skills "$log")
  skill_want=$(driver_brief_skill "$brief")
  want=$(printf '%s\n%s\n' "$skill_want" "$(driver_declared_skills "$step")" | grep -v '^$' | sort -u)
  if [ -n "$want" ]; then
    local hit=0 k
    while IFS= read -r k; do
      [ -n "$k" ] || continue
      printf '%s\n' "$skill_saw" | grep -qxF "$k" && { hit=1; break; }
    done <<EOW
$want
EOW
    if [ "$hit" -eq 0 ]; then
      driver_say "✋ $step: the brief's skills are $(printf '%s' "$want" | tr '\n' ' ')and the run log does not contain any of those Skill calls (saw: ${skill_saw:-none}). Inside a ticket Superpowers does the work; a step that skipped it has not run."
      driver_state_set "$t" park_note "the $step step ran none of the skills briefs/facts.json declares for it ($(printf '%s' "$want" | tr '\n' ' ')); the transcript shows: ${skill_saw:-none}"
      return "$DRIVER_E_NO_SKILL"
    fi
    driver_say "   $step: $(printf '%s' "$skill_saw" | sort -u | tr '\n' ' ')ran"
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
  # The step's own latest answer, whatever slot produced it. build calls this once
  # per plan task, and the orchestrator reads the question off `steps/<step>.json`.
  [ "$slot" = "$step" ] || printf '%s\n' "$result" | jq . > "$d/steps/$step.json"

  # 1b. A SKILL CLAIMED IN THE ANSWER AND ABSENT FROM THE LOG IS A FAILED STEP.
  # Every brief says so in its own Return section and nothing checked it.
  claimed=$(jq -r '(.skills // [])[]' "$ans" 2>/dev/null)
  local never; never=$(driver_never_invoked_skills)
  local miss="" k2
  while IFS= read -r k2; do
    [ -n "$k2" ] || continue
    # A skill that is never a tool call is skipped, not counted as missing: the
    # transcript cannot show it whether or not it was followed, so demanding it
    # there measures the model's phrasing and nothing else.
    printf '%s\n' "$never" | grep -qxF "$k2" && continue
    printf '%s\n' "$skill_saw" | grep -qxF "$k2" || miss="$miss $k2"
  done <<EOC
$claimed
EOC
  if [ -n "$miss" ]; then
    driver_say "✋ $step: the answer claims${miss} and the run log shows no such Skill call (saw: ${skill_saw:-none}). A claim the transcript does not show is the one thing the JSON cannot tell you."
    # THE PARK'S QUESTION IS ABOUT THE CLAIM, not about the brief. The orchestrator's
    # wording for exit 21 is "the step did not run the Skill its brief names", which on
    # the trial was printed one line under a record of both named skills running — a
    # question nobody can answer because it describes something that did not happen.
    driver_state_set "$t" park_note "the $step answer claims${miss}, and the transcript shows no such Skill call (it shows: ${skill_saw:-none}). Either the answer named a skill it did not run, or that skill is never a tool call and belongs in briefs/facts.json's notInvoked."
    return "$DRIVER_E_NO_SKILL"
  fi

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
  # THIS IS ALSO WHY THE SCHEMA SENT TO THE MODEL IS NOT THIS ONE. The API's tool
  # input schema refuses `allOf` at the top level and prompt-schema.jq drops it; the
  # rules it drops are enforced here, against the unrelaxed contract.
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
  # DRIVER_VALIDATE unbound is reachable: the header skips sourcing driver-env.sh when
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
