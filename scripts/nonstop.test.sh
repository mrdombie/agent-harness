#!/usr/bin/env bash
# nonstop.sh — a window that works one area until it is finished.
#
# Cases: the usage-limit reset is read exactly; a hold blocks and lifts; two
# windows keep their own agents; an agent whose transcript ends on a 429 is cut
# off; after the reset a cut-off agent is resumed from its worktree, or skipped
# when its work already merged — and only once; a dead window's agents are
# adopted by one live window, not two; NEXT names the right action; the
# keep-working hook nags only with a free place and runnable work; the two new
# hooks do their one job. Then each guard is killed in a copy and the cases that
# stand on it must go red.
#
# Nothing touches the network: gh is a stub reading planted JSON, and "origin" is
# a bare repo in a temp dir.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SB=$(mktemp -d "${TMPDIR:-/tmp}/nonstop-XXXXXX")
PIDS=""
trap 'for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$SB"' EXIT
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
unset CLAIM_RUN_ID NONSTOP_WINDOW FIX_LOCK_WINDOW FIX_LOCK_PID HARNESS_CFG_PATH
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@test.local
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@test.local
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }

# ---- sandbox -----------------------------------------------------------------
git init -q --bare -b main "$SB/origin.git"
git clone -q "$SB/origin.git" "$SB/work" 2>/dev/null
git -C "$SB/work" commit -q --allow-empty -m init && git -C "$SB/work" push -q origin main
mkdir -p "$SB/bin" "$SB/gh" "$SB/projects/p/s/subagents"
export HARNESS_STATE_DIR="$SB/state" NONSTOP_REPO_SLUG="acme/widgets" BRANCH_PREFIX="tkt-"
export LBL_READY="st:ready" LBL_GATED="st:gated" LBL_DRAFTING="st:drafting" HOLD_LABEL="hold:human"
export CLAUDE_PROJECTS_DIR="$SB/projects" FIX_LOCK_REPO="$SB/work" NONSTOP_AREA_TTL=0
mkdir -p "$HARNESS_STATE_DIR"

# gh stub: issue list → gh/issues.json · pr list --head B → gh/head-B.json ·
# pr list (open, all) → gh/prs.json · pr view N → gh/pr-N.json. Honours -q/--jq.
cat > "$SB/bin/gh" <<'SH'
#!/usr/bin/env bash
D="$GH_STUB"; q=""; head=""; state=""; f=""
args=("$@")
for ((i=0;i<${#args[@]};i++)); do case "${args[$i]}" in
  -q|--jq) q="${args[$((i+1))]}" ;; --head) head="${args[$((i+1))]}" ;; --state) state="${args[$((i+1))]}" ;; esac; done
case "$1 $2" in
  "issue list") f="$D/issues.json" ;;
  "pr view")    f="$D/pr-$3.json" ;;
  "pr list")    if [ -n "$head" ]; then f="$D/head-$head.json"; else f="$D/prs.json"; fi ;;
  *) exit 0 ;;
esac
[ -f "$f" ] || { [ "$1 $2" = "pr view" ] && exit 1; echo '[]' > /dev/null; f=/dev/null; }
j=$(cat "$f" 2>/dev/null); [ -n "$j" ] || j='[]'
[ -n "$head" ] && [ "$state" = open ] && j=$(jq -c 'map(select(.state=="OPEN"))' <<<"$j")
if [ -n "$q" ]; then jq -r "$q" <<<"$j"; else printf '%s\n' "$j"; fi
SH
chmod +x "$SB/bin/gh"
export PATH="$SB/bin:$PATH" GH_STUB="$SB/gh"

sleep 900 & W1=$!; sleep 900 & W2=$!; PIDS="$W1 $W2"; disown "$W1" "$W2" 2>/dev/null
sh -c 'exit 0' & DEAD=$!; wait "$DEAD" 2>/dev/null

