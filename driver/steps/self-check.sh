#!/usr/bin/env bash
# steps/self-check.sh — the gates, run by the driver, read by exit code.
#
#   driver_step_self_check <ticket>
#
# Three rules, each of which has cost this project a shipped defect:
#
#   ONE GATE, ONE COMMAND, AND THE EXIT CODE IS THE VERDICT. A gate batched with
#   anything else reports on the shell reaching that line. A warning list is not
#   a failure and a printed error is not one either — the exit line is.
#
#   EVERY GATE RUNS, INCLUDING THE ONES BEHIND A FAILURE. A group that stops at
#   the first red means "gates pass locally" is only ever true of a prefix, and
#   the gates behind it have never run on this change even once.
#
#   NOTHING CONFIGURED IS A REFUSAL, NOT A PASS. A self-check with no gates
#   reports exactly like a self-check that found nothing wrong. That is the
#   whole failure mode: a protection that did not run looks like one that
#   passed.
#
# The gates themselves are a project fact, read from harness.json's `gates`
# object. The kit names none of them. Two shapes are read, and only two:
#
#   { "local": ["<this project's gate command>", …] }   the documented shape
#   { "<name>": "<command>", … }        a flat map of name to command
#
# `group` and `requiredChecks` ARE NOT COMMANDS and are never run as one. `group`
# names a gate group inside the project's own runner and `requiredChecks` names the
# CI checks a pull request waits on — neither is a shell line. Reading every key as
# a command turned the documented shape into three broken ones: measured on the
# 2026-09-27 trial, `local` exited 127 with ``[: missing `]' ``, `group` with
# `gates:repo: command not found` and `requiredChecks` with `Typecheck + Unit
# tests,: command not found`, so a correctly-configured project was told "3 of 3
# gate(s) red". It failed loudly rather than falsely green, which is the right
# direction to fail in and still the wrong answer.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/state.sh" || exit 1
# _driver_owed: whether a reviewer the push demands is still owed on this diff.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/push-requires.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/format.sh" || exit 1

# _driver_note_changelog_skip <ticket> <tree> — the build steps answered `changelog:
# {skipped: <reason>}`, and their commits did not carry the project's skip line: the
# push was refused after review was paid for (trial run of #11168, 2026-10-01). When
# the project's gate accepts ONE branch-wide line (changelog.branchTrailer), the
# driver adds one empty commit carrying `<trailer>: <reason>` — no history is
# rewritten. Only when EVERY build answer reported skipped, and no commit on the
# branch already carries the line.
_driver_note_changelog_skip() {
  local t="$1" wt="$2" trailer all reason base c out
  trailer=$(driver_opt changelog.branchTrailer "")
  [ -n "$trailer" ] || return 0
  all="$(driver_state_dir "$t")/steps/build.all.json"
  [ -s "$all" ] || return 0
  jq -e -s 'length > 0 and all(.[]; ((.changelog.skipped // "") | gsub("\\s"; "")) != "")' "$all" >/dev/null 2>&1 || return 0
  reason=$(jq -r -s '[.[] | .changelog.skipped] | first' "$all" 2>/dev/null | tr '\r\n\t' '   ' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-200)
  [ -n "$reason" ] || return 0
  base=$(git -C "$wt" merge-base "origin/$INTEGRATION_BRANCH" HEAD 2>/dev/null \
         || git -C "$wt" merge-base "$INTEGRATION_BRANCH" HEAD 2>/dev/null)
  [ -n "$base" ] || return 0
  for c in $(git -C "$wt" rev-list "$base"..HEAD 2>/dev/null); do
    git -C "$wt" log -1 --format=%B "$c" \
      | awk -v t="$trailer:" 'index($0, t) == 1 && substr($0, length(t) + 1) ~ /[^[:space:]]/ { f = 1 } END { exit !f }' && return 0
  done
  # A normal commit: the project's hooks run on it, nothing is skipped.
  out="$(driver_state_dir "$t")/steps/changelog-note.out"
  if ! git -C "$wt" commit -q --only --allow-empty -m "$(driver_opt commit.parkType chore): no changelog for #$t" -m "$trailer: $reason" > "$out" 2>&1; then
    driver_say "✋ self-check: the build answered 'no changelog' and the commit saying so for the branch could not be made — $(tail -2 "$out" | tr '\n' ' ')"
    driver_state_set "$t" park_note "could not commit '$trailer: $reason' for the branch: $(tail -2 "$out" | tr '\n' ' ' | cut -c1-200)"
    return "$DRIVER_E_REFUSED"
  fi
  driver_say "   self-check: every build step answered 'no changelog' — said once for the branch: $trailer: $reason"
  return 0
}

