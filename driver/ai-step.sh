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

# driver_record_usage <ticket> <slot> <log> <prompt> — what a step cost, how big its
# context got, and how many words it was given, appended under .usage[<slot>] and
# added to .spend. These are the shadow run's measurements (words per step, spend).
# The log may carry non-JSON lines, so it
# is read line by line; a step that left no result line records a cost of 0.
driver_record_usage() {
  local u words
  [ -s "$3" ] || return 0
  u=$(jq -Rsc '
    [ split("\n")[] | fromjson? // empty ] as $ev
    | [ $ev[] | select(.type == "assistant") | .message.usage // empty
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) ] as $ctx
    | ([ $ev[] | select(.type == "result") ] | last) as $r
    | { cost: ($r.total_cost_usd // 0), turns: ($r.num_turns // 0),
        ctxFirst: ($ctx | first // 0), ctxMax: ($ctx | max // 0), ctxLast: ($ctx | last // 0) }' "$3" 2>/dev/null)
  [ -n "$u" ] || return 0
  words=$(wc -w < "$4" 2>/dev/null | tr -d ' ')
  _driver_state_edit "$1" --arg s "$2" --argjson u "$u" --argjson w "${words:-0}" \
    '.usage[$s] = ((.usage[$s] // []) + [$u + {words: $w}]) | .spend = ((.spend // 0) + $u.cost)'
  driver_say "   $2: \$$(jq -r '.cost' <<<"$u") · context $(jq -r '"\(.ctxFirst)→\(.ctxMax)"' <<<"$u") tokens · ${words:-?} words given"
}

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
# The log is read a line at a time and a line that is not JSON is dropped: one
# stray warning on stdout otherwise stops the reader there, and every Skill call —
# or the whole answer — after it reads as never having happened.
driver_log_events() { jq -c -R 'fromjson? // empty' "$1" 2>/dev/null; }

driver_log_skills() {
  driver_log_events "$1" | jq -r 'select(.type=="assistant")
         | .message.content[]?
         | select(.type=="tool_use" and .name=="Skill")
         | (.input.skill // .input.name // empty)' 2>/dev/null
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
  so=$(driver_log_events "$1" | jq -r -s '[.[] | select(.type=="result") | .structured_output? // empty] | last // empty' 2>/dev/null)
  if [ -n "$so" ] && [ "$so" != "null" ]; then printf '%s' "$so"; return 0; fi
  driver_log_events "$1" | jq -r -s '[.[] | select(.type=="result")] | last | (.result // "")' 2>/dev/null \
    | sed -e '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d'
}

# driver_usage_wall <ticket> <step> <log> — 0 when the plan's usage limit stopped
# this step: the reset goes in the hold file the coordinator spawns by, and the
# reason on the record. Asked before anything reads the answer, because a wall reads
# as every other refusal — on 2026-10-18 seven runs parked as "answered in a shape
# the driver cannot read" or "did not run the Skill", and a park is never retried.
driver_usage_wall() {
  local hold epoch why
  hold=$(swarm_usage_log_reset "$3") || return 1
  epoch=$(printf '%s' "$hold" | cut -f1); why=$(printf '%s' "$hold" | cut -f2-)
  swarm_usage_hold_write "$epoch" "$why (#$1 $2)" \
    || driver_say "   $2: the usage hold could not be written to ${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}"
  driver_say "✋ $2: stopped by the plan's usage limit — spawning holds until $(swarm_iso "$epoch"): $why"
  driver_state_set "$1" park_note "the $2 step stopped on the plan's usage limit ($why); held until $(swarm_iso "$epoch")"
  return 0
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
  # THE RUN'S BRIEF, when a caller handed one (an owner's answer, a resume after a
  # cut). Every step is given it verbatim, because a step that never saw it builds as
  # if it had never been sent.
  # In repair mode it is the caller's repair brief, to every step but repair (which
  # has it as its BRIEF), so fix, self-check and review see what the PR was sent back
  # for and the reviewer can judge whether it was met. A note-less healing run's
  # class line is not a brief. A build's brief is never read in repair mode.
  local rb=""
  if [ "$(driver_state_get "$t" mode)" = repair ]; then
    [ "$(driver_state_get "$t" repair_brief_source)" = caller ] && [ "$step" != repair ] && rb=$(driver_state_get "$t" repair_brief)
  else
    rb=$(driver_state_get "$t" run_brief)
  fi
  if [ -n "$rb" ] && [ -s "$rb" ]; then
    { printf '\n---\nA brief came with this run, from whoever started it. %s Read it before anything else, and act on it where it bears on this step:\n\n' "$DRIVER_BRIEF_PREFACE"; cat "$rb"; } >> "$prompt"
  fi

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
  # A step carries only what the work inside it uses. Every tool schema and every
  # connector is re-read on every turn of every step, so each one a step never calls
  # is paid for once per turn; measured 2026-09-30, a bare step started at 70k tokens
  # of which ~6.5k were connectors and tools no step uses.
  # And the rest of the fixed load: only the tools this step uses, and the project's
  # instruction files named rather than preloaded (#11172). One builder for every
  # model call the driver makes, reviewers included.
  driver_lean_args "$wt" "$step"
  local lean=("${DRIVER_LEAN_ARGS[@]}")

  # THE DRIVER ALONE PUSHES, READIES AND ARMS. A brief written for the prose flow says
  # "push, keep auto-merge armed, hand off", and a step has Bash: a push from inside a
  # step lands through auto-merge before self-check, review and ship have run. Two
  # guards, and only the second is the guarantee:
  #   - git and gh on the step's PATH refuse push, pr ready, pr merge and pr create;
  #   - origin's head for the branch is read before and after the step, and a step
  #     it moved under refuses, whatever path it used to get there.
  local shim="$d/steps/.driver-shim" real_git real_gh pbranch before="" after="" brc=1 arc=1
  real_git=$(command -v git); real_gh=$(command -v gh 2>/dev/null || true)
  mkdir -p "$shim"
  cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
a=("\$@"); i=0; sub=""
while [ "\$i" -lt "\${#a[@]}" ]; do
  case "\${a[\$i]}" in -C|-c|--git-dir|--work-tree|--namespace) i=\$((i+2)) ;; -*) i=\$((i+1)) ;; *) sub="\${a[\$i]}"; break ;; esac
done
if [ "\$sub" = push ]; then
  echo "git push refused inside a driver step: the driver alone pushes, after the review (\${HARNESS_DRIVER_RUN:-})" >&2; exit 1
fi
exec "$real_git" "\$@"
SHIM
  # And no step writes the repo's settings: a build added a required check to the
  # live develop ruleset with `gh api` from inside a step (2026-10-20).
  local rsw="$KIT_ROOT/hooks/lib/repo-settings-write.sh"
  cat > "$shim/gh" <<SHIM
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in "pr ready"|"pr merge"|"pr create")
  echo "gh \$1 \$2 refused inside a driver step: the driver alone readies, arms and opens pull requests (\${HARNESS_DRIVER_RUN:-})" >&2; exit 1 ;;
esac
if [ -f "$rsw" ] && bash "$rsw" gh "\$@"; then
  . "$rsw"; echo "gh \$* refused inside a driver step: \$REPO_SETTINGS_WRITE_REASON (\${HARNESS_DRIVER_RUN:-})" >&2; exit 1
fi
${real_gh:+exec "$real_gh" "\$@"}
echo "gh: not installed" >&2; exit 127
SHIM
  chmod +x "$shim/git" "$shim/gh"
  pbranch=$(driver_state_get "$t" branch)
  if [ -n "$pbranch" ] && git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    before=$(git -C "$wt" ls-remote origin "refs/heads/$pbranch" 2>/dev/null); brc=$?
  fi

  local crc=0
  _driver_ai_call "$prompt" "$log" || return $?

  # ONE RE-ASK, WITH THE REASON, BEFORE A PARK. An answer the driver cannot read
  # parked the ticket outright, and the run's work with it (#13249, 2026-10-17); the
  # same session is asked once more, told exactly what was wrong. Bounded at one: a
  # second unreadable answer parks as before.
  local jrc=0 reask_why="" first_log="$log.first" note_was
  note_was=$(driver_state_get "$t" park_note)
  _driver_ai_judge || jrc=$?
  if [ "$jrc" -eq "$DRIVER_E_SCHEMA" ] && [ -n "$reask_why" ] && [ "${DRIVER_SCHEMA_REASKS:-1}" -gt 0 ]; then
    local reask="$d/steps/$slot.reask.prompt" sid
    sid=$(driver_log_events "$log" | jq -r 'select(.session_id? != null) | .session_id' 2>/dev/null | tail -1)
    [ -z "$sid" ] || : > "$reask"
    [ -n "$sid" ] || cp "$prompt" "$reask"
    printf '\n---\nYour answer could not be read by the driver: %s\nAnswer again: JSON only, valid against schemas/%s.json. The Return section lists every field it allows and when each one is required. Keep the work you have done; change only the shape of the answer.\n' \
      "$reask_why" "$step" >> "$reask"
    driver_say "↩ $step: the answer could not be read — asking once more with the reason: $(printf '%s' "$reask_why" | cut -c1-200)"
    [ ! -f "$ans" ] || cp "$ans" "$d/steps/$slot.first.json"
    cp "$log" "$first_log"
    crc=0; _driver_ai_call "$reask" "$log.reask" "$sid" || crc=$?
    [ "$crc" -eq 0 ] || { cat "$log.reask" >> "$log"; return "$crc"; }
    # Both transcripts, in order: the skills ran in the first, the answer is the last result.
    cat "$log.reask" >> "$log"
    jrc=0; _driver_ai_judge || jrc=$?
    # A re-ask that was read leaves no note behind for a later refusal to be mistaken for,
    # and nor does one that asked a question: the stale "not JSON" note outranks the
    # question at the park, which is how an API error reached the owner as his question.
    [ "$jrc" -ne 0 ] && [ "$jrc" -ne "$DRIVER_E_QUESTION" ] || driver_state_set "$t" park_note "$note_was"
  fi
  return "$jrc"
}

# driver_api_error <log> — 0, printing what failed, when the call never answered at the
# API (swarm_api_error_log). Read before the answer, because read as an answer it is
# "not JSON", and that parked #13642 for the owner over a false safeguards flag.
driver_api_error() { swarm_api_error_log "$1"; }

# driver_question_silent_agent <question> — 0 when a step's "question" is that a subagent
# it started had not reported: still running, timed out, or returned nothing. That has
# one answer (run it again), so it is the machine's, never a person's question.
driver_question_silent_agent() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -Eq \
    "(sub-?agent|reviewer|review agent|agent)[^.?!]*((had|has|have|did|was|is)( not|n't)( yet)? (report|return|finish|complet|answer|respond|come back)|still running|timed? ?out|never (report|return|finish|answer))|(timed? ?out|still running)[^.?!]*(sub-?agent|reviewer)"
}

