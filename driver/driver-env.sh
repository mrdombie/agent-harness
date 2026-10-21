#!/usr/bin/env bash
# driver-env.sh — the one place the driver resolves WHERE things are and HOW it
# reaches the outside world.
#
#   . "$KIT_ROOT/driver/driver-env.sh" || exit 1
#
# It sits on swarm/swarm-env.sh rather than beside it. The swarm layer already
# resolves the state dir, the project's labels, the GitHub seam and the clock,
# and a second copy of that resolution is a second thing to keep in step — the
# drift this whole epic exists to remove.
#
# Sets, on top of everything swarm-env.sh sets:
#   DRIVER_DIR       per-ticket run records: $STATE_DIR/driver/<ticket>
#   DRIVER_BRIEFS    the AI step briefs (owned by the briefs ticket, read here)
#   DRIVER_SCHEMAS   $DRIVER_BRIEFS/schemas — the JSON each brief must return
#   DRIVER_VALIDATE  briefs/validate.sh — the one thing that reads a whole schema
#   DRIVER_STEPS     the fixed order, one name per step
#   DRIVER_MAX_BUILD_TRIES   red-before-green attempts before the ticket parks (5)
#   DRIVER_MAX_REVIEW_ROUNDS review rounds before leftovers become a ticket (2)
#
# The seams, each overridable so a test points it at a recorder:
#   DRIVER_CLAUDE    the agent runner   (default: claude)
#   SWARM_GH         the GitHub CLI     (inherited from swarm-env)
#
# Exit codes are the driver's whole control flow, so they are named once here and
# nowhere else:
#   0  the step finished
#   20 the step asked a question — the ticket parks with it
#   21 the brief named a Skill and the run log does not contain that Skill call
#   22 the answer did not meet its contract, or the contract could not be read
#   23 there is no brief for this step
#   24 a refusal gate said no
#   25 a command outran its time limit — a hang is not a failure to retry
#   30 the reviewer found a Critical or a Major — go back to the build step
_driver_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_driver_self")/../swarm" && pwd)/swarm-env.sh" || return 1 2>/dev/null || exit 1
DRIVER_HOME="$(cd "$(dirname "$_driver_self")" && pwd)"
unset _driver_self

DRIVER_DIR="${DRIVER_DIR:-$STATE_DIR/driver}"
DRIVER_BRIEFS="${DRIVER_BRIEFS:-$KIT_ROOT/briefs}"
DRIVER_SCHEMAS="${DRIVER_SCHEMAS:-$DRIVER_BRIEFS/schemas}"
# The validator is the kit's, not the briefs directory's. DRIVER_BRIEFS is a seam
# a fixture points at a temp dir holding only the briefs it wrote, so resolving
# the validator through it would have made it absent in every test — and an absent
# validator that read as "nothing to check" is the failure this whole call exists
# to end. It is separately overridable so a test can hand over one that refuses.
DRIVER_VALIDATE="${DRIVER_VALIDATE:-$KIT_ROOT/briefs/validate.sh}"
mkdir -p "$DRIVER_DIR" 2>/dev/null || true

# The order. It is a list, not a set: "runs the steps in order" is the guarantee,
# and the orchestrator walks exactly this.
# `fix` sits after `build` because a rework rewinds to it, and a step that is
# conditionally skipped reports exactly like a step that passed — so it is in the
# order on every pass and is a no-op with nothing said back to it.
#
# `compare` sits BEFORE the gates, not after. Its contract lets the step answer
# `fixed: true`, which means it edited the tree; placed after `self-check` that
# edit is never linted, typechecked or tested, and the change ships behind gates
# that ran on the code before it. A render run on a branch whose gates then go red
# is the cheaper mistake.
DRIVER_STEPS="${DRIVER_STEPS:-start plan build fix compare self-check review record ship}"

# Five tries, then park — the number in the approved design's flowchart.
DRIVER_MAX_BUILD_TRIES="${DRIVER_MAX_BUILD_TRIES:-5}"
DRIVER_MAX_REVIEW_ROUNDS="${DRIVER_MAX_REVIEW_ROUNDS:-2}"
# Red gates in the branch's own diff go back to fix this many times before a park.
DRIVER_MAX_GATE_FIXES="${DRIVER_MAX_GATE_FIXES:-3}"

DRIVER_CLAUDE="${DRIVER_CLAUDE:-claude}"

# Where a question about the ticket's shape parks: the PM's label, never the owner's
# hold. The project's labels.pmDecision, else status:pm-decision.
DRIVER_PM_LABEL="${DRIVER_PM_LABEL:-${LBL_PM_DECISION:-status:pm-decision}}"

# driver_link_install <repo> <tree> — the shared install, linked, never copied or
# installed. The tree gets its own node_modules of links to the shared entries, with
# the workspace packages pointed at the tree's own source; one link to the whole
# shared node_modules ran the shared checkout's stale packages instead
# (scripts/link-node-modules.sh says how). Its narration goes to stderr: callers
# sit inside command substitutions. 0 linked, or nothing to link · 1 it failed.
driver_link_install() {
  bash "$KIT_ROOT/scripts/link-node-modules.sh" "$1" "$2" >&2
}

# driver_refresh_install <repo> <tree> — machine setup before anything reads the tree's
# install: relinked only when the tree's lockfile or package.json files (or the shared
# clone's lockfile) moved since it was linked. A merge of the trunk brings new packages,
# and nothing else re-runs the linker. The shared clone itself is never relinked.
# 0 up to date, relinked, or nothing to do · 1 the relink failed.
driver_refresh_install() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -d "$2" ] || return 0
  [ "$1" -ef "$2" ] && return 0
  bash "$KIT_ROOT/scripts/link-node-modules.sh" --if-stale "$1" "$2" >&2
}

