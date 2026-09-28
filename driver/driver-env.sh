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
# order on every pass and is a no-op with nothing said back to it. `compare` sits
# after the gates, so a red gate costs no render run.
DRIVER_STEPS="${DRIVER_STEPS:-start plan build fix self-check compare review record ship}"

# Five tries, then park — the number in the approved design's flowchart.
DRIVER_MAX_BUILD_TRIES="${DRIVER_MAX_BUILD_TRIES:-5}"
DRIVER_MAX_REVIEW_ROUNDS="${DRIVER_MAX_REVIEW_ROUNDS:-2}"

DRIVER_CLAUDE="${DRIVER_CLAUDE:-claude}"

DRIVER_OK=0
DRIVER_E_QUESTION=20
DRIVER_E_NO_SKILL=21
DRIVER_E_SCHEMA=22
DRIVER_E_NO_BRIEF=23
DRIVER_E_REFUSED=24
DRIVER_E_TIMEOUT=25
DRIVER_E_REWORK=30

# driver_say <message…> — one line on stdout and one in the ticket's own log, so
# a run that scrolled past is still readable afterwards.
driver_say() {
  printf '%s\n' "$*"
  [ -n "${DRIVER_TICKET:-}" ] || return 0
  mkdir -p "$DRIVER_DIR/$DRIVER_TICKET" 2>/dev/null
  printf '%s %s\n' "$(swarm_stamp)" "$*" >> "$DRIVER_DIR/$DRIVER_TICKET/log"
}

driver_opt_early() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

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
  [ -n "$secs" ] || secs="$DRIVER_CMD_TIMEOUT"
  # A NON-NUMBER IS NOT A CEILING. perl reads `alarm "15m"` as `alarm 0`, which CANCELS
  # the alarm — so an operator writing "15m" or "900s" in the config silently removes
  # every bound in the driver. Refuse to pretend: run it, and say the bound is not there.
  case "$secs" in
    ''|*[!0-9]*|0)
      echo "driver: '$secs' is not a number of seconds, so '$cmd' runs UNBOUNDED — set cmdTimeout to a whole number of seconds." >&2
      /bin/sh -c "$cmd"; return $? ;;
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
    ' "$secs" /bin/sh -c "$cmd"
    rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$secs" /bin/sh -c "$cmd"; rc=$?
  else
    echo "driver: neither perl nor timeout is available, so '$cmd' runs UNBOUNDED" >&2
    /bin/sh -c "$cmd"; rc=$?
  fi
  return "$rc"
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
# project says where with `worktreeRoot`; the temp dir is the fallback for a
# project that names none.
driver_worktree_root() {
  local r; r=$(driver_opt worktreeRoot "")
  case "$r" in
    '~')   r="$HOME" ;;
    '~/'*) r="$HOME/${r#\~/}" ;;
  esac
  [ -n "$r" ] || r="${TMPDIR:-/tmp}"
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
    dest="$(driver_state_dir "$t")/scratch/$p"
    mkdir -p "$(dirname "$dest")" 2>/dev/null
    rm -rf "$dest" 2>/dev/null
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

# THE GRADE SCALE, and the one place it is named. Every reviewer and every agent
# that files work grades what it raises, and the grade — not the list it arrived
# in — decides the effect: a Critical or a Major sends work back, a Minor leaves
# as one follow-up, a Nit is dropped. Two representations of the same judgement is
# how a check and the thing it checks end up derived from different inputs.
DRIVER_GRADES="${DRIVER_GRADES:-critical major minor nit}"

# The priority a filed follow-up carries, read off the grade, so the queue orders
# by the same judgement the reviewer made. P0-P3 is the kit's own vocabulary (the
# same labels /queue, /work and /project already sort on); a project that names
# them differently says so under labels.priority. A Nit is never filed, so it has
# no label here.
DRIVER_LABEL_CRITICAL="${DRIVER_LABEL_CRITICAL:-$(driver_opt labels.priority.critical P0)}"
DRIVER_LABEL_MAJOR="${DRIVER_LABEL_MAJOR:-$(driver_opt labels.priority.major P1)}"
DRIVER_LABEL_MINOR="${DRIVER_LABEL_MINOR:-$(driver_opt labels.priority.minor P3)}"

export DRIVER_HOME DRIVER_DIR DRIVER_BRIEFS DRIVER_SCHEMAS DRIVER_VALIDATE DRIVER_STEPS
export DRIVER_MAX_BUILD_TRIES DRIVER_MAX_REVIEW_ROUNDS DRIVER_CLAUDE DRIVER_CMD_TIMEOUT
export DRIVER_GRADES DRIVER_LABEL_CRITICAL DRIVER_LABEL_MAJOR DRIVER_LABEL_MINOR
export DRIVER_PREPARE_WHY
export DRIVER_OK DRIVER_E_QUESTION DRIVER_E_NO_SKILL DRIVER_E_SCHEMA
export DRIVER_E_NO_BRIEF DRIVER_E_REFUSED DRIVER_E_TIMEOUT DRIVER_E_REWORK