# _driver_ai_call <prompt> <log> [session-id] — one model call, its spend and the usage
# wall, from driver_ai_step's locals. A call that failed at the API is made ONCE more
# after DRIVER_API_RETRY_SEC; failing again it is a machine fault, never a question.
# No step chunks its diff, so a safeguards flag is retried whole.
_driver_ai_call() {
  local in="$1" out="$2" sid="${3:-}" err
  _driver_ai_run "$in" "$out" "$sid"
  driver_record_usage "$t" "$slot" "$out" "$in"
  driver_usage_wall "$t" "$step" "$out" && return "$DRIVER_E_USAGE"
  err=$(driver_api_error "$out") || return 0
  driver_say "↻ $step: the model call failed at the API — $err. Trying once more in ${DRIVER_API_RETRY_SEC:-30}s."
  cp "$out" "$out.apierr" 2>/dev/null
  sleep "${DRIVER_API_RETRY_SEC:-30}"
  _driver_ai_run "$in" "$out" "$sid"
  driver_record_usage "$t" "$slot" "$out" "$in"
  driver_usage_wall "$t" "$step" "$out" && return "$DRIVER_E_USAGE"
  err=$(driver_api_error "$out") || return 0
  driver_say "✋ $step: the model call failed at the API twice — $err. A machine fault, not a question."
  driver_state_set "$t" park_note "machine fault, nothing to answer: the $step model call failed at the API twice ($err). The next run tries again."
  return "$DRIVER_E_MACHINE"
}