# driver_relink_if_behind <repo> <tree> — a tree whose install is missing a package its
# lockfile declares, or holds one at another version, is relinked to the shared install
# before anything reads it: the machine's setup, never the change's. Narration on stderr.
# 0 not behind, or relinked and no longer behind · 1 still behind (DRIVER_BEHIND_WHY says how).
driver_relink_if_behind() {
  DRIVER_BEHIND_WHY=""
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -d "$2" ] || return 0
  [ "$1" -ef "$2" ] && return 0
  local behind
  behind=$(bash "$KIT_ROOT/scripts/link-node-modules.sh" --behind "$2" 2>/dev/null) || return 0
  driver_say "   install: $behind — relinking it to the shared install before anything reads it (machine setup, not the change)" >&2
  driver_link_install "$1" "$2" || true
  if DRIVER_BEHIND_WHY=$(bash "$KIT_ROOT/scripts/link-node-modules.sh" --behind "$2" 2>/dev/null); then
    driver_say "   install: still behind after the relink — $DRIVER_BEHIND_WHY" >&2
    return 1
  fi
  DRIVER_BEHIND_WHY=""
  return 0
}

DRIVER_OK=0
DRIVER_E_QUESTION=20
DRIVER_E_NO_SKILL=21
DRIVER_E_SCHEMA=22
DRIVER_E_NO_BRIEF=23
DRIVER_E_REFUSED=24
DRIVER_E_TIMEOUT=25
# NOT THE TICKET'S FAULT, SO NEVER A PARK: a park is never retried.
DRIVER_E_UNREAD=26    # GitHub could not be read, after retries: nothing was decided
DRIVER_E_USAGE=27     # a model step hit the plan's usage limit
DRIVER_E_REQUEUE=28   # build-ticket's own exit: back on the queue, no label, no park
DRIVER_E_BUSY=29      # another run on this host holds the ticket's claim
DRIVER_E_REWORK=30
DRIVER_E_TO_REPAIR=31 # start found the ticket's open PR: this run becomes a repair of it
DRIVER_E_NOOP=32      # the step read the PR afresh and nothing is owed: the run ends clean, exit 0
DRIVER_E_MACHINE=33   # a model call failed with an API error, twice: the machine, never a question

# driver_gh_read <command…> — a GitHub read, tried DRIVER_LOOKUP_TRIES times with a
# growing pause. One failed read parked a ticket for good on 2026-10-18.
driver_gh_read() {
  local n=0 out
  while :; do
    n=$((n+1))
    if out=$("$@"); then printf '%s' "$out"; return 0; fi
    [ "$n" -lt "${DRIVER_LOOKUP_TRIES:-3}" ] || return 1
    sleep $(( ${DRIVER_LOOKUP_RETRY_SEC:-5} * n ))
  done
}

# driver_say <message…> — one line on stdout and one in the ticket's own log, so
# a run that scrolled past is still readable afterwards.
driver_say() {
  printf '%s\n' "$*"
  [ -n "${DRIVER_TICKET:-}" ] || return 0
  mkdir -p "$DRIVER_DIR/$DRIVER_TICKET" 2>/dev/null
  printf '%s %s\n' "$(swarm_stamp)" "$*" >> "$DRIVER_DIR/$DRIVER_TICKET/log"
}

driver_opt_early() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

# A step runs `claude -p` with no one to answer a permission prompt, so it needs a
# mode that lets the build step edit and commit — the claim spawner runs `auto`.
DRIVER_PERMISSION_MODE="${DRIVER_PERMISSION_MODE:-$(driver_opt_early driver.permissionMode auto)}"
# Tools no step calls, left out of every step's context: a headless step has no one
# to ask, plan with or notify, and schedules nothing. Space-separated; empty keeps
# every tool. Skill, the subagent tools, Bash and the file tools are never listed —
# the briefs depend on them.
DRIVER_DISALLOWED_TOOLS="${DRIVER_DISALLOWED_TOOLS-$(driver_opt_early driver.disallowedTools 'Workflow WebSearch NotebookEdit CronCreate CronDelete CronList Monitor ScheduleWakeup RemoteTrigger PushNotification EnterWorktree ExitWorktree EnterPlanMode ExitPlanMode AskUserQuestion')}"
# THE TOOLS A STEP LOADS, BY ALLOWLIST. Every tool schema is re-sent on every call of
# every step, and across the 27 transcripts of trial 3 (2026-09-30) the steps only
# ever called these eight — plus StructuredOutput, which --json-schema adds itself.
# Loading the rest cost ~14k tokens a call (60,028 → 46,227 measured, same prompt).
# A step may narrow it in briefs/facts.json (`steps.<step>.tools`); `driver.tools`
# sets the default; "default" loads Claude Code's whole set, as before (#11172).
DRIVER_TOOLS="${DRIVER_TOOLS-$(driver_opt_early driver.tools 'Bash Read Edit Write Grep Glob Skill Agent')}"
# THE PROJECT'S INSTRUCTION FILES ARE READ ON DEMAND, NOT PRELOADED. Auto-loaded,
# the origin project's CLAUDE.md + AGENTS.md were ~17k tokens on every call of every step; the
# brief already carries the project's facts. "preload" restores the old behaviour.
DRIVER_PROJECT_INSTRUCTIONS="${DRIVER_PROJECT_INSTRUCTIONS-$(driver_opt_early driver.projectInstructions on-demand)}"

# driver_bounded <seconds> <command> — run a command with a ceiling on its life.
#
# NOTHING ELSE BOUNDS A STEP THAT NEVER RETURNS. The orchestrator bounds a step that
# keeps saying "go back", and the build step bounds its own retries, but a command that
# hangs is outside both: no park, no refusal, the claim held and the worktree pinned —
# the one state the whole design exists to make impossible. And the build step's command
# comes from the MODEL, so a reported watch-mode runner (`vitest` without `run`,
# `jest --watch`, a dev server) hangs the run for ever on an answer that looks perfectly
# reasonable.
#
# Returns 124 on a timeout, which is the conventional code and is what a caller names
# its refusal from. A command that genuinely exits 124 is indistinguishable; that is the
# cost of having a bound at all.
#
# IT KILLS THE PROCESS GROUP, not just the command. `exec` plus a bare alarm terminates
# the shell and orphans its children, so a watch-mode runner carries on inside the ticket
# worktree after the bound has "held" — and the worktree is then removed from under a
# live process. The child gets its own group and the group is signalled.
#
# `timeout` is GNU coreutils and is not on a stock mac, so perl is the portable one.
# Neither available: run it unbounded and SAY SO, because a bound nobody applied must not
# read like one that held.
DRIVER_CMD_TIMEOUT="${DRIVER_CMD_TIMEOUT:-$(driver_opt_early cmdTimeout 900)}"