NOW=1792050000                     # a fixed instant: 2026-10-15 ~08:20 in London
ns() { # <kit-scripts-dir> <window> <args…> → OUT, RC
  local k=$1 w=$2; shift 2
  RC=0; OUT=$(cd "$SB/work" && NONSTOP_NOW="${T_NOW:-$NOW}" NONSTOP_WINDOW="$w" FIX_LOCK_PID="$w" \
              FIX_LOCK_WINDOW="host:$w" bash "$k/nonstop.sh" "$@" 2>&1) || RC=$?
}
has()  { grep -qF -- "$2" <<<"$1"; }

# A 429 the way a sub-agent transcript actually ends (shape measured 2026-10-15).
limit_tail() {
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Wrote the failing test; implementing the card next."}]}}'
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"content":[{"type":"text","text":"You'"'"'ve hit your session limit · resets 2:40am (Europe/London)"}]}}'
}

plant_area() { # ready gated-or-drafting red-pr? → issues and PRs for area "area:x"
  jq -n '[{number:101,labels:[{name:"area:x"},{name:"st:ready"}]},
          {number:105,labels:[{name:"area:x"},{name:"st:ready"}]},
          {number:102,labels:[{name:"area:x"},{name:"st:gated"}]},
          {number:103,labels:[{name:"area:x"},{name:"st:gated"},{name:"hold:human"}]},
          {number:104,labels:[{name:"area:x"},{name:"st:review"}]}]' > "$SB/gh/issues.json"
  jq -n '[{number:9,headRefName:"tkt-104/fix-card",isDraft:false,mergeable:"MERGEABLE",
           statusCheckRollup:[{conclusion:"FAILURE"},{conclusion:"SUCCESS"}]},
          {number:5,headRefName:"tkt-999/other-area",isDraft:false,mergeable:"MERGEABLE",
           statusCheckRollup:[{conclusion:"FAILURE"}]}]' > "$SB/gh/prs.json"
}
plant_empty() { echo '[]' > "$SB/gh/issues.json"; echo '[]' > "$SB/gh/prs.json"; }