# A RATCHET THAT WENT DOWN IS LOCKED IN, NOT PARKED. A shrink-only ratchet fails when
# its baseline sits ABOVE actual — the build improved things and left the headroom —
# and prints the command that lowers the baseline. Parked on exactly that (2026-10-20:
# "1 entry sits ABOVE actual — 3 … of free headroom"), a build that made the code
# better stopped. The driver runs the gate's own lowering command and commits. Only
# when the output names no rise: a ratchet's update refuses to raise a number, and a
# rise is code to fix. Only a package-script command, and only the files it changed.
#   ✗ N entries sit ABOVE actual — … / Lock the cleanup in: <cmd>
#   ✗ N baseline entries name things that no longer exist / Drop the entries: <cmd>
#   Lock the progress in:  <cmd>
# _driver_ratchet_tighten <ticket> <tree> <gate output> <label> — 0 when it committed
# a lowered baseline and the gate should run again.
DRIVER_RATCHET_CMD_RE='^(npm|pnpm|yarn|bun) run [A-Za-z0-9:._/-]+( --)?( --[A-Za-z][A-Za-z-]*)+$'
_driver_ratchet_tighten() {
  local t="$1" wt="$2" out="$3" label="$4" cmds c ran="" log
  [ -f "$out" ] || return 1
  grep -qE 'ABOVE actual|no longer exist|free headroom|Lock the (cleanup|progress) in' "$out" || return 1
  if grep -qE '(^|[[:space:]])ROSE([[:space:](]|$)|RISEN' "$out"; then
    driver_say "   self-check: $label — a ratchet has slack to lock in, but one also ROSE; that is code to fix, so nothing is tightened"
    return 1
  fi
  cmds=$(sed -nE 's/^.*(Lock the (cleanup|progress) in|Drop the entries):[[:space:]]+//p' "$out" \
         | sed -e 's/[[:space:]]*$//' | grep -E "$DRIVER_RATCHET_CMD_RE" | awk '!seen[$0]++')
  [ -n "$cmds" ] || return 1
  local before after changed
  before=$(git -C "$wt" diff --name-only HEAD 2>/dev/null | sort)
  log="$(driver_state_dir "$t")/steps/ratchet-tighten.out"; : > "$log"
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    driver_say "   self-check: $label — a ratchet sits above actual; locking the improvement in: $c"
    ( cd "$wt" && driver_run_project "${DRIVER_CMD_TIMEOUT:-900}" "$c" ) >> "$log" 2>&1 && ran="$ran${ran:+, }$c"
  done <<EOS
$cmds
EOS
  [ -n "$ran" ] || { driver_say "   self-check: $label — the lowering command failed: $(tail -2 "$log" | tr '\n' ' ')"; return 1; }
  # Only what the command changed is committed: anything already dirty is not swept in.
  after=$(git -C "$wt" diff --name-only HEAD 2>/dev/null | sort)
  changed=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed '/^$/d')
  [ -n "$changed" ] || { driver_say "   self-check: $label — the lowering command changed nothing"; return 1; }
  local files=(); while IFS= read -r c; do files+=("$c"); done <<<"$changed"
  if ! ( cd "$wt" && git commit -q -m "$(driver_opt commit.parkType chore): lock in the lower ratchet baseline for #$t" -m "Ran: $ran" -- "${files[@]}" ) >> "$log" 2>&1; then
    driver_say "   self-check: $label — the lowered baseline could not be committed: $(tail -2 "$log" | tr '\n' ' ')"
    return 1
  fi
  driver_say "   self-check: $label — lowered baseline committed; running it again"
  return 0
}