# driver_warn_unbounded — say ONCE, through the ticket's own log, that the configured
# time limit is not a number and therefore bounds nothing. driver_bounded also warns, but
# a caller that redirects the command's output (self-check writes each gate to a file)
# captures that warning into the file nobody is reading yet. This one goes where the
# operator is looking.
driver_check_timeout() {
  case "${DRIVER_CMD_TIMEOUT:-}" in
    ''|*[!0-9]*|0)
      driver_say "⚠ the configured time limit is '${DRIVER_CMD_TIMEOUT:-}', which is not a number of seconds, so commands run UNBOUNDED — set cmdTimeout to a whole number."
      return 1 ;;
  esac
  return 0
}

driver_bounded() { # <seconds> <command>
  local secs cmd rc
  # One name per line. bash expands the whole `local` command before assigning any of
  # it, so `local secs="${1:-$X}" cmd="$2"` with $2 unset aborts on the SECOND word
  # under `set -u` before the first default is ever applied.
  secs="${1:-}"
  cmd="${2:-}"
  # BASH, NOT /bin/sh. Agents write commands in bash; on Linux /bin/sh is dash, which
  # rejects arrays, [[ ]] and process substitution, and a refused command read as a
  # failing test sent builds round the rework loop. DRIVER_SHELL overrides.
  local DRIVER_SHELL="${DRIVER_SHELL:-$(command -v bash || echo /bin/sh)}"
  [ -n "$secs" ] || secs="$DRIVER_CMD_TIMEOUT"
  # A NON-NUMBER IS NOT A CEILING. perl reads `alarm "15m"` as `alarm 0`, which CANCELS
  # the alarm — so an operator writing "15m" or "900s" in the config silently removes
  # every bound in the driver. Refuse to pretend: run it, and say the bound is not there.
  case "$secs" in
    ''|*[!0-9]*|0)
      echo "driver: '$secs' is not a number of seconds, so '$cmd' runs UNBOUNDED — set cmdTimeout to a whole number of seconds." >&2
      "$DRIVER_SHELL" -c "$cmd"; return $? ;;
  esac
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift; my @cmd = @ARGV;
      my $pid = fork;
      if (!defined $pid) { exit 127 }
      if ($pid == 0) { setpgrp(0, 0); exec @cmd; exit 127 }
      $SIG{ALRM} = sub { kill("TERM", -$pid); sleep 1; kill("KILL", -$pid); exit 124 };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      alarm 0;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$DRIVER_SHELL" -c "$cmd"
    rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$DRIVER_SHELL" -c "$cmd"; rc=$?
  else
    echo "driver: neither perl nor timeout is available, so '$cmd' runs UNBOUNDED" >&2
    "$DRIVER_SHELL" -c "$cmd"; rc=$?
  fi
  return "$rc"
}