reset_state() { rm -rf "$HARNESS_STATE_DIR" "$SB/gh"; mkdir -p "$HARNESS_STATE_DIR" "$SB/gh"; rm -f "$SB/projects/p/s/subagents"/*
  git -C "$SB/work" push -q origin --delete refs/fixing/9 2>/dev/null || true; }

# core <kit-scripts-dir> → prints one line per failed case; empty = all hold
core() {
  local k=$1 e
  reset_state
  # -- the reset time
  ns "$k" "$W1" reset-epoch "You've hit your session limit · resets 2:40am (Europe/London)"
  e=$(TZ=Europe/London date -r "$OUT" +%H:%M 2>/dev/null || TZ=Europe/London date -d "@$OUT" +%H:%M)
  [ "$e" = "02:40" ] && [ "$OUT" -gt "$NOW" ] || echo "reset-epoch read $OUT ($e), not the next 02:40 London"
  ns "$k" "$W1" reset-epoch 'x "resetsAt":1792120000 y'; [ "$OUT" = 1792120000 ] || echo "resetsAt not taken exactly ($OUT)"
  ns "$k" "$W1" reset-epoch "You've hit your session limit"; [ "$OUT" = $((NOW + 3600)) ] || echo "a wall with no time is not held an hour ($OUT)"
  ns "$k" "$W1" reset-epoch "all fine"; [ "$RC" -ne 0 ] || echo "a message with no limit set a reset"

  # -- two windows on one area keep their own agents
  plant_area
  ns "$k" "$W1" start area:x; ns "$k" "$W2" start area:x
  ns "$k" "$W1" agent add aaa1 101 --branch tkt-101/a --worktree "$SB/work"
  ns "$k" "$W2" agents; has "$OUT" aaa1 && echo "window 2 lists window 1's agent"
  ns "$k" "$W1" agents; has "$OUT" aaa1 || echo "window 1 lost its own agent"

  # -- a red PR window 2 is fixing is not window 1's to fix
  ns "$k" "$W1" wake; has "$OUT" "NEXT: FIX — PR #9" || echo "a red PR in the area is not the next move (got: $(tail -1 <<<"$OUT"))"
  has "$OUT" "PR #5" && echo "a red PR from another area counted as this one's"
  ( cd "$SB/work" && FIX_LOCK_REPO="$SB/work" FIX_LOCK_PID="$W2" FIX_LOCK_WINDOW="host:$W2" bash "$k/fix-lock.sh" acquire 9 >/dev/null 2>&1 )
  ns "$k" "$W1" wake; has "$OUT" "NEXT: FIX" && echo "window 1 was sent to the PR window 2 is fixing"
  has "$OUT" "NEXT: CLAIM" || echo "with the PR taken and a ticket ready, the next move is not CLAIM ($(tail -1 <<<"$OUT"))"
  ns "$k" "$W2" wake; has "$OUT" "NEXT: FIX — PR #9" || echo "the window holding the fix lost sight of its own PR"
  has "$OUT" "#101" && echo "a ticket an agent already holds is offered again"
  ns "$k" "$W2" agent add fx9 104 --kind fix --pr 9
  ns "$k" "$W2" wake; has "$OUT" "NEXT: FIX" && echo "a PR an agent is already fixing is sent to a second fixer"
  ns "$k" "$W2" agent done fx9

  # -- an agent that died on the usage wall
  limit_tail > "$SB/projects/p/s/subagents/agent-aaa1.jsonl"
  ns "$k" "$W1" wake
  has "$OUT" "NEXT: HOLD" || echo "a 429 in the transcript did not hold the window ($(tail -1 <<<"$OUT"))"
  has "$OUT" "1 cut off" || echo "the agent cut off by the wall is not marked"
  ns "$k" "$W2" hold; [ "$RC" -eq 0 ] || echo "the hold is not shared with the other window"
  ns "$k" "$W1" should-continue; [ "$RC" -eq 0 ] || echo "the Stop hook would nag during the hold"

  # -- after the reset: resume once, never what already merged
  ns "$k" "$W1" agent add aaa2 102 --branch tkt-102/b
  ns "$k" "$W1" agent cut aaa2
  mkdir -p "$SB/gh/head-tkt-102"; echo '[{"number":77,"state":"MERGED"}]' > "$SB/gh/head-tkt-102/b.json"
  T_NOW=1792200000 ns "$k" "$W1" wake
  has "$OUT" "SKIP aaa2 #102 — already merged" || echo "merged work was not skipped"
  has "$OUT" "RESUME aaa2" && echo "merged work was resumed"
  has "$OUT" "RESUME aaa1 #101 — continue in $SB/work on tkt-101/a" || echo "the cut-off agent has no resume brief"
  has "$OUT" "last words: Wrote the failing test" || echo "the brief does not carry where the agent stopped"
  has "$OUT" "NEXT: RESUME" || echo "NEXT is not RESUME after the reset"
  T_NOW=1792200000 ns "$k" "$W1" wake
  has "$OUT" "RESUME aaa1" && echo "the same agent was resumed twice"

  # -- a dead window's agents go to exactly one live window
  printf '{"area":"area:x","window":"%s","stopped":"","agents":[{"id":"ddd1","ticket":"101","kind":"build","branch":"tkt-101/d","worktree":"","pr":"","state":"running","at":1}]}' "$DEAD" \
    > "$HARNESS_STATE_DIR/nonstop/w-$DEAD.json"
  T_NOW=1792200000 ns "$k" "$W2" wake; has "$OUT" "RESUME ddd1" || echo "a dead window's agent was not adopted"
  T_NOW=1792200000 ns "$k" "$W1" wake; has "$OUT" "ddd1" && echo "a dead window's agent was adopted twice"

  # -- slots full: wait, and the Stop hook stays quiet
  ns "$k" "$W2" agent add b1 101; ns "$k" "$W2" agent add b2 101; ns "$k" "$W2" agent add b3 101
  T_NOW=1792200000 ns "$k" "$W2" wake; has "$OUT" "NEXT: WAIT" || echo "with every place taken the next move is not WAIT ($(tail -1 <<<"$OUT"))"
  T_NOW=1792200000 ns "$k" "$W2" should-continue; [ "$RC" -eq 0 ] || echo "the Stop hook would nag a window whose places are all taken"
  # The places are the machine's: window 1 runs one agent, but window 2's fill the rest.
  T_NOW=1792200000 ns "$k" "$W1" wake; has "$OUT" "NEXT: CLAIM" && echo "two windows together ran past the machine's agent limit"
  # -- a free place and ready work: the Stop hook nags
  for a in b1 b2 b3 ddd1; do ns "$k" "$W2" agent done "$a"; done
  T_NOW=1792200000 ns "$k" "$W2" should-continue; [ "$RC" -eq 2 ] || echo "a free place with ready work does not nag (rc $RC)"

  # -- finished only when nothing is ready, drafting, fixable or in flight
  plant_empty
  for a in aaa1 aaa2; do ns "$k" "$W1" agent done "$a"; done
  T_NOW=1792200000 ns "$k" "$W1" wake; has "$OUT" "NEXT: FINISHED" || echo "an empty area is not FINISHED ($(tail -1 <<<"$OUT"))"
  ns "$k" "$W1" agent add w1 104 --kind watch --pr 9
  T_NOW=1792200000 ns "$k" "$W1" wake; has "$OUT" "NEXT: FINISHED" && echo "FINISHED while a watcher it owns is in flight"
  ns "$k" "$W1" stop "area finished"; [ "$OUT" = "Stopped: area finished" ] || echo "stop does not say 'Stopped: area finished' ($OUT)"
  T_NOW=1792200000 ns "$k" "$W1" should-continue; [ "$RC" -eq 0 ] || echo "a stopped window still nags"
}

echo "nonstop: the loop's state"
if [ "${NONSTOP_TEST_ONLY:-}" = hooks ]; then R=""; else R=$(core "$HERE"); fi
[ -z "$R" ] && ok "every case holds on the shipped script" || { bad "cases failed on the shipped script:"; printf '         %s\n' "$R"; }

# ---- the hooks -----------------------------------------------------------------
echo "hooks"
reset_state
jq -nc '{hook_event_name:"StopFailure",error:"rate_limit",error_details:"You have hit your session limit · resets 2:40am (Europe/London)"}' \
  | NONSTOP_NOW=$NOW bash "$KIT/hooks/usage-limit.sh"
[ -s "$HARNESS_STATE_DIR/nonstop/usage-hold" ] && ok "StopFailure on rate_limit records the reset" || bad "StopFailure on rate_limit recorded nothing"
reset_state
jq -nc '{hook_event_name:"StopFailure",error:"authentication_failed",error_details:"bad token"}' | bash "$KIT/hooks/usage-limit.sh"
[ -e "$HARNESS_STATE_DIR/nonstop/usage-hold" ] && bad "an auth failure was read as a usage wall" || ok "other API errors hold nothing"

reset_state; plant_area
ns "$HERE" "$W1" start area:x
ctx=$(jq -nc '{source:"compact"}' | NONSTOP_WINDOW="$W1" FIX_LOCK_PID="$W1" FIX_LOCK_WINDOW="host:$W1" bash "$KIT/hooks/nonstop-resume.sh")
has "$ctx" "additionalContext" && has "$ctx" "area:x" && ok "after compaction the window gets its area and NEXT back" || bad "compaction context missing ($ctx)"
ctx=$(jq -nc '{source:"startup"}' | NONSTOP_WINDOW="$W1" bash "$KIT/hooks/nonstop-resume.sh")
[ -z "$ctx" ] && ok "a fresh start is left alone" || bad "a fresh start was given loop context"

kw() { # <window> → rc of keep-working.sh for a fresh session
  jq -nc --arg s "kw-$RANDOM$RANDOM" '{session_id:$s,stop_hook_active:false,last_assistant_message:"ok"}' \
    | NONSTOP_WINDOW="$1" FIX_LOCK_PID="$1" FIX_LOCK_WINDOW="host:$1" CLAUDE_SESSION_PID_OVERRIDE="$1" HARNESS_REPO_SLUG=acme/widgets bash "$KIT/hooks/keep-working.sh" >/dev/null 2>&1
}
kw "$W1"; [ $? -eq 2 ] && ok "keep-working nags a non-stop window with a free place and ready work" || bad "keep-working is quiet with a free place and ready work"
for i in 1 2 3 4; do ns "$HERE" "$W1" agent add "f$i" 101; done
kw "$W1"; [ $? -eq 0 ] && ok "keep-working leaves a full window to wait on its agents" || bad "keep-working nags a window whose places are all taken"
kw "$W2"; [ $? -eq 0 ] && ok "keep-working does not drive the window beside it" || bad "keep-working nagged a window with no loop of its own"

# A non-stop window paced by a cron has no ScheduleWakeup in its transcript; it is
# still a loop, so a reply without the status block goes back.
echo '{"type":"user"}' > "$SB/transcript.jsonl"
hb() { # <kit> <window> → rc of heartbeat.sh on a reply with no status block
  jq -nc --arg t "$SB/transcript.jsonl" '{stop_hook_active:false,last_assistant_message:"Started the next ticket.",transcript_path:$t}' \
    | NONSTOP_WINDOW="$2" bash "$1/hooks/heartbeat.sh" >/dev/null 2>&1
}
hb "$KIT" "$W1"; [ $? -eq 2 ] && ok "heartbeat holds a non-stop window to its status block" || bad "heartbeat let a non-stop window reply without its status block"
hb "$KIT" "$W2"; [ $? -eq 0 ] && ok "heartbeat leaves a window with no loop alone" || bad "heartbeat demanded a status block from a window with no loop"

# ---- hook plants: kill the new line in a copy of the kit, the case must go red --
hplant() { # <desc> <file> <old> <new> <check: a command that must now FAIL>
  local d="$SB/hkit"; rm -rf "$d"; mkdir -p "$d"; cp -R "$KIT/hooks" "$KIT/scripts" "$KIT/swarm" "$d/"
  python3 - "$d/$2" "$3" "$4" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  grep -qF -- "$4" "$d/$2" || { bad "plant did not land: $1"; return; }
  if eval "$5"; then bad "planted: $1 → still green (the guard is decorative)"; else ok "planted: $1 → red"; fi
}
usage_case() { reset_state; jq -nc '{error:"rate_limit",error_details:"hit your session limit · resets 2:40am (Europe/London)"}' \
  | NONSTOP_NOW=$NOW bash "$1/hooks/usage-limit.sh"; [ -s "$HARNESS_STATE_DIR/nonstop/usage-hold" ]; }
kw_full_case() { reset_state; plant_area; ns "$1/scripts" "$W1" start area:x
  for i in 1 2 3 4; do ns "$1/scripts" "$W1" agent add "f$i" 101; done
  jq -nc --arg s "kw-$RANDOM$RANDOM" '{session_id:$s,stop_hook_active:false}' \
    | NONSTOP_WINDOW="$W1" FIX_LOCK_PID="$W1" FIX_LOCK_WINDOW="host:$W1" CLAUDE_SESSION_PID_OVERRIDE="$W1" \
      HARNESS_REPO_SLUG=acme/widgets bash "$1/hooks/keep-working.sh" >/dev/null 2>&1; }
resume_case() { reset_state; plant_area; ns "$1/scripts" "$W1" start area:x
  jq -nc '{source:"compact"}' | NONSTOP_WINDOW="$W1" FIX_LOCK_PID="$W1" FIX_LOCK_WINDOW="host:$W1" bash "$1/hooks/nonstop-resume.sh" | grep -q area:x; }
hb_case() { reset_state; ns "$1/scripts" "$W1" start area:x; hb "$1" "$W1"; [ $? -eq 2 ]; }
echo "hook plants"
for c in usage_case kw_full_case resume_case hb_case; do
  "$c" "$KIT" && ok "$c passes unplanted" || bad "$c fails unplanted"
done
hplant "StopFailure records nothing" hooks/usage-limit.sh \
  'OUT=$(bash "$(dirname "$0")/../scripts/nonstop.sh" hold-set "$TEXT" 2>&1)' 'OUT=""' 'usage_case "$d"'
hplant "keep-working nags a window whose places are all taken" hooks/keep-working.sh \
  '[ "$NSRC" -eq 2 ] || { say "exit0 nonstop-nothing-to-take $SID"; exit 0; }' ':' 'kw_full_case "$d"'
hplant "compaction gets no loop context" hooks/nonstop-resume.sh \
  'case "$SRC" in compact|resume) ;; *) exit 0 ;; esac' 'exit 0' 'resume_case "$d"'
hplant "a cron-paced non-stop window is not seen as a loop" hooks/heartbeat.sh \
  'if [ -n "$NSW" ] && [ -f "$NSF" ]' 'if false' 'hb_case "$d"'

# ---- the plants -------------------------------------------------------------------
plant() { # <desc> <old> <new> <the case that must go red>
  local d="$SB/kit"; rm -rf "$d"; mkdir -p "$d/scripts" "$d/hooks/lib" "$d/swarm"
  cp "$HERE"/*.sh "$d/scripts/"; cp "$KIT/hooks/lib/"*.sh "$d/hooks/lib/"; cp "$KIT/swarm/"*.sh "$d/swarm/" 2>/dev/null
  python3 - "$d/scripts/nonstop.sh" "$2" "$3" <<'PY' || { bad "plant did not land: $1"; return; }
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
if s.count(a) != 1: sys.exit(1)
open(p, "w").write(s.replace(a, b))
PY
  grep -qF -- "$3" "$d/scripts/nonstop.sh" || { bad "plant did not land: $1"; return; }
  local r; r=$(core "$d/scripts" 2>/dev/null)
  if grep -qF -- "$4" <<<"$r"; then ok "planted: $1 → red: $4"
  elif [ -n "$r" ]; then bad "planted: $1 → red, but not on its own case ($4): $(head -1 <<<"$r")"
  else bad "planted: $1 → still green (the guard is decorative)"; fi
}
[ "${NONSTOP_TEST_ONLY:-}" = hooks ] && exit $fail
echo "plants"
plant "a transcript ending on a 429 is not read" \
  "grep -qE '\"apiErrorStatus\":429|hit your (session|weekly|usage)[a-z ]* limit'" "grep -qE 'NEVER-MATCHES'" \
  'a 429 in the transcript did not hold the window'
plant "merged work is resumed anyway" '[ "${s:-0}" -gt 0 ] 2>/dev/null && { echo MERGED; return; }' ':' \
  'merged work was resumed'
plant "a resumed agent is never marked, so it resumes again" \
  "      *)
        edit \"\$WF\" '.agents |= map(if .id == \$id then .state = \"resuming\" else . end)' --arg id \"\$id\"" \
  "      *)
        :" \
  'the same agent was resumed twice'
plant "another window's fix lock is ignored" '| ($red - $taken) as $fixable' '| $red as $fixable' \
  'window 1 was sent to the PR window 2 is fixing'
plant "the hold is not read" '  if [ "$e" -gt "$(now)" ]; then' '  if false; then' \
  'a 429 in the transcript did not hold the window'
plant "a dead window is adopted by every window that looks" \
  "    jq '.agents = [] | .stopped = \"window gone\"' \"\$f\" > \"\$f.tmp\" 2>/dev/null && mv \"\$f.tmp\" \"\$f\"" ':' \
  'adopted twice'
plant "the area's red PRs are not matched to its tickets" '"(^|/)(" + $pre + ")?" + ($n | tostring) + "([-/]|$)"' '"."' \
  'a red PR from another area counted'
plant "a free place is counted while every place is taken" 'free=$(( MAX - $(running_all) - ncut ))' 'free=$MAX' \
  'with every place taken the next move is not WAIT'
plant "each window counts only its own agents against the limit" '    [ "$f" = "$WF" ] || claim_pid_alive "$w" || continue' '    [ "$f" = "$WF" ] || continue' \
  'two windows together ran past the machine'
plant "a running agent's ticket and PR are offered again" '- $skip - $busy.tickets) as $ready' '- $skip) as $ready' \
  'a ticket an agent already holds is offered again'
plant "a PR an agent is fixing is fixable again" '.pr) + $busy.prs + $building) as $taken' '.pr)) as $taken' \
  'a PR an agent is already fixing is sent to a second fixer'
plant "FINISHED ignores what the window still has in flight" '  elif [ "$run" -gt 0 ]; then' '  elif false; then' \
  'FINISHED while a watcher it owns is in flight'

exit $fail