# The compiler's or runner's own error lines when it printed any, else the tail.
_driver_gate_lines() { # <file>
  local l
  l=$(grep -E 'error TS[0-9]+|(^|[[:space:]])(error|Error|FAIL)[:[:space:]]' "$1" 2>/dev/null | head -3)
  [ -n "$l" ] || l=$(tail -3 "$1" 2>/dev/null)
  printf '%s' "$l" | tr '\n' ' ' | tr -s ' ' | cut -c1-400
}

_driver_order_has() { case " ${DRIVER_STEPS:-} " in *" $1 "*) return 0 ;; esac; return 1; }

# A GATE'S TIME LIMIT FOLLOWS THE MACHINE. cmdTimeout is what a gate takes on a quiet
# Mac; with five or six builds sharing it, `changed 3` ran past 900s three times on
# 2026-10-20 and each parked a build that was fine (#12801, #12563, #12782). The limit
# is scaled by load per core, between 1x and DRIVER_GATE_TIMEOUT_MAX_SCALE (3x).
# _driver_gate_scale — the factor; _driver_gate_secs [factor] — the limit in seconds.
_driver_gate_scale() {
  local load cores max="${DRIVER_GATE_TIMEOUT_MAX_SCALE:-3}" f
  load=$(swarm_load 2>/dev/null); cores=$(swarm_cores 2>/dev/null)
  case "$load" in ''|*[!0-9]*) load=0 ;; esac
  case "$cores" in ''|*[!0-9]*|0) cores=1 ;; esac
  case "$max" in ''|*[!0-9]*|0) max=3 ;; esac
  f=$(( (load + cores - 1) / cores ))
  [ "$f" -ge 1 ] || f=1
  [ "$f" -le "$max" ] || f=$max
  printf '%s' "$f"
}
_driver_gate_secs() {
  case "${DRIVER_CMD_TIMEOUT:-}" in ''|*[!0-9]*|0) printf '%s' "${DRIVER_CMD_TIMEOUT:-}"; return ;; esac
  printf '%s' $(( DRIVER_CMD_TIMEOUT * ${1:-$(_driver_gate_scale)} ))
}

# _driver_gate_quiet_retry <label> <secs> — a gate ran past its limit: give the slot
# back, wait until the machine is quiet, take a slot again. Sets DRIVER_GATE_RETRY_SECS
# to the second try's limit: twice the base at least, scaled by the load then.
_driver_gate_quiet_retry() {
  local label="$1" secs="$2" s2
  driver_say "⏳ self-check: $label did not return within ${secs}s (load $(swarm_load 2>/dev/null || echo ?) on $(swarm_cores 2>/dev/null || echo ?) cores) — waiting for a quieter moment, then running it once more. A timeout is not a red gate."
  machine_gate_release
  machine_gate_wait_load 0
  machine_gate_acquire 0 "self-check #${DRIVER_TICKET:-?}"
  s2=$(_driver_gate_secs)
  case "$s2" in ''|*[!0-9]*) DRIVER_GATE_RETRY_SECS="$s2"; return 0 ;; esac
  [ "$s2" -ge $(( DRIVER_CMD_TIMEOUT * 2 )) ] || s2=$(( DRIVER_CMD_TIMEOUT * 2 ))
  DRIVER_GATE_RETRY_SECS="$s2"
}

# _driver_gate_timed_out <label> <secs> <cmd> <loaded> — the second try ran out too.
# On a loaded machine that is the machine, not the change: the run goes back on the
# queue (DRIVER_E_BUSY). On a quiet one it is a command that does not return: a park.
_driver_gate_timed_out() {
  local label="$1" secs="$2" cmd="$3" loaded="$4"
  if [ "$loaded" -eq 1 ]; then
    driver_say "⏳ self-check: $label did not return within ${secs}s on the second try either, with the machine loaded — back on the queue for a quieter machine, not parked."
    driver_state_set "$DRIVER_TICKET" park_note "the '$label' gate did not return within ${secs}s twice while the machine was loaded: $cmd"
    return "$DRIVER_E_BUSY"
  fi
  driver_say "✋ self-check: $label ran out of time twice (over ${secs}s) on a quiet machine. A gate that does not return is not a gate that passed."
  driver_state_set "$DRIVER_TICKET" park_note "the '$label' gate did not return within ${secs}s, twice, on a quiet machine: $cmd"
  return "$DRIVER_E_TIMEOUT"
}