# _driver_ai_run <prompt> <log> [session-id] — one model call in the ticket's
# worktree, from driver_ai_step's locals. With a session id it resumes that session.
_driver_ai_run() {
  local in="$1" out="$2" sid="${3:-}"
  local resume=() dbw=()
  [ -z "$sid" ] || resume=(--resume "$sid")
  # The steps that run the project's tests get the throwaway database the proof gets.
  case "$step" in build|fix|repair) dbw=(driver_with_test_db --soft "$out.db" "$wt") ;; esac
  rm -f "$out.db"
  (
    cd "$wt" || exit 1
    export PATH="$shim:$PATH"
    # The Stop hook stands down for a driver step: the sign-off banner is an
    # instruction to a person's terminal, and here it rewrites a machine's answer.
    export HARNESS_DRIVER_RUN="${DRIVER_TICKET:-$t}:$step"
    if [ -n "$schema_for_model" ]; then
      ${dbw[@]+"${dbw[@]}"} "$DRIVER_CLAUDE" -p ${resume[@]+"${resume[@]}"} \
        --output-format stream-json --verbose --name "$step" \
        --permission-mode "$DRIVER_PERMISSION_MODE" "${lean[@]}" \
        --add-dir "$wt" --json-schema "$(cat "$schema_for_model")" \
        < "$in" > "$out" 2>"$out.err"
    else
      ${dbw[@]+"${dbw[@]}"} "$DRIVER_CLAUDE" -p ${resume[@]+"${resume[@]}"} \
        --output-format stream-json --verbose --name "$step" \
        --permission-mode "$DRIVER_PERMISSION_MODE" "${lean[@]}" \
        --add-dir "$wt" < "$in" > "$out" 2>"$out.err"
    fi
  ) || true
  [ ! -s "$out.db" ] || driver_say "   $step: ran with no test database — $(cat "$out.db")"
}

