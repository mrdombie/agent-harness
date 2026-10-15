#!/usr/bin/env bash
# nonstop.sh — the state behind a window that works one area until it is done.
#
#   nonstop.sh start <area-label>      arm this window's loop on that label
#   nonstop.sh wake                    THE call every wake starts with: one short
#                                      board ending in a single NEXT: line
#   nonstop.sh stop "<reason>"         end it; prints "Stopped: <reason>"
#   nonstop.sh agent add <id> <ticket> [--kind build|fix|pm|watch] [--branch b]
#                                      [--worktree w] [--pr n]
#   nonstop.sh agent done <id>
#   nonstop.sh agent cut  <id> [text]  an agent died on the usage limit
#   nonstop.sh agents                  this window's agents
#   nonstop.sh resume                  what to restart after a usage wall, or skip
#   nonstop.sh hold                    0 + "held until …" while the plan's limit holds
#   nonstop.sh hold-set [text]         record a usage wall (text, else stdin)
#   nonstop.sh reset-epoch [text]      the reset time a limit message names
#   nonstop.sh area                    the area's counts (cached a minute)
#   nonstop.sh should-continue         exit 2 + why, when a slot is free and work is
#                                      runnable (the keep-working Stop hook asks this)
#   nonstop.sh window                  this window's id
#
# WHY A SCRIPT. The loop is instructions, and instructions are re-read at the cost
# of the whole context on every wake. Measured 2026-10-15 over eight loop windows
# of the last three days: 8,630 window calls averaging 150k-546k tokens of context
# each, 1,100 of them (13%) shell polls of a PR or a run. Everything here is a
# question with a shell answer, so it costs a shell call and not a model turn.
#
# STATE. One file per window, $STATE_DIR/nonstop/w-<window>.json: the area and
# the agents it started. The plan's usage limit is account-wide, so its hold is
# one shared file. A window is the Claude process it runs in — the same for every
# sub-agent and tool call inside it, different for the window beside it, and it
# survives compaction.

_NS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$_NS_HOME/toolkit-env.sh" >/dev/null 2>&1 || true
. "$_NS_HOME/claim-proc.sh" || exit 1
. "$_NS_HOME/../hooks/lib/python.sh" || exit 1

set -uo pipefail

# Hooks run outside any checkout; fall back to the values the resolver last saw.
SD="${NONSTOP_STATE_DIR:-${STATE_DIR:-${HARNESS_STATE_DIR:-$(cat "$HOME/.claude/.harness-last-state-dir" 2>/dev/null)}}}"
SD="${SD/#\~/$HOME}"
REPO="${NONSTOP_REPO_SLUG:-${REPO_SLUG:-$(cat "$HOME/.claude/.harness-last-repo-slug" 2>/dev/null)}}"
L_READY="${LBL_READY:-status:ready}"; L_GATED="${LBL_GATED:-status:gated}"
L_DRAFT="${LBL_DRAFTING:-status:drafting}"; L_HOLD="${HOLD_LABEL:-needs:human-approval}"
PREFIX="${BRANCH_PREFIX:-}"
# Agent places for the MACHINE, not per window: two windows on one area share
# the operator's 4-agent limit rather than doubling it.
MAX="${NONSTOP_MAX_AGENTS:-4}"
PROJECTS="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
[ -n "$SD" ] || { echo "nonstop: no state dir (set HARNESS_STATE_DIR)" >&2; exit 1; }
NSD="$SD/nonstop"; mkdir -p "$NSD"
HOLD_F="$NSD/usage-hold"

now() { printf '%s' "${NONSTOP_NOW:-$(date +%s)}"; }
clock() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M 2>/dev/null || echo "$1"; }
WINDOW="${NONSTOP_WINDOW:-$(claim_session_pid)}"
WF="$NSD/w-$WINDOW.json"