# driver_run_project <seconds> <command> — one of the PROJECT's own commands (a gate,
# a test, a typecheck), bounded, and run as CI runs it: without the kit's HARNESS_*
# pins. A launcher exports HARNESS_CFG_PATH so the kit reads the right config; a
# project test that builds its own fixture config reads that same variable first and
# fails on a change that is fine.
driver_run_project() { # <seconds> <command>
  (
    for _v in $(env | sed -n 's/^\(HARNESS_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
    unset _v
    driver_bounded "$@"
  )
}

# driver_prepare_worktree <tree> — this project's per-checkout setup, in a freshly
# created tree. Sets DRIVER_PREPARE_WHY and returns 1 when a command fails.
#
# A linked node_modules and a copy of the hook shims are not the whole of what a
# worktree needs. Measured on the 2026-09-27 trial, every push from a driver
# worktree was refused:
#
#   ✗ pre-push blocked: the prompt-template hash does not describe the prompt sources.
#       Error: Cannot find module '@/generated/prisma/client'
#
# The generated database client is gitignored and per-checkout, so a fresh worktree
# has none and every hook importing it dies. The kit cannot know what a project
# generates, so the project says: `worktree.prepare` in harness.json, a list of
# commands. Absent is normal and skipped.
#
# It runs in the START step's tree AND in the build step's two proof trees. A test
# command resolving through a generated artifact exits 127 in both halves of the
# red/green proof, and 127 in the second half reads as "the change does not do the
# job" — so the ticket parks blaming a change that works.
DRIVER_PREPARE_WHY=""
# driver_signoff_refusal <ticket> <output> — 0, with the owner's park note set, when
# the sign-off guard refused: the owner signed these screens and the change moves them.
driver_signoff_refusal() {
  grep -q 'sign-off comes last' "$2" 2>/dev/null || return 1
  driver_state_set "$1" park_note "Needs the owner: this PR's screens were signed off and this build changes them after that ($(driver_signoff_line "$2")). Either the change becomes a follow-up ticket, or it is a fix the PR cannot merge without and its commit says pixel-change-after-signoff: <why>, which puts the hold back on for the owner to sign again."
}
driver_signoff_line() { grep -m1 'sign-off comes last' "$1" 2>/dev/null | sed 's/^[^A-Za-z]*pre-push blocked: //' | cut -c1-300; }

# driver_push <ticket> <tree> <branch> <slot> — push the branch, keeping what the
# project's pre-push said. A refused push used to be `>/dev/null 2>&1`: the park
# said "read its own output" and that output existed nowhere, so the one line that
# named the failing check had to be got by re-running the push by hand (#10955,
# trial 3). The whole output goes to steps/<slot>-push.out; DRIVER_PUSH_WHY is the
# lines that say no (✗, error:, fatal:), joined, for the log and the park note.
#
# THE PARK ESCAPE. A park's push of a draft branch carries `<name>=1` (PARK_PUSH by
# default, `driver.parkPushEnv` to rename it), which a project's pre-push may honour
# by skipping the quality gates work-in-progress fails by definition. Without it a
# red check refused every park push and the work stayed in a local bundle — seven
# times on 2026-10-17. Every other slot, and a park of a trunk, strips it: inherited
# from the shell, it would wave a ship past the gates it exists to pass.
driver_push() {
  local t="$1" wt="$2" branch="$3" slot="$4" f rc=0 esc tr
  f="$(driver_state_dir "$t")/steps/$slot-push.out"
  mkdir -p "$(dirname "$f")"
  local penv=(env -u PARK_PUSH)
  esc=$(driver_opt driver.parkPushEnv PARK_PUSH)
  if [[ "$esc" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    penv+=(-u "$esc")
    if [ "$slot" = park ]; then
      for tr in $(driver_opt trunks "$INTEGRATION_BRANCH"); do [ "$tr" = "$branch" ] && esc=""; done
      [ -n "$esc" ] && penv+=("$esc=1")
    fi
  elif [ "$slot" = park ]; then
    driver_say "   park: driver.parkPushEnv '$esc' is not an environment variable name, so the push carries no park escape"
  fi
  "${penv[@]}" git -C "$wt" push -u origin "refs/heads/$branch:refs/heads/$branch" > "$f" 2>&1 || rc=$?
  DRIVER_PUSH_OUT="$f"
  DRIVER_PUSH_WHY=""
  [ "$rc" -ne 0 ] || driver_state_set "$t" pushed_head "$(git -C "$wt" rev-parse HEAD 2>/dev/null)"
  if [ "$rc" -ne 0 ]; then
    DRIVER_PUSH_WHY=$(grep -E '✗|^error:|^fatal:|^remote: error' "$f" 2>/dev/null | sed 's/^[[:space:]]*//' | head -5 | tr '\n' ' ' | cut -c1-400)
    [ -n "$DRIVER_PUSH_WHY" ] || DRIVER_PUSH_WHY=$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -3 | tr '\n' ' ' | cut -c1-400)
    [ -n "$DRIVER_PUSH_WHY" ] || DRIVER_PUSH_WHY="the push exited $rc and printed nothing"
  fi
  return "$rc"
}

# driver_take_origin <ticket> <tree> <branch> [trunk] — bring in what origin's copy of
# the ticket's OWN branch has and this tree lacks, before a push. An earlier run of
# the same ticket that pushed first made every later push "rejected (fetch first)",
# and the park left the ticket ready to hit it again (measured 2026-10-20: 2 commits
# on origin, 12 newer here). Merged, never rebased or forced. On a conflict this
# run's version wins for a file its own commits changed; any other conflicted file
# aborts the merge and is named in DRIVER_TAKE_WHY (return 1). DRIVER_TAKE_MERGED=1
# when the merge changed the tree, so the caller re-runs the gates on it.
driver_take_origin() {
  local t="$1" wt="$2" branch="$3" trunk="${4:-}" ob lrc=0 before n mine conflicted f rest="" out="" msg
  DRIVER_TAKE_MERGED=0; DRIVER_TAKE_WHY=""; DRIVER_TAKE_COUNT=0
  ob="refs/remotes/origin/$branch"
  git -C "$wt" ls-remote --exit-code -q origin "refs/heads/$branch" >/dev/null 2>&1 || lrc=$?
  [ "$lrc" -ne 2 ] || return 0
  if [ "$lrc" -ne 0 ] || ! out=$(git -C "$wt" fetch -q origin "+refs/heads/$branch:$ob" 2>&1); then
    driver_say "   could not fetch origin's $branch (the push will say why if it matters): $(printf '%s' "$out" | tail -1 | cut -c1-200)"
    return 0
  fi
  n=$(git -C "$wt" rev-list --count "HEAD..$ob" 2>/dev/null)
  case "$n" in ''|*[!0-9]*)
    DRIVER_TAKE_WHY="could not count origin's $branch against this tree"; return 1 ;; esac
  [ "$n" -gt 0 ] || return 0
  DRIVER_TAKE_COUNT="$n"
  before=$(git -C "$wt" rev-parse 'HEAD^{tree}')
  if [ -n "$trunk" ] && git -C "$wt" rev-parse --verify -q "$trunk" >/dev/null 2>&1; then
    mine=$(git -C "$wt" log --no-merges --format= --name-only HEAD --not "$ob" "$trunk" 2>/dev/null | sort -u)
  else
    mine=$(git -C "$wt" log --no-merges --format= --name-only HEAD --not "$ob" 2>/dev/null | sort -u)
  fi
  msg="chore(merge): take the earlier run's commits on this ticket's branch (#$t)"
  if git -C "$wt" merge -q --no-ff --no-verify -m "$msg" "$ob" >/dev/null 2>&1; then
    [ "$(git -C "$wt" rev-parse 'HEAD^{tree}')" = "$before" ] || DRIVER_TAKE_MERGED=1
    return 0
  fi
  conflicted=$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)
  if [ -z "$conflicted" ]; then
    git -C "$wt" merge --abort >/dev/null 2>&1
    DRIVER_TAKE_WHY="merging origin's $branch failed with no conflicted file to name"; return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$mine" | grep -qxF -- "$f" || rest="$rest$f "
  done <<< "$conflicted"
  if [ -n "$rest" ]; then
    git -C "$wt" merge --abort >/dev/null 2>&1
    DRIVER_TAKE_WHY="${rest% }"; return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if git -C "$wt" cat-file -e "HEAD:$f" 2>/dev/null; then
      git -C "$wt" checkout -q --ours -- "$f" && git -C "$wt" add -- "$f"
    else
      git -C "$wt" rm -q --cached --ignore-unmatch -- "$f" >/dev/null 2>&1; rm -f -- "$wt/$f"
    fi
  done <<< "$conflicted"
  if [ -n "$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)" ] \
     || ! git -C "$wt" commit -q --no-verify -m "$msg" >/dev/null 2>&1; then
    git -C "$wt" merge --abort >/dev/null 2>&1
    DRIVER_TAKE_WHY="the conflicts in $(printf '%s' "$conflicted" | tr '\n' ' ')could not be settled for this run's side"; return 1
  fi
  [ "$(git -C "$wt" rev-parse 'HEAD^{tree}')" = "$before" ] || DRIVER_TAKE_MERGED=1
  return 0
}