# _driver_ai_judge — the checks on the transcript in $log, from driver_ai_step's
# locals. Sets reask_why when the only fault is the answer's shape.
_driver_ai_judge() {
  reask_why=""
  if [ "$brc" -eq 0 ]; then
    after=$(git -C "$wt" ls-remote origin "refs/heads/$pbranch" 2>/dev/null); arc=$?
    if [ "$arc" -ne 0 ] || [ "$(printf '%s' "$before" | cut -f1)" != "$(printf '%s' "$after" | cut -f1)" ]; then
      driver_say "✋ $step: origin/$pbranch moved while the step ran ($(printf '%s' "$before" | cut -c1-8) → $( [ "$arc" -eq 0 ] && printf '%s' "$after" | cut -c1-8 || echo unreadable)). A step never pushes: the driver alone pushes, after the review — and on a PR with auto-merge armed that push may already have merged."
      driver_state_set "$t" park_note "origin/$pbranch moved during the $step step — a push from inside a step, which the driver never makes; check whether PR auto-merge already landed it"
      return "$DRIVER_E_REFUSED"
    fi
  fi

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
    reask_why="the run ended with no answer at all"
    driver_state_set "$t" park_note "the $step step ended without an answer"
    return "$DRIVER_E_SCHEMA"
  fi
  if ! printf '%s' "$result" | jq -e . >/dev/null 2>&1; then
    driver_say "✋ $step: the answer is not JSON — $(printf '%s' "$result" | head -c 120)"
    reask_why="the answer is not JSON: $(printf '%s' "$result" | head -c 200)"
    driver_state_set "$t" park_note "the $step answer is not JSON: $(printf '%s' "$result" | head -c 200)"
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
    # Harmless variance is settled before the contract reads it: a null optional field
    # is an absent one, and a SHIP beside a blocking finding is a BLOCKED.
    jq 'del(..|nulls) | if (.verdict? == "SHIP") and ([.findings[]? | select((.grade // "") | IN("critical","major","minor"))] | length > 0) then .verdict = "BLOCKED" else . end' \
      "$ans" > "$ans.norm" 2>/dev/null && [ -s "$ans.norm" ] && mv "$ans.norm" "$ans" || rm -f "$ans.norm"
    # From a directory that exists: npx refuses to start ("getcwd: cannot access parent
    # directories") when the step's working folder was deleted under it, and that crash
    # read as "the answer was never checked" and parked finished work.
    vout=$(cd "$DRIVER_HOME" 2>/dev/null || cd /; BRIEFS_SCHEMAS="$DRIVER_SCHEMAS" bash "$validator" "$step" "$ans" 2>&1); vrc=$?
    why=$(printf '%s' "$vout" | grep -v 'strict mode' | tr '\n' ' ' | tr -s ' ' | cut -c1-400)
    if [ "$vrc" -eq 1 ]; then
      driver_say "✋ $step: the answer does not match briefs/schemas/$step.json — $why"
      driver_state_set "$t" park_note "$step answered outside briefs/schemas/$step.json: $why"
      reask_why="the validator refused it against schemas/$step.json: $why"
      return "$DRIVER_E_SCHEMA"
    elif [ "$vrc" -ne 0 ]; then
      driver_say "✋ $step: briefs/schemas/$step.json could not be read, so NOTHING about this answer was checked — $why"
      driver_state_set "$t" park_note "the $step answer was never checked against briefs/schemas/$step.json (validate.sh exited $vrc): $why"
      return "$DRIVER_E_SCHEMA"
    fi
  fi

  return "$DRIVER_OK"
}