# THE PUSH'S OWN CHECKS. On 2026-10-17 self-check said "3 gate(s) green" and the
# push then refused on one of the 77 checks the project's pre-push runs: the work
# parked after review was paid for, on a finding the fix step never saw (#236). So
# the push verification is a gate here too, and its red goes to fix like any other.
#
#   gates.prePush   a command   run it, as the other gates run
#                   false       off, and said
#                   absent      the tree's own pre-push hook, run the way `git push`
#                               runs it: remote and url as arguments, the ref line
#                               on stdin
#   gates.prePushOwed  a command  run in its place while a reviewer the push demands
#                                 is still owed: the push's checks minus that verdict
#
# A TRIAL, NOT A PUSH. SIGNOFF_GUARD_DRYRUN=1 tells the sign-off guard to refuse
# without its side effects (the hold back on, a comment, a notice) for a head that
# was never pushed.
#
# _driver_prepush <ticket> <tree> <out> [key] — its exit code; 0 with DRIVER_PREPUSH_DID
# "none" or "off" when there was nothing to run. DRIVER_PREPUSH_CMD names what ran.
_driver_prepush() {
  local t="$1" wt="$2" out="$3" key="${4:-prePush}" ptype top hook branch head rsha url rc=0
  DRIVER_PREPUSH_DID=ran; DRIVER_PREPUSH_CMD=""
  ptype=$(jq -r --arg k "$key" '.gates[$k] | type' "$HARNESS_CFG" 2>/dev/null)
  case "$ptype" in
    string)
      DRIVER_PREPUSH_CMD=$(jq -r --arg k "$key" '.gates[$k]' "$HARNESS_CFG")
      if [ -z "$(printf '%s' "$DRIVER_PREPUSH_CMD" | tr -d '[:space:]')" ]; then
        printf 'harness.json gates.%s is an empty command\n' "$key" > "$out"; return 127
      fi
      ( cd "$wt" && export SIGNOFF_GUARD_DRYRUN=1 && driver_run_project "${DRIVER_GATE_SECS:-$DRIVER_CMD_TIMEOUT}" "$DRIVER_PREPUSH_CMD" ) > "$out" 2>&1 || rc=$?
      return "$rc" ;;
    boolean)
      if [ "$(jq -r --arg k "$key" '.gates[$k]' "$HARNESS_CFG")" = false ]; then DRIVER_PREPUSH_DID=off; return 0; fi
      printf 'harness.json gates.%s is true, which names no command (a command, or false)\n' "$key" > "$out"; return 127 ;;
    null) ;;
    *) printf 'harness.json gates.%s is a %s; it takes a command or false\n' "$key" "${ptype:-unreadable value}" > "$out"; return 127 ;;
  esac
  top=$(git -C "$wt" rev-parse --show-toplevel 2>/dev/null) || top="$wt"
  # Unset hooks resolve to no pre-push at all, which would read as "nothing to verify".
  if [ -d "$top/.husky" ] && ! driver_ensure_hooks "$MAIN_REPO" "$wt" >"$out" 2>&1; then return 127; fi
  hook="$(git -C "$wt" rev-parse --path-format=absolute --git-path hooks 2>/dev/null)/pre-push"
  if [ ! -x "$hook" ]; then DRIVER_PREPUSH_DID=none; return 0; fi
  branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  head=$(git -C "$wt" rev-parse HEAD 2>/dev/null)
  rsha=$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null) || rsha=0000000000000000000000000000000000000000
  url=$(git -C "$wt" remote get-url origin 2>/dev/null) || url=origin
  DRIVER_PREPUSH_CMD="the pre-push hook ($hook)"
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$branch" "$head" "$branch" "$rsha" > "$out.stdin"
  ( cd "$top" && export SIGNOFF_GUARD_DRYRUN=1 && driver_bounded_argv "${DRIVER_GATE_SECS:-$DRIVER_CMD_TIMEOUT}" "$out.stdin" "$hook" origin "$url" ) > "$out" 2>&1 || rc=$?
  rm -f "$out.stdin"
  return "$rc"
}