lock() { local i=0; while ! mkdir "$1.lock" 2>/dev/null; do i=$((i+1)); [ $i -gt 100 ] && rm -rf "$1.lock"; sleep 0.05; done; }
unlock() { rmdir "$1.lock" 2>/dev/null || true; }
# Apply a jq program to a window file under its lock. Assert the write landed.
edit() { # <file> <jq program> [jq args…]
  local f="$1" p="$2"; shift 2
  lock "$f"
  [ -f "$f" ] || printf '{"agents":[]}' > "$f"
  if jq "$@" "$p" "$f" > "$f.tmp" 2>/dev/null && [ -s "$f.tmp" ]; then mv "$f.tmp" "$f"; else rm -f "$f.tmp"; unlock "$f"; return 1; fi
  unlock "$f"
}
armed() { [ -f "$WF" ] && [ "$(jq -r '.area // ""' "$WF")" != "" ] && [ "$(jq -r '.stopped // ""' "$WF")" = "" ]; }

# ---- the usage limit ----------------------------------------------------------
# The wording, measured on this machine's transcripts (2026-10-15):
#   Agent terminated early due to an API error: You've hit your session limit ·
#   resets 2:40am (Europe/London) (error type rate_limit, HTTP 429, …)
# and, in swarm logs, "resets Sep 29 at 9pm (Europe/London)" and a structured
# "resetsAt":<epoch>. The epoch is exact and wins. A wall that names no time at all
# is held for an hour and re-read, rather than read as no wall.
reset_epoch() { # <text>
  harness_python || { echo $(( $(now) + 3600 )); return 0; }
  NOW="$(now)" "${HARNESS_PY[@]}" - "$1" <<'PY'
import os, re, sys, datetime as dt
t = sys.argv[1]; now = int(os.environ["NOW"])
m = re.search(r'"resetsAt"\s*:\s*(\d{9,})', t)
if m:
    print(int(m.group(1))); sys.exit(0)
m = re.search(r'resets (?:([A-Z][a-z]{2}) (\d{1,2}) at )?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?: \(([^)]+)\))?', t)
if not m:
    if re.search(r"hit your [a-z ]*limit|rate_limit|HTTP 429|usage limit", t, re.I):
        print(now + 3600); sys.exit(0)
    sys.exit(1)
mon, day, h, mi, ap, tz = m.groups()
h = int(h) % 12 + (12 if ap == "pm" else 0); mi = int(mi or 0)
try:
    from zoneinfo import ZoneInfo
    zone = ZoneInfo(tz) if tz else None
except Exception:
    zone = None
base = dt.datetime.fromtimestamp(now, zone) if zone else dt.datetime.fromtimestamp(now)
if mon:
    month = dt.datetime.strptime(mon, "%b").month
    cand = base.replace(month=month, day=int(day), hour=h, minute=mi, second=0, microsecond=0)
    # Only a year boundary rolls forward (read Dec 30, "resets Jan 2"). A date
    # merely past is an old message, and an old message holds nothing.
    if cand.timestamp() < now - 180 * 86400:
        cand = cand.replace(year=cand.year + 1)
else:
    cand = base.replace(hour=h, minute=mi, second=0, microsecond=0)
    if cand.timestamp() <= now:
        cand += dt.timedelta(days=1)
print(int(cand.timestamp()))
PY
}

cmd_hold_set() {
  local text="${1:-}" e cur
  [ -n "$text" ] || text=$(cat)
  e=$(reset_epoch "$text") || { echo "nonstop: no usage limit in that text" >&2; return 1; }
  # Keep the LATER of two walls: a weekly wall outlasts the session wall that hit first.
  cur=$(cut -f1 "$HOLD_F" 2>/dev/null || echo 0); case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  [ "$e" -gt "$cur" ] && printf '%s\t%s\n' "$e" "$(printf '%s' "$text" | tr '\n\t' '  ' | cut -c1-200)" > "$HOLD_F"
  cmd_hold
}

cmd_hold() {
  local e; e=$(cut -f1 "$HOLD_F" 2>/dev/null); case "$e" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$e" -gt "$(now)" ]; then
    printf 'held until %s (%s min) — the plan usage limit\n' "$(clock "$e")" $(( (e - $(now) + 59) / 60 ))
    return 0
  fi
  rm -f "$HOLD_F"; return 1
}