# driver_step_tools <step> — the allowlist for one step: briefs/facts.json's
# `steps.<step>.tools` when it names one, else DRIVER_TOOLS.
driver_step_tools() {
  local f="${DRIVER_BRIEFS:-}/facts.json" v=""
  [ -n "${1:-}" ] && [ -f "$f" ] && v=$(jq -r --arg s "$1" '.steps[$s].tools // empty | if type == "array" then join(" ") else . end' "$f" 2>/dev/null)
  # A reviewer judges; it does not edit. Its own frontmatter narrows this too, but
  # the driver does not lean on a file it does not own.
  [ -z "$v" ] && [ "${1:-}" = "attest" ] && v="Read Bash Grep Glob"
  printf '%s' "${v:-$DRIVER_TOOLS}"
}

# driver_bounded_argv <seconds> <stdin-file> <command> [args...] — driver_bounded
# for a command that is an ARGUMENT LIST, never a string: no shell re-parses it, so
# no quoting can break on a path, a locale or a byte (review of #11172: `printf %q`
# emits $'...', which dash passes through as a literal).
driver_bounded_argv() {
  local secs="${1:-}" in="${2:-/dev/null}"; shift 2
  case "$secs" in ''|*[!0-9]*|0) "$@" < "$in"; return $? ;; esac
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift; my @cmd = @ARGV;
      my $pid = fork;
      if (!defined $pid) { exit 127 }
      if ($pid == 0) { setpgrp(0, 0); exec @cmd; exit 127 }
      $SIG{ALRM} = sub { kill("TERM", -$pid); sleep 1; kill("KILL", -$pid); exit 124 };
      alarm $secs;
      waitpid($pid, 0);
      my $st = $?;
      alarm 0;
      exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
    ' "$secs" "$@" < "$in"
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" < "$in"
  else
    "$@" < "$in"
  fi
}

# driver_lean_args <tree> [step] — fills the array DRIVER_LEAN_ARGS with what every
# model call the driver makes carries: no connectors, only the tools the step uses,
# and — unless the project asks for "preload" — the tree's CLAUDE.md / AGENTS.md
# excluded BY PATH (`claudeMdExcludes`), named in the system prompt instead.
# By path and nothing wider: every setting source still loads, so the project's own
# skills, agents, hooks and local settings reach the step exactly as before.
# (`--setting-sources user` also left CLAUDE.md out, and silently took the
# project's 32 skills and its agents with it — review of #11172.)
driver_lean_args() {
  local wt="${1:-}" step="${2:-}" tools f files="" excl=""
  local -a list
  DRIVER_LEAN_ARGS=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')
  # Off unless a spawner sets it: a runaway stop per step, never a measurement.
  [ -z "${DRIVER_STEP_BUDGET_USD:-}" ] || DRIVER_LEAN_ARGS+=(--max-budget-usd "$DRIVER_STEP_BUDGET_USD")
  tools=$(driver_step_tools "$step")
  if [ -n "$tools" ] && [ "$tools" != "default" ]; then
    read -r -a list <<<"$tools"
    DRIVER_LEAN_ARGS+=(--tools "${list[@]}")
  elif [ -n "$DRIVER_DISALLOWED_TOOLS" ]; then
    read -r -a list <<<"$DRIVER_DISALLOWED_TOOLS"
    DRIVER_LEAN_ARGS+=(--disallowed-tools "${list[@]}")
  fi
  [ "$DRIVER_PROJECT_INSTRUCTIONS" = "preload" ] && return 0
  [ -n "$wt" ] || return 0
  for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md; do
    [ -f "$wt/$f" ] || continue
    files="$files${files:+, }$f"
    excl="$excl${excl:+,}$(jq -Rn --arg p "$wt/$f" '$p')"
  done
  [ -n "$files" ] || return 0
  DRIVER_LEAN_ARGS+=(--settings "{\"claudeMdExcludes\":[$excl]}")
  DRIVER_LEAN_ARGS+=(--append-system-prompt "This project's instruction files are not preloaded, to keep every call small: $files, at the root of the tree you are working in. Before you change code, read the parts of them that bear on the change. You do not need them to answer from what you were given.")
}

# driver_ensure_hooks <repo> <tree> — the tree runs its own .husky hooks, or this
# fails. Without it git finds no hook and pushes unchecked. A tree with no .husky/
# keeps whatever hooks setup it has (the script says so and exits 0).
driver_ensure_hooks() {
  # From the tree itself: the run's own directory can be gone, and git refuses to start there.
  ( cd "$2" 2>/dev/null || cd /; bash "${DRIVER_ENSURE_HOOKS:-$KIT_ROOT/scripts/ensure-hooks.sh}" "$1" "$2" ) >&2 || {
    driver_say "✋ git hooks could not be set up in $2 — the reason is printed above."
    return 1
  }
}