# _driver_prepush_owed <ticket> <tree> — the review.attest rows still owed on this
# diff, space-separated. The review step records them after self-check, so a push
# verification run before then is red on them whatever the change.
_driver_prepush_owed() {
  local t="$1" wt="$2" trunk="" r name owed list=""
  for r in "origin/$INTEGRATION_BRANCH" "$INTEGRATION_BRANCH"; do
    git -C "$wt" rev-parse --verify -q "$r" >/dev/null 2>&1 && { trunk="$r"; break; }
  done
  while IFS=$'\t' read -r name owed; do
    [ -n "$name" ] && [ -n "$owed" ] || continue
    _driver_owed "$t" "$name" "$owed" "$wt" "$trunk" >/dev/null 2>&1 || list="$list $name"
  done <<EOS
$(jq -r '(.review.attest // {}) | if type == "object" then to_entries[] | "\(.key)\t\(if (.value | type) == "string" then .value else (.value.owed // "") end)" else empty end' "$HARNESS_CFG" 2>/dev/null)
EOS
  printf '%s' "${list# }"
}

# _driver_prepush_gate <ticket> <tree> — the push verification as a self-check gate.
# Adds to the caller's ran/failed/redlines/infra and the findings rows; returns
# DRIVER_E_TIMEOUT on a hang, else 0.
_driver_prepush_gate() {
  local t="$1" wt="$2" pout owed prc=0 key=prePush
  pout="$(driver_state_dir "$t")/steps/gate-pre-push.out"
  # A red gate above is fixed first; the push's checks run on a change that passes them.
  if [ "$failed" -gt 0 ]; then
    driver_say "   self-check: pre-push waits — the gates above are red, and their fix comes first"
    return 0
  fi
  owed=$(_driver_prepush_owed "$t" "$wt")
  if [ -n "$owed" ]; then
    if [ "$(jq -r '.gates.prePushOwed | type' "$HARNESS_CFG" 2>/dev/null)" != string ]; then
      driver_say "   self-check: pre-push waits for the push — $owed is owed on this diff, the review records it after this step, and harness.json names no gates.prePushOwed to run without it"
      return 0
    fi
    key=prePushOwed
    driver_say "   self-check: $owed is owed on this diff — running gates.prePushOwed, the push's checks without that verdict"
  fi
  local pscale psecs; pscale=$(_driver_gate_scale); psecs=$(_driver_gate_secs "$pscale")
  DRIVER_GATE_SECS="$psecs" _driver_prepush "$t" "$wt" "$pout" "$key" || prc=$?
  if [ "$prc" -eq 124 ]; then
    _driver_gate_quiet_retry pre-push "$psecs"
    psecs="$DRIVER_GATE_RETRY_SECS"; prc=0
    [ "$(_driver_gate_scale)" -le 1 ] || pscale=2
    DRIVER_GATE_SECS="$psecs" _driver_prepush "$t" "$wt" "$pout" "$key" || prc=$?
    if [ "$prc" -eq 124 ]; then
      pushran=1
      _driver_gate_timed_out pre-push "$psecs" "$DRIVER_PREPUSH_CMD" "$([ "$pscale" -gt 1 ] && echo 1 || echo 0)"
      return $?
    fi
  fi
  case "$DRIVER_PREPUSH_DID" in
    none) driver_say "   self-check: pre-push — this tree has no pre-push hook and harness.json names no gates.prePush"; return 0 ;;
    off)  driver_say "   self-check: pre-push off (gates.$key is false)"; return 0 ;;
  esac
  pushran=1
  if [ "$prc" -ne 0 ] && [ "$prc" -ne 124 ] \
     && { _driver_ratchet_tighten "$t" "$wt" "$pout" pre-push || driver_format_changed "$t" "$wt" "self-check: pre-push"; }; then
    prc=0; DRIVER_GATE_SECS="$psecs" _driver_prepush "$t" "$wt" "$pout" "$key" || prc=$?
  fi
  if [ "$prc" -eq 0 ]; then
    driver_say "   self-check: pre-push ok"
    return 0
  fi
  # THE OWNER'S CALL, NEVER A FINDING: handed to fix, the model could write the
  # pixel-change-after-signoff trailer itself and wave its own change through.
  if driver_signoff_refusal "$t" "$pout"; then
    driver_say "✋ self-check: the owner has signed this PR's screens and this change moves them — nothing goes to fix. $(driver_signoff_line "$pout")"
    return "$DRIVER_E_REFUSED"
  fi
  failed=$((failed+1))
  driver_say "✋ self-check: pre-push failed (exit $prc) — $(_driver_gate_lines "$pout")"
  redlines="$redlines${redlines:+ | }pre-push ($DRIVER_PREPUSH_CMD, exit $prc): $(_driver_push_lines "$pout")"
  case "$prc" in 126|127) infra="$infra pre-push" ;; esac
  jq -cn --arg cmd "$DRIVER_PREPUSH_CMD" --argjson rc "$prc" --arg out "$(_driver_push_tail "$pout")" \
    '{id: "gate-pre-push", gate: "pre-push", command: $cmd, exit: $rc, output: $out}' >> "$findings.rows"
  return 0
}