# ---- agents --------------------------------------------------------------------
transcript_of() { # <agent id> — the sub-agent's own transcript, if this machine has it
  local id="${1#agent-}" f
  for f in "$PROJECTS"/*/*/subagents/agent-"$id".jsonl; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 1
}
last_words() { # <transcript> — the agent's last sentence or two, for a resume brief
  tail -c 60000 "$1" 2>/dev/null | jq -Rr 'fromjson? | select(.type=="assistant" and (.isApiErrorMessage | not)) | .message.content[]? | select(.type=="text") | .text' 2>/dev/null \
    | tail -3 | tr '\n' ' ' | cut -c1-300
}
LIMIT_TEXT='hit your [^"\\]{0,120}|"resetsAt":[0-9]+'
hit_limit() { # <transcript> — did it end on the usage wall? Only the tail counts.
  tail -c 8000 "$1" 2>/dev/null | grep -qE '"apiErrorStatus":429|hit your (session|weekly|usage)[a-z ]* limit'
}

cmd_agent() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    add)
      local id="${1:?agent add <id> <ticket>}" tk="${2:?agent add <id> <ticket>}" kind=build br="" wt="" pr=""
      shift 2
      while [ $# -gt 0 ]; do case "$1" in
        --kind) kind="$2"; shift 2 ;; --branch) br="$2"; shift 2 ;;
        --worktree) wt="$2"; shift 2 ;; --pr) pr="$2"; shift 2 ;; *) shift ;; esac; done
      edit "$WF" '.agents = ([.agents[] | select(.id != $id)] + [{id:$id,ticket:$tk,kind:$k,branch:$b,worktree:$w,pr:$p,state:"running",at:$at}])' \
        --arg id "$id" --arg tk "$tk" --arg k "$kind" --arg b "$br" --arg w "$wt" --arg p "$pr" --argjson at "$(now)" \
        && echo "agent $id on #$tk ($kind)"
      rm -f "$NSD"/area-*.txt ;;   # what is busy changed: the area's counts are stale
    done)
      edit "$WF" '.agents |= map(if .id == $id then .state = "done" else . end)' --arg id "${1:?}" && echo "agent $1 done"
      rm -f "$NSD"/area-*.txt ;;
    cut)
      local id="${1:?}" text="${2:-}"
      edit "$WF" '.agents |= map(if .id == $id then .state = "cut" else . end)' --arg id "$id"
      [ -n "$text" ] && cmd_hold_set "$text" >/dev/null 2>&1
      echo "agent $id cut off" ;;
    *) echo "agent add|done|cut" >&2; return 1 ;;
  esac
}

cmd_agents() {
  [ -f "$WF" ] || return 0
  jq -r '.agents[] | select(.state != "done") | "  \(.state)\t\(.id)\t#\(.ticket)\t\(.kind)\(if .pr != "" then "\tPR #"+.pr else "" end)"' "$WF"
}

# Agents a dead window left behind come to the first live window that looks. The
# move is under the dead file's lock, so two windows waking together cannot both
# adopt — the second finds the list already empty.
adopt_dead() {
  local f w
  for f in "$NSD"/w-*.json; do
    [ -f "$f" ] && [ "$f" != "$WF" ] || continue
    w=${f##*/w-}; w=${w%.json}
    case "$w" in ''|*[!0-9]*) continue ;; esac
    claim_pid_alive "$w" && continue
    lock "$f"
    local moved; moved=$(jq -c '[.agents[] | select(.state != "done") | .state = "cut"]' "$f" 2>/dev/null || echo '[]')
    jq '.agents = [] | .stopped = "window gone"' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    unlock "$f"
    [ "$moved" = "[]" ] || edit "$WF" '.agents += $m' --argjson m "$moved"
  done
}

# A running agent whose transcript ends on a 429 is cut off: the notification
# saying so may sit unread behind the same wall that killed it.
scan() {
  [ -f "$WF" ] || return 0
  local id t
  for id in $(jq -r '.agents[] | select(.state == "running") | .id' "$WF"); do
    t=$(transcript_of "$id") || continue
    if hit_limit "$t"; then
      # Into a variable first: bash 3.2 brace-expands a {0,120} quoted inside "$( )".
      local why; why=$(tail -c 8000 "$t" | grep -oE "$LIMIT_TEXT" | tail -1)
      cmd_agent cut "$id" "$why" >/dev/null
    fi
  done
}