driver_prepare_worktree() { # <tree>
  local tree="${1:?driver_prepare_worktree: need a tree}" ptype n i cmd out rc
  DRIVER_PREPARE_WHY=""
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  # THE SHAPE FIRST, because `length` answers for a string and an object too. Written
  # as a bare string — `"prepare": "npx prisma generate"` — `// []` does not fire (a
  # string is truthy), length is the CHARACTER COUNT, every per-element read errors
  # into /dev/null, and this returned 0 having prepared nothing. Measured: 19 for a
  # 19-character string. That is the defect self-check.sh refuses one file over, and
  # its consequence here is worse: an unprepared tree that reports as prepared fails
  # at the push, or 127s in both halves of the build step's proof.
  ptype=$(jq -r '(.worktree.prepare // null) | type' "$HARNESS_CFG" 2>/dev/null)
  case "$ptype" in
    null)  return 0 ;;
    array) : ;;
    # An EMPTY type is jq failing, not a shape: an unparseable harness.json, or a
    # `worktree` that is itself a string. Given the shape arm's wording it printed
    # "is a  and this reads a list", which tells the operator nothing about which.
    '')    DRIVER_PREPARE_WHY="harness.json could not be read for worktree.prepare ($HARNESS_CFG), so NOTHING was prepared in $tree"
           driver_say "✋ $DRIVER_PREPARE_WHY. Nothing having run is not everything having passed."
           return 1 ;;
    *)     DRIVER_PREPARE_WHY="harness.json's worktree.prepare is a $ptype and this reads a list of commands, so NOTHING was prepared in $tree"
           driver_say "✋ $DRIVER_PREPARE_WHY. Nothing having run is not everything having passed."
           return 1 ;;
  esac
  n=$(jq -r '.worktree.prepare | length' "$HARNESS_CFG" 2>/dev/null)
  case "${n:-0}" in ''|*[!0-9]*|0) return 0 ;; esac
  i=0
  while [ "$i" -lt "$n" ]; do
    cmd=$(jq -r --argjson i "$i" '.worktree.prepare[$i] | if type == "string" then . else "" end' "$HARNESS_CFG" 2>/dev/null)
    i=$((i+1))
    # An element that is not a command is NAMED, never skipped in silence — a list
    # entry nobody ran and nobody mentioned is the same failure one shape up.
    if [ -z "$cmd" ] || [ "$cmd" = "null" ]; then
      DRIVER_PREPARE_WHY="harness.json's worktree.prepare entry $i of $n (counting from 1) is not a command, so it did not run in $tree"
      driver_say "✋ $DRIVER_PREPARE_WHY"
      return 1
    fi
    out=$( ( cd "$tree" && driver_bounded "$DRIVER_CMD_TIMEOUT" "$cmd" ) 2>&1 ); rc=$?
    if [ "$rc" -ne 0 ]; then
      DRIVER_PREPARE_WHY="harness.json's worktree.prepare command '$cmd' exited $rc in $tree: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
      driver_say "✋ the worktree could not be prepared — $DRIVER_PREPARE_WHY. An unprepared tree cannot pass this project's pre-push, and finding that out at the push is finding it out after the build."
      return 1
    fi
    driver_say "   prepared $tree with '$cmd'"
  done
  return 0
}

# driver_worktree_root — where this project keeps its ticket worktrees.
#
# NOT $TMPDIR. On macOS that is a per-user folder under /var/folders that the
# system prunes, and a driver run's tree is the only copy of the work between the
# build and the push — the 2026-09-28 trial ended with 9 commits in one. The
# project says where with `worktreeRoot`; a project that names none gets the same
# default /agent-harness:claim uses (toolkit_worktree_root: ~/.harness-worktrees/<repo>),
# never the temp dir. A configured root is honoured as given.
driver_worktree_root() {
  local r; r=$(driver_opt worktreeRoot "")
  case "$r" in
    '~')   r="$HOME" ;;
    '~/'*) r="$HOME/${r#\~/}" ;;
  esac
  [ -n "$r" ] || r=$(toolkit_worktree_root) || return 1
  printf '%s' "${r%/}"
}

# driver_scratch_paths — the paths a step's own tooling writes into the ticket
# worktree that are NOT the change. `superpowers:writing-plans` writes its working
# plan to docs/superpowers/plans/, and on the 2026-09-28 trial the park swept a
# 1,361-line plan file into the parked commit and created docs/superpowers on a
# branch of a repo that has no such directory. A project may name more under
# `worktree.scratch`.
driver_scratch_paths() {
  printf '%s\n' docs/superpowers
  [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ] || return 0
  jq -r '(.worktree.scratch // []) | .[] | select(type == "string")' "$HARNESS_CFG" 2>/dev/null
}

# driver_sweep_scratch <ticket> <tree> — move that tooling's leavings OUT of the
# worktree and into the run record, so neither `git add -A` nor the ship step's
# clean-tree check ever sees them.
#
# MOVED, NOT DELETED. The plan is the step's own reasoning and a person reading a
# park wants it; it just does not belong in the product's history. It lands under
# the ticket's state directory beside the transcripts.
#
# A TRACKED PATH IS NEVER TOUCHED. If the project genuinely keeps files there, the
# sweep would be deleting the change — so anything git knows about is left alone
# and said.
driver_sweep_scratch() { # <ticket> <tree>
  local t="${1:-}" tree="${2:-}" p dest moved=""
  [ -n "$tree" ] && [ -d "$tree" ] || return 0
  command -v driver_state_dir >/dev/null 2>&1 || return 0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -e "$tree/$p" ] || continue
    if [ -n "$(git -C "$tree" ls-files -- "$p" 2>/dev/null | head -1)" ]; then
      driver_say "   the worktree's '$p' is tracked here, so it is the change and was left alone."
      continue
    fi
    # ITS OWN DESTINATION EVERY TIME. A fixed one made the SECOND sweep delete the
    # FIRST step's plan, which is "moved, not deleted" doing exactly the deleting
    # this function says it does not.
    dest="$(driver_state_dir "$t")/scratch/$(date +%Y%m%d-%H%M%S)-$$/$p"
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    mv "$tree/$p" "$dest" 2>/dev/null && moved="$moved $p"
  done <<EOS
$(driver_scratch_paths)
EOS
  [ -z "$moved" ] || driver_say "   kept out of the change:${moved} — moved to $(driver_state_dir "$t")/scratch"
  return 0
}

# driver_opt <dotted.key> <default> — an OPTIONAL project fact. toolkit_cfg
# refuses a missing key by name, which is right for a fact the kit cannot invent;
# these are tuning the kit can default without naming anyone's project.
driver_opt() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