# The lines a push verification said no with (✗), else the compiler's or the tail.
_driver_push_lines() { # <file>
  local l; l=$(grep -E '✗' "$1" 2>/dev/null | head -3)
  [ -n "$l" ] || l=$(_driver_gate_lines "$1")
  printf '%s' "$l" | tr '\n' ' ' | tr -s ' ' | cut -c1-400
}
# Every ✗ line, then the tail, once each: the finding fix is handed.
_driver_push_tail() { # <file>
  { grep -E '✗' "$1"; tail -40 "$1"; } 2>/dev/null | awk '!seen[$0]++' | cut -c1-400 | head -60
}

driver_step_self_check() { # <ticket>
  local t="${1:?driver_step_self_check: need a ticket}"
  local wt names row name safe cmd rc gtype failed=0 ran=0 pushran=0 empty="" redlines="" infra="" findings gscale gsecs
  export DRIVER_TICKET="$t"
  wt=$(driver_state_get "$t" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  findings="$(driver_state_dir "$t")/steps/self-check.findings.json"
  rm -f "$findings" "$findings.rows"
  # Said before the gates run, and through the ticket's log: each gate's own output goes
  # to a file, so a warning printed inside one is a warning nobody sees.
  driver_check_timeout || true

  # The build's own changelog claim, written where the project's gate reads it.
  local trc=0; _driver_note_changelog_skip "$t" "$wt" || trc=$?
  [ "$trc" -eq 0 ] || return "$trc"

  # The SHAPE first. `gates` written as a list reads as no names at all, and the
  # "nothing configured" guard below does not fire because the key is there — so one
  # typo in harness.json turned this whole step into a no-op reporting green.
  gtype=$(jq -r '(.gates // {}) | type' "$HARNESS_CFG" 2>/dev/null)
  if [ "$gtype" != "object" ]; then
    driver_say "✋ self-check: harness.json's 'gates' is a ${gtype:-unreadable value}, and this reads an object of name to command."
    driver_state_set "$t" park_note "the gates in harness.json are a ${gtype:-unreadable value}; self-check reads an object of name to command"
    return "$DRIVER_E_REFUSED"
  fi
  # ONE TAB-SEPARATED `name<TAB>command` PER LINE, from whichever shape this project
  # wrote. A command carries spaces and a name does not, so the split is on the tab.
  #
  # CHANGED-ONLY WHEN THE PROJECT SAYS HOW. The kit's standing rule: local checks run
  # what the change touches, and CI runs the whole suite before anything merges. A
  # project's `gates.changed` is that list; `gates.local` is the whole-app form. On
  # the 2026-09-30 trial the whole-app form ran repo-wide lint and typecheck plus 37
  # repo checks for a one-file fix, and failed on a check the change never touched.
  if [ "$(jq -r '(.gates.changed // null) | type' "$HARNESS_CFG" 2>/dev/null)" = "array" ]; then
    names=$(jq -r '.gates.changed | to_entries[] | "changed \(.key + 1)\t\(.value)"' "$HARNESS_CFG" 2>/dev/null)
  elif [ "$(jq -r '(.gates.local // null) | type' "$HARNESS_CFG" 2>/dev/null)" = "array" ]; then
    names=$(jq -r '.gates.local | to_entries[] | "local \(.key + 1)\t\(.value)"' "$HARNESS_CFG" 2>/dev/null)
  else
    # A value that is not a string is NOT skipped: it falls through as an empty
    # command, so the "every gate is empty, nothing ran" refusal counts it by name.
    # Dropped here it would have left a key configured, unrun and unmentioned.
    # prePush is the push verification below, not a gate of this list.
    names=$(jq -r '.gates | del(.prePush) | to_entries[] |"\(.key)\t\(if (.value | type) == "string" then .value else "" end)"' "$HARNESS_CFG" 2>/dev/null)
  fi
  if [ -z "$names" ]; then
    driver_say "✋ self-check: harness.json configures no local 'gates' command. A check that never ran reports exactly like one that found nothing, so this refuses rather than passing."
    driver_state_set "$t" park_note "harness.json configures no gate command for self-check to run"
    return "$DRIVER_E_REFUSED"
  fi

  # Heavy local work waits for the machine: under the load ceiling, then one gate
  # slot held across every gate. It waits as long as it takes; it never parks.
  . "$KIT_ROOT/scripts/machine-gate.sh" || {
    driver_state_set "$t" park_note "self-check could not load $KIT_ROOT/scripts/machine-gate.sh, so no gate ran"
    return "$DRIVER_E_REFUSED"; }
  machine_gate_wait_load 0
  machine_gate_acquire 0 "self-check #$t"

  # The branch's files are formatted before any gate reads them: a format check is a
  # command the driver can run, never a finding to send to fix.
  driver_format_changed "$t" "$wt" self-check || true

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    name=${row%%	*}; cmd=${row#*	}
    # Trimmed before the emptiness test, and a comment is not a command. A
    # placeholder left in harness.json counted as a gate that ran, printed "ok", and
    # took the green count up with it — one keystroke from the empty case.
    case "$(printf '%s' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')" in
      ''|null|'#'*) empty="$empty $name"; continue ;;
    esac
    ran=$((ran+1))
    safe=$(printf '%s' "$name" | tr -cs 'A-Za-z0-9._-' '-')
    # Its own command, its own exit code, nothing batched with it. The limit is
    # scaled by the machine's load, read now.
    gscale=$(_driver_gate_scale); gsecs=$(_driver_gate_secs "$gscale")
    ( cd "$wt" && driver_run_project "$gsecs" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then
      # Its own outcome, not a red gate: it says nothing about the change. One more
      # try once the machine is quiet, before anything is decided.
      _driver_gate_quiet_retry "$name" "$gsecs"
      gsecs="$DRIVER_GATE_RETRY_SECS"
      [ "$(_driver_gate_scale)" -le 1 ] || gscale=2
      ( cd "$wt" && driver_run_project "$gsecs" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>&1
      rc=$?
    fi
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] \
       && { _driver_ratchet_tighten "$t" "$wt" "$(driver_state_dir "$t")/steps/gate-$safe.out" "$name" \
            || driver_format_changed "$t" "$wt" "self-check: $name"; }; then
      ( cd "$wt" && driver_run_project "$gsecs" "$cmd" ) > "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>&1
      rc=$?
    fi
    if [ "$rc" -eq 124 ]; then
      # The park question a reader needs is "which command hangs", not "which check failed".
      local trc=0
      _driver_gate_timed_out "$name" "$gsecs" "$cmd" "$([ "$gscale" -gt 1 ] && echo 1 || echo 0)" || trc=$?
      machine_gate_release
      return "$trc"
    elif [ "$rc" -eq 0 ]; then
      driver_say "   self-check: $name ok"
    else
      failed=$((failed+1))
      driver_say "✋ self-check: $name failed (exit $rc) — $(tail -3 "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>/dev/null | tr '\n' ' ')"
      redlines="$redlines${redlines:+ | }$name (\`$cmd\`, exit $rc): $(_driver_gate_lines "$(driver_state_dir "$t")/steps/gate-$safe.out")"
      # 126/127: the command itself could not run — configuration, not the change.
      case "$rc" in 126|127) infra="$infra $name" ;; esac
      jq -cn --arg id "gate-$safe" --arg name "$name" --arg cmd "$cmd" --argjson rc "$rc" \
        --arg out "$(tail -60 "$(driver_state_dir "$t")/steps/gate-$safe.out" 2>/dev/null | cut -c1-400)" \
        '{id: $id, gate: $name, command: $cmd, exit: $rc, output: $out}' >> "$findings.rows"
    fi
  done <<EOS
$names
EOS
  # The push verification last, after every gate above ran whatever it said.
  local pgrc=0; _driver_prepush_gate "$t" "$wt" || pgrc=$?
  if [ "$pgrc" -ne 0 ]; then machine_gate_release; return "$pgrc"; fi
  machine_gate_release

  # NOTHING RAN IS A REFUSAL. Every command empty is the same failure as no gates at
  # all, wearing a configured shape — and it printed "0 gate(s) green" and returned
  # OK, so ship pushed and armed auto-merge on code nothing had checked.
  if [ "$ran" -eq 0 ]; then
    driver_say "✋ self-check: every configured gate has an empty command (${empty# }), so nothing ran. Nothing having run is not everything having passed."
    driver_state_set "$t" park_note "every configured gate has an empty command (${empty# }), so nothing ran"
    return "$DRIVER_E_REFUSED"
  fi
  if [ "$failed" -gt 0 ]; then
    driver_say "✋ self-check: $failed of $((ran+pushran)) gate(s) red. The local gate IS the gate — nothing is pushed past it."
    # The failing gates travel with the refusal: a park pointing at a log on the host
    # that ran it is a reason nobody else can read.
    driver_state_set "$t" park_note "$failed of $((ran+pushran)) gate(s) red — $redlines"
    # UP TO DRIVER_MAX_GATE_FIXES REPAIR ROUNDS, then a park. A gate the model can repair goes to fix with its
    # output as the finding, inside the fix-round ceiling; a second red parks.
    local reds fixes
    reds=$(driver_state_count "$t" selfcheck_red); fixes=$(driver_state_count "$t" fix)
    driver_state_bump "$t" selfcheck_red
    if [ -n "$infra" ]; then
      driver_say "   self-check: not sent to fix —${infra} could not run at all (exit 126/127), which is configuration, not the change."
    elif [ "${reds:-0}" -ge "$DRIVER_MAX_GATE_FIXES" ]; then
      driver_say "   self-check: not sent to fix — $DRIVER_MAX_GATE_FIXES gate fix round(s) are used on this run."
    elif ! _driver_order_has fix; then
      driver_say "   self-check: not sent to fix — this run has no fix step."
    else
      jq -s . "$findings.rows" > "$findings" && rm -f "$findings.rows"
      driver_state_set "$t" park_note ""
      driver_say "↩ self-check: $failed red gate(s) go to fix with their output as the findings."
      return "$DRIVER_E_REWORK"
    fi
    rm -f "$findings.rows"
    return "$DRIVER_E_REFUSED"
  fi
  rm -f "$findings.rows"
  driver_say "   self-check: $((ran+pushran)) gate(s) green"
  return "$DRIVER_OK"
}