pr_state() { # <branch> <pr> → MERGED | OPEN <n> | NONE — never resume what already shipped
  local br="$1" pr="$2" s
  if [ -n "$pr" ]; then
    s=$(gh pr view "$pr" --repo "$REPO" --json state -q .state 2>/dev/null) || s=""
    [ "$s" = MERGED ] && { echo MERGED; return; }
    [ "$s" = OPEN ] && { echo "OPEN $pr"; return; }
  fi
  [ -n "$br" ] || { echo NONE; return; }
  s=$(gh pr list --repo "$REPO" --head "$br" --state all --limit 5 --json number,state \
        -q 'map(select(.state=="MERGED"))|length' 2>/dev/null) || s=0
  [ "${s:-0}" -gt 0 ] 2>/dev/null && { echo MERGED; return; }
  s=$(gh pr list --repo "$REPO" --head "$br" --state open --limit 1 --json number -q '.[0].number // empty' 2>/dev/null)
  [ -n "$s" ] && { echo "OPEN $s"; return; }
  echo NONE
}

cmd_resume() {
  [ -f "$WF" ] || return 0
  if cmd_hold >/dev/null; then echo "HOLD $(cmd_hold)"; return 0; fi
  local row id tk kind br wt pr st t ahead dirty
  while IFS=$'\t' read -r id tk kind br wt pr; do
    [ -n "$id" ] || continue
    st=$(pr_state "$br" "$pr")
    case "$st" in
      MERGED)
        cmd_agent done "$id" >/dev/null
        printf 'SKIP %s #%s — already merged, not resumed\n' "$id" "$tk" ;;
      OPEN*)
        edit "$WF" '.agents |= map(if .id == $id then .state = "resuming" else . end)' --arg id "$id"
        printf 'RESUME %s #%s — PR #%s is open: finish it (%s, %s)\n' "$id" "$tk" "${st#OPEN }" "${br:-?}" "${wt:-no worktree}" ;;
      *)
        edit "$WF" '.agents |= map(if .id == $id then .state = "resuming" else . end)' --arg id "$id"
        ahead="?"; dirty="?"
        if [ -n "$wt" ] && [ -d "$wt" ]; then
          ahead=$(git -C "$wt" rev-list --count "@{upstream}..HEAD" 2>/dev/null || git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo "?")
          dirty=$(git -C "$wt" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
        fi
        t=$(transcript_of "$id" || true)
        printf 'RESUME %s #%s — continue in %s on %s: %s unpushed commits, %s changed files%s%s\n' \
          "$id" "$tk" "${wt:-?}" "${br:-?}" "$ahead" "$dirty" \
          "${t:+; transcript $t}" "${t:+; last words: $(last_words "$t")}" ;;
    esac
  done < <(jq -r '.agents[] | select(.state == "cut") | [.id,.ticket,.kind,.branch,.worktree,.pr] | @tsv' "$WF")
}