# driver_evidence_plan <ticket> — the capture plan's path in the tree, where CI reads it:
# <evidence.dir>/<key>/plan.json, the key by CI's own rule (scripts/evidence-plan.sh). Ship,
# repair and the facts all ask here; a path built from the ticket alone missed CI on every
# branch not named <prefix>NNNN/… (four PRs, 2026-10-20).
. "$KIT_ROOT/scripts/evidence-plan.sh"
driver_evidence_plan() { # <ticket>
  local t="$1" b pr k wt
  b=$(driver_state_get "$t" branch)
  if [ -z "$b" ]; then wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] && b=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null); fi
  pr=$(driver_state_get "$t" pr); [ -n "$pr" ] || pr=$(driver_state_get "$t" critic_pr)
  k=$(evidence_plan_key "$b" "$pr")
  if [ -z "$k" ] && [ -n "$b" ]; then
    pr=$(swarm_gh pr list --repo "$REPO_SLUG" --head "$b" --state open --json number -q '.[0].number // empty' 2>/dev/null)
    k=$(evidence_plan_key "$b" "$pr")
  fi
  # No PR yet on an unconventional branch: CI has no key either until one opens.
  printf '%s/%s/plan.json' "$(driver_opt evidence.dir "docs/evidence")" "${k:-$t}"
}

# The preface every caller's brief is handed under. Briefs are written for the prose
# flow and say "push, keep auto-merge armed, hand off"; inside the driver those are
# the driver's alone, done after the review. ai-step.sh also enforces it.
DRIVER_BRIEF_PREFACE="The driver alone pushes, marks the pull request ready, arms auto-merge and hands off — after its own gates and review. Any instruction in this brief to push, re-arm auto-merge, mark ready or hand off is void: do not do it; commit, and leave the rest to the driver."

# driver_conflict_markers <tree> <trunk> — the files this branch ADDS a conflict
# marker line to, against the trunk, one per line. Read from the branch's own diff,
# so it holds on every pass whatever the record says: a marker committed by an
# interrupted pass is still a marker. `<<<<<<<` and `>>>>>>>` only — a bare `=======`
# is also a Markdown underline.
driver_conflict_markers() {
  git -C "$1" diff -U0 "$2"...HEAD 2>/dev/null | awk '
    /^\+\+\+ b\// { f = substr($0, 7); next }
    /^\+(<<<<<<<|>>>>>>>)( |$)/ { if (f != "" && !(f in seen)) { seen[f] = 1; print f } }'
}

. "$KIT_ROOT/scripts/pr-closes.sh"
# A throwaway, migrated database for a proof or a step, when tests.db is configured.
. "$DRIVER_HOME/test-db.sh"

# driver_open_prs_for <ticket> — the open pull requests that are this ticket's, one
# per line. A PR is the ticket's by ANY of: a head branch <prefix><ticket> or
# <ticket>/ (a person's or /claim's branch carries no prefix), GitHub's closing
# references, or a Closes/Fixes/Resolves #<ticket> in its body (GitHub links none
# on a PR into a non-default base):
#   number \t headRefName \t headRefOid \t mergeStateStatus \t isDraft \t mergeable
# Returns 1 when GitHub could not be asked: an unreadable list is not "none", and
# read as none it lets start cut a second branch beside a PR that exists.
# Read from the shared copy (gh_open_prs) while it is DRIVER_PRS_MAX_AGE seconds old.
driver_open_prs_for() {
  local t="${1:?driver_open_prs_for: need a ticket}" j
  j=$(driver_open_prs) || return 1
  printf '%s' "$j" | jq -r --arg pre "$BRANCH_PREFIX" --arg t "$t" --arg kw "$PR_CLOSES_JQ" '
    .[] | select((.headRefName | test("^" + $pre + $t + "([^0-9]|$)") or test("^" + $t + "/"))
                 or ([.closingIssuesReferences[]?.number | tostring] | index($t) != null)
                 or ((.body // "") | test($kw + $t + "([^0-9]|$)"; "i")))
    | [.number, .headRefName, (.headRefOid // ""), (.mergeStateStatus // ""), (.isDraft // false), (.mergeable // "")] | @tsv'
}

# driver_claim_dead_here <ticket> — 0 when the claim was taken on this host by a
# process that is gone: a dead run's claim, which nothing else will ever release.
driver_claim_dead_here() {
  local c host pid
  type claim_pid_alive >/dev/null 2>&1 || . "$KIT_ROOT/scripts/claim-proc.sh" || return 1
  c=$(bash "$CL" show "$1" 2>/dev/null) || return 1
  host=$(printf '%s' "$c" | jq -r '.host // ""' 2>/dev/null); pid=$(printf '%s' "$c" | jq -r '.pid // ""' 2>/dev/null)
  [ -n "$host" ] && [ "$host" = "$(claim_host 2>/dev/null)" ] || return 1
  case "$pid" in ''|null|*[!0-9]*) return 1 ;; esac
  ! claim_pid_alive "$pid"
}

# driver_open_prs_for_patient <ticket> — driver_open_prs_for, asked DRIVER_LOOKUP_TRIES
# (3) times DRIVER_LOOKUP_RETRY_SEC (5) apart: a GitHub timeout is usually gone by then.
driver_open_prs_for_patient() {
  local n=0 out
  until out=$(driver_open_prs_for "$1"); do
    n=$((n+1)); [ "$n" -lt "${DRIVER_LOOKUP_TRIES:-3}" ] || return 1
    sleep "${DRIVER_LOOKUP_RETRY_SEC:-5}"
  done
  printf '%s' "$out"; [ -z "$out" ] || printf '\n'
}

# driver_open_prs — every open pull request as a JSON array, from the shared copy.
driver_open_prs() {
  local j
  j=$(gh_open_prs "${DRIVER_PRS_MAX_AGE:-60}" 2>/dev/null) || return 1
  printf '%s' "$j" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  printf '%s\n' "$j"
}

# driver_brief_note <brief-file> — the brief as a queue note, without the coordinator's
# own "Coordinator note (<class>): " wrapper, which the next spawn adds again.
driver_brief_note() { sed '1s/^Coordinator note ([a-z-]*): //' "$1"; }

# driver_record_diverged <ticket> <open-pr row> — why the record is not this PR's,
# or nothing when it is: the same branch, still a draft, and the PR's head inside the
# record's work (its tree's head, else the head it last pushed, when it has either).
driver_record_diverged() {
  local t="$1" pb ph pd rb wt rh where
  IFS=$'\t' read -r _ pb ph _ pd _ <<<"$2"
  rb=$(driver_state_get "$t" branch); wt=$(driver_state_get "$t" worktree)
  if [ -n "$rb" ] && [ "$rb" != "$pb" ]; then printf 'the record is on %s and the PR on %s' "$rb" "$pb"; return; fi
  if [ "$pd" != true ]; then printf 'the PR is ready, and a build the driver left unshipped leaves a draft'; return; fi
  where="$MAIN_REPO"; rh=""
  if [ -n "$wt" ] && [ -d "$wt" ]; then where="$wt"; rh=$(git -C "$wt" rev-parse HEAD 2>/dev/null); fi
  [ -n "$rh" ] || rh=$(driver_state_get "$t" pushed_head)
  # No tree and no pushed head on the record: the head cannot be held against it.
  [ -z "$rh" ] || [ -z "$ph" ] || [ "$ph" = "$rh" ] && return 0
  git -C "$where" cat-file -e "$ph^{commit}" 2>/dev/null \
    || git -C "$where" fetch -q origin "+refs/heads/$pb:refs/remotes/origin/$pb" 2>/dev/null || true
  git -C "$where" merge-base --is-ancestor "$ph" "$rh" 2>/dev/null \
    || printf 'the PR head %s is not in the record'"'"'s work (%s): it moved since' "$(printf '%s' "$ph" | cut -c1-8)" "$(printf '%s' "$rh" | cut -c1-8)"
}

# driver_built <ticket> — 0 when this ticket's record holds a build the driver ran.
# Only a build runs `start`; a repair round reopens its own steps and never that one.
driver_built() {
  jq -e '(.done // []) | index("start") != null' "$DRIVER_DIR/$1/state.json" >/dev/null 2>&1
}

# THE GRADE SCALE, and the one place it is named. Every reviewer and every agent
# that files work grades what it raises, and the grade — not the list it arrived
# in — decides the effect: a Critical, a Major or a Minor sends work back and is
# fixed in the change that caused it; a Nit is dropped. Two representations of the
# same judgement is how a check and the thing it checks end up derived from
# different inputs.
DRIVER_GRADES="${DRIVER_GRADES:-critical major minor nit}"

# WHAT BLOCKS, named once, and by review round (the owner, 2026-10-20). Round 1 fixes
# Critical, Major and Minor; from round 2 only Critical and Major block, and a Minor
# goes on its screen's polish list for the next change there. A Minor filed as its own
# follow-up made every merge open new tickets (110 of 339 bugs in one week); a Minor
# that blocked every round made 4-5 hour loops (86 of 117 latest findings were Minor).
DRIVER_BLOCKING_GRADES="${DRIVER_BLOCKING_GRADES:-critical major minor}"
DRIVER_BLOCKING_GRADES_LATER="${DRIVER_BLOCKING_GRADES_LATER:-critical major}"

# driver_blocking_grades [round] — the grades that block in that review round; no
# round, or round 1, is the first round's set.
driver_blocking_grades() {
  case "${1:-1}" in ''|*[!0-9]*|0|1) printf '%s' "$DRIVER_BLOCKING_GRADES" ;; *) printf '%s' "${DRIVER_BLOCKING_GRADES_LATER:-$DRIVER_BLOCKING_GRADES}" ;; esac
}

# driver_blocking_select [round] — the jq selector for a finding whose grade blocks in
# that round. Every step reads this; a literal copy is refused by
# tests/blocking-grades.test.sh.
driver_blocking_select() {
  printf 'select((.grade // "") as $g | ("%s" | split(" ")) | index($g) != null)' "$(driver_blocking_grades "${1:-1}")"
}

# The priority a filed follow-up carries, read off the grade, so the queue orders
# by the same judgement the reviewer made. P0-P3 is the kit's own vocabulary (the
# same labels /queue, /work and /project already sort on); a project that names
# them differently says so under labels.priority. A Nit is never filed, so it has
# no label here; the Minor label stays for work filed outside a review.
DRIVER_LABEL_CRITICAL="${DRIVER_LABEL_CRITICAL:-$(driver_opt labels.priority.critical P0)}"
DRIVER_LABEL_MAJOR="${DRIVER_LABEL_MAJOR:-$(driver_opt labels.priority.major P1)}"
DRIVER_LABEL_MINOR="${DRIVER_LABEL_MINOR:-$(driver_opt labels.priority.minor P3)}"

export DRIVER_HOME DRIVER_DIR DRIVER_BRIEFS DRIVER_SCHEMAS DRIVER_VALIDATE DRIVER_STEPS
export DRIVER_MAX_BUILD_TRIES DRIVER_MAX_REVIEW_ROUNDS DRIVER_MAX_GATE_FIXES DRIVER_CLAUDE DRIVER_CMD_TIMEOUT
export DRIVER_GRADES DRIVER_BLOCKING_GRADES DRIVER_BLOCKING_GRADES_LATER DRIVER_LABEL_CRITICAL DRIVER_LABEL_MAJOR DRIVER_LABEL_MINOR
export DRIVER_PREPARE_WHY
export DRIVER_OK DRIVER_E_QUESTION DRIVER_E_NO_SKILL DRIVER_E_SCHEMA
export DRIVER_E_NO_BRIEF DRIVER_E_REFUSED DRIVER_E_TIMEOUT DRIVER_E_UNREAD DRIVER_E_USAGE DRIVER_E_REQUEUE DRIVER_E_BUSY DRIVER_E_REWORK DRIVER_E_TO_REPAIR DRIVER_E_NOOP DRIVER_E_MACHINE