# Every live window's state file on this machine, this one included, concatenated.
live_windows() {
  local f w
  for f in "$NSD"/w-*.json; do
    [ -f "$f" ] || continue
    w=${f##*/w-}; w=${w%.json}
    [ "$f" = "$WF" ] || claim_pid_alive "$w" || continue
    cat "$f"; echo
  done
}

# ---- the area ------------------------------------------------------------------
# One issue call and one PR call, cached a minute: the Stop hook asks on every turn end.
cmd_area() {
  local area; area=$(jq -r '.area // ""' "$WF" 2>/dev/null)
  [ -n "$area" ] || { echo "nonstop: this window has no area — run start first" >&2; return 1; }
  # Per window: which red PRs are "taken" depends on who is asking.
  local cache="$NSD/area-$(printf '%s' "$area" | tr -c 'A-Za-z0-9' _)-$WINDOW.txt" age
  if [ -f "$cache" ] && [ -z "${NONSTOP_NO_CACHE:-}" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || stat -f %m "$cache" 2>/dev/null || echo 0) ))
    [ "$age" -lt "${NONSTOP_AREA_TTL:-60}" ] && { cat "$cache"; return 0; }
  fi
  local issues prs locks skip
  issues=$(gh issue list --repo "$REPO" --label "$area" --state open --limit 500 --json number,labels 2>/dev/null) \
    || { echo "nonstop: cannot read the area's tickets" >&2; return 1; }
  prs=$(gh pr list --repo "$REPO" --state open --limit 200 --json number,headRefName,isDraft,mergeable,statusCheckRollup 2>/dev/null || echo '[]')
  locks=$(bash "$_NS_HOME/fix-lock.sh" list --json 2>/dev/null || echo '[]')
  # What an agent in any live window is already on: never a second agent on it.
  local busy
  busy=$(live_windows | jq -cs '[.[].agents[]? | select(.state=="running" or .state=="resuming")]
           | {tickets: map(.ticket | tonumber? // empty), prs: map(.pr | tonumber? // empty),
              branches: map(.branch | select(. != ""))}' 2>/dev/null)
  [ -n "$busy" ] || busy='{"tickets":[],"prs":[],"branches":[]}'
  skip='[]'
  [ -f "$SD/.auto-skip" ] && skip=$(cut -f1 "$SD/.auto-skip" | jq -R 'tonumber? // empty' | jq -cs . 2>/dev/null)
  [ -n "$skip" ] || skip='[]'
  jq -rn --argjson i "$issues" --argjson p "$prs" --argjson l "$locks" --argjson skip "${skip:-[]}" --argjson busy "$busy" \
     --arg r "$L_READY" --arg g "$L_GATED" --arg d "$L_DRAFT" --arg h "$L_HOLD" --arg pre "$PREFIX" '
    def has($x): [.labels[].name] | index($x) != null;
    ($i | map(.number)) as $nums
    | ($i | map(select(has($r)) | .number) - $skip - $busy.tickets) as $ready
    | ($i | map(select((has($g) or has($d)) and (has($h) | not)) | .number) - $skip) as $pm
    | [ $p[] | . as $pr
        | ($nums | map(. as $n | select($pr.headRefName | test("(^|/)(" + $pre + ")?" + ($n | tostring) + "([-/]|$)")))) as $m
        | select(($m | length) > 0)
        | select(([.statusCheckRollup[]? | (.conclusion // .state // "")] | map(select(test("FAILURE|ERROR|TIMED_OUT|STARTUP_FAILURE"))) | length) > 0
                 or .mergeable == "CONFLICTING")
        | .number ] as $red
    | ([ $p[] | select(.headRefName as $h | $busy.branches | index($h)) | .number ]) as $building
    | ($l | map(select((.mine | not) and (.expired | not)) | .pr) + $busy.prs + $building) as $taken
    | ($red - $taken) as $fixable
    | "ready=\($ready|length) pm=\($pm|length) red=\($red|length) fixable=\($fixable|length)",
      "ready: \($ready[:6] | map("#"+tostring) | join(" "))",
      "pm: \($pm[:6] | map("#"+tostring) | join(" "))",
      "fixable: \($fixable[:6] | map("PR #"+tostring) | join(" "))"' > "$cache.tmp" \
    && mv "$cache.tmp" "$cache" && cat "$cache"
}
count() { sed -n "1s/.*$1=\([0-9]*\).*/\1/p" <<<"$2"; }

# Agents running in every live window on this machine, this one included.
running_all() {
  live_windows | jq -s '[.[].agents[]? | select(.state=="running" or .state=="resuming")] | length' 2>/dev/null || echo 0
}

# ---- the loop ------------------------------------------------------------------
cmd_start() {
  local area="${1:?start <area-label>}"
  edit "$WF" '.area = $a | .window = $w | .started = $t | .stopped = ""' --arg a "$area" --arg w "$WINDOW" --argjson t "$(now)"
  # The keep-working hook's loop marker and the stand-up's scope, as /work writes them.
  printf '%s\t%s\n' "$area" "$(date +%Y-%m-%dT%H:%M:%S%z)" > "$SD/.session-label"
  printf '%s\n' "$WINDOW" > "$SD/.session-label.owner"
  touch "$SD/.loop-active"
  echo "nonstop armed on $area (window $WINDOW)"
}

cmd_stop() {
  local why="${1:-stopped}"
  edit "$WF" '.stopped = $r' --arg r "$why" || true
  printf '%s\n' "$why" > "$SD/.stop-reason"
  printf 'Stopped: %s\n' "$why"
}

cmd_wake() {
  [ -f "$WF" ] || { echo "NEXT: START — no loop in this window; run: nonstop.sh start <area>"; return 0; }
  local area; area=$(jq -r '.area' "$WF")
  [ "$(jq -r '.stopped // ""' "$WF")" = "" ] || { echo "NEXT: STOPPED — $(jq -r .stopped "$WF")"; return 0; }
  adopt_dead; scan
  local h=""; h=$(cmd_hold) || h=""
  local run ncut free a res
  run=$(jq '[.agents[] | select(.state=="running" or .state=="resuming")] | length' "$WF")
  ncut=$(jq '[.agents[] | select(.state=="cut")] | length' "$WF")
  free=$(( MAX - $(running_all) - ncut )); [ "$free" -lt 0 ] && free=0
  echo "nonstop · $area · window $WINDOW"
  echo "hold: ${h:-none}"
  echo "agents: $run running, $ncut cut off; $free of $MAX machine places free"
  cmd_agents
  if [ -n "$h" ]; then
    echo "NEXT: HOLD — end the turn; the next tick after $(clock "$(cut -f1 "$HOLD_F")") resumes the cut-off agents"; return 0
  fi
  if [ "$ncut" -gt 0 ]; then res=$(cmd_resume); printf '%s\n' "$res"
    grep -q '^RESUME' <<<"$res" && { echo "NEXT: RESUME — start one agent per RESUME line with its brief, then agent add/done"; return 0; }
  fi
  a=$(cmd_area) || { echo "NEXT: WAIT — the area could not be read; end the turn"; return 0; }
  printf '%s\n' "$a"
  local ready pm fixable
  ready=$(count ready "$a"); pm=$(count pm "$a"); fixable=$(count fixable "$a")
  if [ "$free" -gt 0 ] && [ "${fixable:-0}" -gt 0 ]; then
    echo "NEXT: FIX — $(sed -n 's/^fixable: //p' <<<"$a" | cut -d' ' -f1-2): fix-lock.sh acquire it, then one agent fixes it"
  elif [ "$free" -gt 0 ] && [ "${ready:-0}" -gt 0 ]; then
    echo "NEXT: CLAIM — $free place(s) free, $ready ready; one agent per ticket via /agent-harness:claim"
  elif [ "$free" -gt 0 ] && [ "${pm:-0}" -gt 0 ]; then
    echo "NEXT: PM — spec, draw or flip one of: $(sed -n 's/^pm: //p' <<<"$a")"
  elif [ "$run" -gt 0 ]; then
    echo "NEXT: WAIT — $run agent(s) and watchers running; end the turn, their notifications wake you"
  else
    echo "NEXT: FINISHED — nothing ready, drafting or fixable, nothing in flight: run nonstop.sh stop \"area finished\""
  fi
}

cmd_should_continue() {
  armed || return 0
  cmd_hold >/dev/null && return 0
  scan
  local run ncut free a ready pm fixable
  run=$(jq '[.agents[] | select(.state=="running" or .state=="resuming")] | length' "$WF")
  ncut=$(jq '[.agents[] | select(.state=="cut")] | length' "$WF")
  [ "$ncut" -gt 0 ] && { echo "$ncut agent(s) were cut off by the usage limit and the limit has reset: run nonstop.sh wake and resume them"; return 2; }
  free=$(( MAX - $(running_all) )); [ "$free" -gt 0 ] || return 0
  a=$(cmd_area 2>/dev/null) || return 0
  ready=$(count ready "$a"); pm=$(count pm "$a"); fixable=$(count fixable "$a")
  [ $(( ${ready:-0} + ${pm:-0} + ${fixable:-0} )) -gt 0 ] || return 0
  echo "$free agent place(s) free while $(jq -r .area "$WF") has ready=${ready:-0} fixable=${fixable:-0} pm=${pm:-0}: run nonstop.sh wake and act on its NEXT line"
  return 2
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  wake) cmd_wake ;;
  agent) shift; cmd_agent "$@" ;;
  agents) cmd_agents ;;
  resume) cmd_resume ;;
  hold) cmd_hold ;;
  hold-set) shift; cmd_hold_set "$@" ;;
  reset-epoch) shift; t="${1:-}"; [ -n "$t" ] || t=$(cat); reset_epoch "$t" ;;
  area) cmd_area ;;
  should-continue) cmd_should_continue ;;
  window) echo "$WINDOW" ;;
  *) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
