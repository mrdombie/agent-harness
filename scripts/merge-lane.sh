#!/usr/bin/env bash
# merge-lane.sh — one serial merge lane into the integration branch, for a repo
# without GitHub's merge queue. One pass per run, in a fresh process, with a lock.
#
#   merge-lane.sh                one pass
#   MERGE_LANE_SHADOW=0 …        act for real; anything else is shadow
#
# Each approved PR that joined used to be merged by its own auto-merge, so every
# merge moved the trunk under the next one: approved PRs clashed or went red in
# turn, and two that passed separately broke the trunk together. The lane merges
# one PR at a time, and only once it is up to date and its required checks are
# green on that exact head, so the trunk is always what was tested.
#
# A pass, in order:
#   1. lock        a pass still running means this one exits, untouched
#      label       the lane label exists, or is created (shadow: "would create")
#   2. members     open, not draft, on the trunk, no hold label, and auto-merge
#                  armed or the lane label. Live: the label goes on and auto-merge
#                  comes off, so the lane is the only thing that merges them.
#   3. order       the PR in flight stays head; then the first label (P0), then
#                  priority (the PR's own P label, else its ticket's; none last),
#                  then product before our own tooling, then the pass that first
#                  saw it approved, then the PR number — the queue's own key
#                  (COORD_TICKET_JQ), owner call 2026-10-19: priority decides everywhere
#   4. the head    hold put back after the lane's update  → re-cleared only when
#                                 every commit since approval is a merge and the
#                                 update touched none of its screen files; else the
#                                 owner is told
#                  conflicting, or the update hits a conflict → out, fixer
#                  behind the trunk                      → update-branch, wait —
#                                 unless merge.updateBehind is bot and GitHub does
#                                 not call it BEHIND (up to date is not required):
#                                 then behind is no reason to wait
#                  a required check pending or missing   → wait
#                  a required check red: a flake         → re-run once
#                                        anything else   → out, check named, fixer
#                  every required check green            → merge, end of pass
#                  a wait on anything but its own checks a second pass running
#                                 (unreadable, refused) → it gives up its place
#                                 and goes behind every other member
#
# Project facts, refused by key name when missing: merge.method, gates.requiredChecks.
# Optional: mergeLane.label (queue:merge), mergeLane.firstLabel (P0),
# mergeLane.flakePattern, design.surfacePaths (which files are screens),
# merge.updateBehind (agent; bot = the trunk does not require up to date).
#
# Shadow (the default): every act is written to actions.log as "would …"; nothing
# is merged, updated, labelled, re-run, spawned or notified.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1
. "$SELF_DIR/pr-red.sh" || exit 1
declare -F issue_status_set >/dev/null || . "$SELF_DIR/issue-status.sh" || exit 1
. "$SELF_DIR/repair-gate.sh" || exit 1

LANE_SHADOW="${MERGE_LANE_SHADOW:-1}"
lane_shadow() { [ "$LANE_SHADOW" != 0 ]; }
lane_mode()   { if lane_shadow; then printf would; else printf did; fi; }

METHOD=$(toolkit_cfg merge.method) || exit 1
case "$METHOD" in merge|squash|rebase) ;;
  *) echo "merge-lane: harness.json merge.method is '$METHOD' — expected merge, squash or rebase." >&2; exit 1 ;;
esac
# Names may hold spaces, so they stay JSON rather than a space-joined toolkit_cfg list.
REQUIRED=$(jq -c '.gates.requiredChecks // empty | select(type == "array" and length > 0)' "$HARNESS_CFG" 2>/dev/null)
[ -n "$REQUIRED" ] || { echo "merge-lane: harness.json has no 'gates.requiredChecks' — without them green cannot be told from unchecked." >&2; exit 1; }
# A check that warns until the release (release.nonBlockingChecks) is not waited on.
REQUIRED=$(release_blocking_required "$REQUIRED")
LANE_LABEL=$(swarm_opt mergeLane.label "queue:merge")
UPDATE_BEHIND=$(swarm_opt merge.updateBehind agent)
FIRST_LABEL=$(swarm_opt mergeLane.firstLabel "P0")
FLAKE_RE=$(swarm_opt mergeLane.flakePattern 'shutdown signal|lost communication with the server|runner .*(lost|did not respond|offline)|exit code 137|exit code 143|The operation was canceled|exceeded the maximum execution time')
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
CLEAR_HOLD="$SELF_DIR/clear-hold.sh"
KEPT="$SELF_DIR/approval-kept.sh"

STATE_FILE="$COORD_DIR/lane.$(lane_mode).json"
STATUS_FILE="$COORD_DIR/lane.status"
LANE_LOG="$COORD_DIR/lane.log"
touch "$COORD_ACTIONS"

say() { printf '%s\n' "$*"; swarm_log "$LANE_LOG" "$*"; }
status() { printf 'lane (%s, %s): %s\n' "$(lane_mode)" "$(swarm_stamp)" "$*" > "$STATUS_FILE"; }

# ---- 1. lock ----------------------------------------------------------------
LOCK="$COORD_DIR/lane.lock"
coord_lock "$LOCK" lane || { say "lane: $COORD_LOCK_WHY — exiting"; exit 0; }
trap 'rm -rf "$LOCK"' EXIT

if held=$(swarm_held); then
  say "lane: held — $held"; status "held — $held"; exit 0
fi

# ---- state -------------------------------------------------------------------
# head: the PR in flight. members: {seen, approved sha, updated by the lane}.
# out: the head SHA each PR left on, so the same head is never re-admitted.
# reruns: per PR, the SHA and the job ids re-run once per check.
ST=$(jq -c 'if type == "object" then . else {} end' "$STATE_FILE" 2>/dev/null) || ST=""
[ -n "$ST" ] || ST='{}'
ST=$(jq -c '{head: (.head // null), members: (.members // {}), out: (.out // {}),
             reruns: (.reruns // {}), acts: (.acts // {}), order: (.order // [])}' <<<"$ST")
st() { ST=$(jq -c "$@" <<<"$ST"); }
save() { local tmp; tmp=$(mktemp "$COORD_DIR/.lane.XXXXXX") && printf '%s\n' "$ST" > "$tmp" && mv "$tmp" "$STATE_FILE"; }
trap 'save; rm -rf "$LOCK"' EXIT

# One line per act; a repeat of the last act on that PR's head is not written again.
act() { # <verb> <pr> <sha> [detail]
  local key="$1:$3"
  [ "$(jq -r --arg p "$2" '.acts[$p] // ""' <<<"$ST")" = "$key" ] && return 0
  st --arg p "$2" --arg k "$key" '.acts[$p] = $k'
  printf '%s\t%s\t%s\t%s\t%s\n' "$(swarm_stamp)" "$(lane_mode)" "$1" "$2" "${4:-}" >> "$COORD_ACTIONS"
}

# Agent work, by class: a PR the lane put back on hold reaches the owner in the
# tick's sign-off batch once it is green again; it is not a decision on its own.
owner() { # <key> <line> — notify follows the lane's mode, not the coordinator's
  COORDINATOR_SHADOW=$(lane_shadow && echo 1 || echo 0) bash "$NOTIFY" --class agent "$1" "$2" >/dev/null 2>&1 || true
}

# ---- 1b. the lane label --------------------------------------------------------
# A label the repo lacks cannot be added, so every PR would stay on its own auto-merge.
LABELS=$(swarm_gh label list --repo "$REPO_SLUG" --search "$LANE_LABEL" --json name --limit 100 2>/dev/null)
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$LABELS"; then
  say "lane: could not read whether the label $LANE_LABEL exists — carrying on"
elif ! jq -e --arg l "$LANE_LABEL" 'any(.[]; .name == $l)' >/dev/null <<<"$LABELS"; then
  act label-create - - "$LANE_LABEL is missing from $REPO_SLUG"
  if lane_shadow; then
    say "would create the lane label $LANE_LABEL — it is missing from $REPO_SLUG"
  elif swarm_gh label create "$LANE_LABEL" --repo "$REPO_SLUG" --color 0e8a16 \
         --description "In the merge lane: merged one at a time by the coordinator, auto-merge off" >/dev/null 2>&1; then
    say "lane: created the lane label $LANE_LABEL — it was missing from $REPO_SLUG"
  else
    say "lane: the lane label $LANE_LABEL is missing and could not be created — no PR can join this pass"
  fi
fi

# ---- the open pull requests --------------------------------------------------
# Paged: one request for every open PR with its checks times out once the repo has ~80.
PRS=$(gh_prs_paged number,title,headRefName,headRefOid,isDraft,baseRefName,labels,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup \
        "$INTEGRATION_BRANCH" 2>/dev/null)
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$PRS"; then
  say "lane: the open pull requests could not be read — doing nothing"
  status "blind — the open pull requests could not be read"; exit 0
fi
pr_json() { jq -c --argjson n "$1" '.[] | select(.number == $n)' <<<"$PRS"; }
pr_field() { jq -r --argjson n "$1" ".[] | select(.number == \$n) | $2" <<<"$PRS"; }
has_label() { jq -e --argjson n "$1" --arg l "$2" '.[] | select(.number == $n) | any(.labels[]?; .name == $l)' >/dev/null 2>&1 <<<"$PRS"; }

# ---- 2. members --------------------------------------------------------------
NOW=$(swarm_now)
# A new head is a new PR as far as the out list goes.
ST=$(jq_slurp prs "$PRS" -- jq -c '$prs[0] as $prs | .out |= with_entries(.key as $k | .value as $v | select(any($prs[]; (.number|tostring) == $k and .headRefOid == $v)))' <<<"$ST")
# A PERSON'S do-not-merge STOPS THE LANE: never a member, and its auto-merge comes off.
DNM_LABEL="${LBL_DO_NOT_MERGE:-do-not-merge}"
for n in $(jq -r --arg d "$DNM_LABEL" '.[] | select(any(.labels[]?; .name == $d)) | select(.autoMergeRequest != null) | .number' <<<"$PRS"); do
  if lane_shadow; then
    act disarm "$n" "$(pr_field "$n" .headRefOid)" "auto-merge off: $DNM_LABEL is on"
  else
    swarm_gh pr merge "$n" --repo "$REPO_SLUG" --disable-auto >/dev/null 2>&1 \
      && act disarm "$n" "$(pr_field "$n" .headRefOid)" "auto-merge off: $DNM_LABEL is on" \
      || say "lane: could not disarm auto-merge on #$n, which carries $DNM_LABEL"
  fi
done
CANDS=$(jq_slurp out "$(jq -c .out <<<"$ST")" -- jq -c --arg trunk "$INTEGRATION_BRANCH" --arg hold "$HOLD_LABEL" --arg lane "$LANE_LABEL" --arg dnm "$DNM_LABEL" '
  $out[0] as $out
  | [ .[] | select(.isDraft | not) | select(.baseRefName == $trunk)
    | select(any(.labels[]?; .name == $hold) | not)
    | select(any(.labels[]?; .name == $dnm) | not)
    | select(.autoMergeRequest != null or any(.labels[]?; .name == $lane))
    | select($out[(.number|tostring)] != .headRefOid)
    | {n: .number, sha: .headRefOid} ]' <<<"$PRS")
HEAD_PR=$(jq -r '.head.pr // empty' <<<"$ST")
ST=$(jq_slurp c "$CANDS" -- jq -c --argjson now "$NOW" --arg head "$HEAD_PR" '
  $c[0] as $c
  | .members |= with_entries(.key as $k | select($k == $head or any($c[]; (.n|tostring) == $k)))
  | reduce $c[] as $x (.; (.members[($x.n|tostring)]) as $m
      | if $m == null then .members[($x.n|tostring)] = {seen: $now, approved: $x.sha, updated: false}
        elif ($m.updated | not) then .members[($x.n|tostring)].approved = $x.sha
        else . end)' <<<"$ST")

# The lane does the merge: label first, so a disarmed PR never drops out of it.
for n in $(jq -r '.[].n' <<<"$CANDS"); do
  [ "$(pr_field "$n" '.autoMergeRequest != null')" = true ] || continue
  if lane_shadow; then
    act disarm "$n" "$(pr_field "$n" .headRefOid)" "auto-merge off, $LANE_LABEL on"
  else
    has_label "$n" "$LANE_LABEL" || swarm_gh pr edit "$n" --repo "$REPO_SLUG" --add-label "$LANE_LABEL" >/dev/null 2>&1 \
      || { say "lane: could not label #$n — leaving its auto-merge armed"; continue; }
    swarm_gh pr merge "$n" --repo "$REPO_SLUG" --disable-auto >/dev/null 2>&1 \
      && act disarm "$n" "$(pr_field "$n" .headRefOid)" "auto-merge off, $LANE_LABEL on" \
      || say "lane: could not disarm auto-merge on #$n"
  fi
done

# ---- 3. order ----------------------------------------------------------------
# A PR with no P label of its own takes its ticket's labels, in one batched read
# made only for those; a ticket that cannot be read sorts as no priority.
NEED=$(jq_slurp c "$CANDS" -- jq -r --arg pre "$BRANCH_PREFIX" "$BRANCH_TICKET_JQ"'
  $c[0] as $c
  | [ .[] | select(.number as $n | any($c[]; .n == $n))
    | select(any(.labels[]?; .name | test("^P[0-9]$")) | not)
    | (.headRefName // "" | branch_ticket($pre)) | select(. != "") ] | unique | .[]' <<<"$PRS" 2>/dev/null | tr '\n' ' ')
TICKETS="{}"
# shellcheck disable=SC2086  # a list of numbers, split on purpose
[ -z "${NEED// /}" ] || TICKETS=$(gh_issues_batch $NEED 2>/dev/null) || true
jq -e 'type == "object"' >/dev/null 2>&1 <<<"$TICKETS" || TICKETS="{}"
ORDER=$(jq_slurp c "$CANDS" prs "$PRS" tk "$TICKETS" -- coord_jq -c --arg first "$FIRST_LABEL" \
          --arg pre "$BRANCH_PREFIX" "$COORD_TICKET_JQ$BRANCH_TICKET_JQ"'
  $c[0] as $c | $prs[0] as $prs | $tk[0] as $tk
  | .head.pr as $h | .members as $m
  | [ $c[] | .n as $n
      | ([$prs[] | select(.number == $n)] | first // {}) as $p
      | [$p.labels[]?.name] as $pl
      | ($tk[($p.headRefName // "" | branch_ticket($pre))] // {}) as $t
      | (if any($pl[]; test("^P[0-9]$")) then $pl else ($pl + ($t.labels // [])) end) as $ls
      | {n: $n, h: (if $n == $h then 0 else 1 end),
         p: (if any($pl[]; . == $first) then 0 else 1 end),
         pri: coord_prin($ls; null),
         tool: (if coord_tooling($ls; ($p.title // $t.title // "")) then 1 else 0 end),
         y: (($m[($n|tostring)].yielded // {}) as $y | if $y.sha != null and $y.sha == $p.headRefOid then $y.at else 0 end),
         s: ($m[($n|tostring)].seen // 0)} ]
  | sort_by(.h, .y, .p, .pri, .tool, .s, .n) | map(.n)' <<<"$ST")
ST=$(jq_slurp o "$ORDER" -- jq -c '.order = $o[0]' <<<"$ST")

drop() { # <pr> — gone from the lane's books
  st --arg p "$1" 'del(.members[$p]) | del(.reruns[$p]) | del(.acts[$p]) | if (.head.pr|tostring) == $p then .head = null else . end'
}

if [ -n "$HEAD_PR" ] && [ -z "$(pr_json "$HEAD_PR")" ]; then
  say "lane: head #$HEAD_PR is no longer open — merged or closed elsewhere"
  drop "$HEAD_PR"; HEAD_PR=""
fi
if [ -n "$HEAD_PR" ] && has_label "$HEAD_PR" "$DNM_LABEL"; then
  say "lane: head #$HEAD_PR carries $DNM_LABEL — it leaves, and nothing merges it"
  drop "$HEAD_PR"; HEAD_PR=""
fi
if [ -n "$HEAD_PR" ] && ! has_label "$HEAD_PR" "$HOLD_LABEL" \
   && ! jq -e --argjson n "$HEAD_PR" 'any(.[]; .n == $n)' >/dev/null <<<"$CANDS"; then
  say "lane: head #$HEAD_PR is no longer a candidate (draft, or label and auto-merge both gone) — it leaves"
  drop "$HEAD_PR"; HEAD_PR=""
fi
if [ -z "$HEAD_PR" ]; then
  HEAD_PR=$(jq -r '.[0] // empty' <<<"$ORDER")
  [ -n "$HEAD_PR" ] && st --argjson n "$HEAD_PR" '.head = {pr: $n}'
fi
WAITING=$(jq -r 'length' <<<"$ORDER")
QUEUE_LINE=$(jq -r 'map("#\(.)") | join(" → ")' <<<"$ORDER")
if [ -z "$HEAD_PR" ]; then
  status "empty"; say "lane: empty"; exit 0
fi
SHA=$(pr_field "$HEAD_PR" .headRefOid)
head_status() { status "$WAITING in line${QUEUE_LINE:+ ($QUEUE_LINE)} · head #$HEAD_PR — $*"; }

# A head waiting on its own checks keeps its place; a head stuck on anything else
# (a read that failed, a refusal) waits one pass, then gives it up and goes behind
# every other member until its head moves, so one PR never holds up the rest.
progress() { st '.head.stalls = 0'; }
stall() { # <why> — ends the pass
  local n
  n=$(jq -r '(.head.stalls // 0) + 1' <<<"$ST")
  if [ "$n" -le 1 ]; then
    st '.head.stalls = 1'; head_status "$1"; exit 0
  fi
  say "lane: #$HEAD_PR gives up its place — $1, a second pass running"
  act yield "$HEAD_PR" "$SHA" "$1"
  st --arg p "$HEAD_PR" --arg s "$SHA" --argjson now "$NOW" '.members[$p].yielded = {sha: $s, at: $now} | .head = null'
  status "$WAITING in line · #$HEAD_PR gave up its place: $1"; exit 0
}

# ---- fixers and leaving --------------------------------------------------------
ticket_of() { pr_field "$1" .headRefName | branch_tickets | cut -f1; }

fixer() { # <pr> <why>
  local pr="$1" why="$2" t note brief room
  t=$(ticket_of "$pr")
  if [ -z "$t" ]; then
    owner "lane-noticket:$pr:$SHA" "PR #$pr left the merge lane ($why) and its branch names no ticket to send a fixer to"
    return 0
  fi
  note="Merge lane: PR #$pr left the lane — $why. Fix it on the PR's own branch and push; then re-arm auto-merge so it rejoins. Never merge it yourself: the lane merges."
  # The one repair gate (repair-gate.sh): nothing a repair can fix is never sent one.
  local gwhy
  if ! gwhy=$(repair_gate "$t" "$(jq -c --argjson n "$pr" '[.[] | select(.number == $n)] | first // empty' <<<"$PRS")"); then
    say "lane: no fixer for #$t (PR #$pr): $gwhy"; return 0
  fi
  if lane_shadow; then say "would send a fixer to #$t"; return 0; fi
  if swarm_ticket_live "$t"; then say "lane: #$t already has an agent running — no second fixer"; return 0; fi
  # A live coordinator that ticked lately owns every start; without one a queued fixer never starts.
  if ! coord_live_recently && room=$(coord_room) && room=${room#*$'\t'} \
     && { [ -z "$COORD_CAP$COORD_CAP_BAD" ] || { [ -n "$COORD_CAP" ] && [ "$(swarm_running_total)" -lt "$COORD_CAP" ]; }; }; then
    brief=$(mktemp); printf '%s\n' "$note" > "$brief"
    if CLAIM_CLASS=repair swarm_spawn "$t" "$brief" >> "$LANE_LOG" 2>&1; then
      coord_record_class "$t" repair; say "lane: no live coordinator — spawned a fixer for #$t ($room)"
    else say "lane: the fixer for #$t did not spawn"; fi
    rm -f "$brief"
    return 0
  fi
  bash "$QUEUE" add "$t" --class repair --note "$note" >/dev/null 2>&1 \
    && say "lane: #$t queued as a repair${room:+ — no room ($room)}" \
    || say "lane: could not queue #$t as a repair"
}

take_out() { # <why> — the head leaves the lane on this SHA and gets a fixer
  local why="$1"
  act out "$HEAD_PR" "$SHA" "$why"
  if lane_shadow; then
    say "would take #$HEAD_PR out of the lane: $why"
  else
    say "lane: #$HEAD_PR out — $why"
    swarm_gh pr edit "$HEAD_PR" --repo "$REPO_SLUG" --remove-label "$LANE_LABEL" >/dev/null 2>&1 || true
    swarm_gh pr comment "$HEAD_PR" --repo "$REPO_SLUG" \
      --body "Left the merge lane: $why. Re-arm auto-merge on a new head to rejoin." >/dev/null 2>&1 || true
  fi
  fixer "$HEAD_PR" "$why"
  drop "$HEAD_PR"
  st --arg p "$HEAD_PR" --arg s "$SHA" '.out[$p] = $s'
  status "$WAITING in line · #$HEAD_PR left: $why"
}

# ---- 4a. a hold put back on the head -------------------------------------------
# The rule is shared with the approval gate: scripts/approval-kept.sh.
develop_only() { # <approved-sha> <head-sha> — 0 kept, 1 changed (CHANGE_WHY), 2 unreadable
  CHANGE_WHY=$(HARNESS_CFG_PATH="$HARNESS_CFG" bash "$KEPT" check "$1" "$2" 2>/dev/null)
}

if has_label "$HEAD_PR" "$HOLD_LABEL"; then
  approved=$(jq -r --arg p "$HEAD_PR" '.members[$p].approved // empty' <<<"$ST")
  updated=$(jq -r --arg p "$HEAD_PR" '.members[$p].updated // false' <<<"$ST")
  if [ "$updated" != true ] || [ -z "$approved" ]; then
    say "lane: #$HEAD_PR is held and the lane never updated it — out of line until it is signed off"
    act held "$HEAD_PR" "$SHA" "held; not the lane's update"
    drop "$HEAD_PR"; status "$WAITING in line · #$HEAD_PR held for sign-off"; exit 0
  fi
  CHANGE_WHY=""; develop_only "$approved" "$SHA"; rc=$?
  case "$rc" in
    0)
      reason="the merge lane made a $INTEGRATION_BRANCH-only update and none of its screen files changed since the approved ${approved:0:7}"
      act clear-hold "$HEAD_PR" "$SHA" "$reason"
      if lane_shadow; then say "would clear the hold on #$HEAD_PR: $reason"
      elif bash "$CLEAR_HOLD" "$HEAD_PR" --reason "$reason" --sha "$SHA" >> "$LANE_LOG" 2>&1; then say "lane: hold re-cleared on #$HEAD_PR — $reason"
      else say "lane: clear-hold on #$HEAD_PR failed — trying again next pass"; fi
      progress; head_status "approval carried through a develop-only update" ;;
    1)
      say "lane: #$HEAD_PR changed after its update — $CHANGE_WHY; the hold stays"
      act held "$HEAD_PR" "$SHA" "$CHANGE_WHY"
      owner "lane-hold:$HEAD_PR:$SHA" "PR #$HEAD_PR needs your sign-off again: $CHANGE_WHY"
      drop "$HEAD_PR"; status "$WAITING in line · #$HEAD_PR back to the owner: $CHANGE_WHY" ;;
    *)
      say "lane: #$HEAD_PR is held and its update could not be compared — waiting"
      stall "cannot compare its update with the approved head" ;;
  esac
  exit 0
fi

# ---- 4b. conflict, then behind -------------------------------------------------
if [ "$(pr_field "$HEAD_PR" .mergeable)" = CONFLICTING ]; then
  take_out "it conflicts with $INTEGRATION_BRANCH"; exit 0
fi
# Behind matters only where the trunk requires up to date: with merge.updateBehind
# bot an update is never needed unless GitHub itself reads the PR as BEHIND (a strict
# rule). Updating anyway chased the trunk: PRs merging around the lane moved it on
# before the new CI finished, and every PR behind the head waited.
BEHIND=0
if [ "$UPDATE_BEHIND" != bot ] || [ "$(pr_field "$HEAD_PR" .mergeStateStatus)" = BEHIND ]; then
  # gh-read-ok: a non-number waits, below
  BEHIND=$(swarm_gh api "repos/$REPO_SLUG/compare/$INTEGRATION_BRANCH...$SHA" --jq .behind_by 2>/dev/null)
  case "$BEHIND" in
    ''|*[!0-9]*) say "lane: cannot read how far #$HEAD_PR is behind — waiting"; stall "cannot read how far behind it is" ;;
  esac
fi
if [ "$BEHIND" -gt 0 ]; then
  act update "$HEAD_PR" "$SHA" "$BEHIND behind $INTEGRATION_BRANCH"
  if lane_shadow; then
    say "would update #$HEAD_PR ($BEHIND behind $INTEGRATION_BRANCH)"
  else
    err=$(swarm_gh api -X PUT "repos/$REPO_SLUG/pulls/$HEAD_PR/update-branch" -f "expected_head_sha=$SHA" 2>&1 >/dev/null)
    if [ $? -eq 0 ]; then
      say "lane: updated #$HEAD_PR with $INTEGRATION_BRANCH"
      st --arg p "$HEAD_PR" '.members[$p].updated = true'; progress
    elif printf '%s' "$err" | grep -qi conflict; then
      take_out "updating it with $INTEGRATION_BRANCH hit a merge conflict"; exit 0
    else
      say "lane: update of #$HEAD_PR refused — $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
      stall "its update with $INTEGRATION_BRANCH was refused"
    fi
  fi
  head_status "updating with $INTEGRATION_BRANCH"; exit 0
fi

# ---- 4c. the required checks on this head --------------------------------------
# One row per required check: name, green|pending|missing|failed, conclusion, url.
CHECKS=$(jq -r --argjson n "$HEAD_PR" --argjson req "$REQUIRED" "$CHECK_NEWEST_JQ"'
  (.[] | select(.number == $n) | .statusCheckRollup // [] | newest_runs) as $c
  | $req[] as $r
  | ([ $c[] | select(.name == $r or .context == $r or (((.workflowName // "") + " / " + (.name // "")) == $r)) ] | last) as $x
  | if $x == null then [$r, "missing", "", ""]
    elif (($x.status // "COMPLETED") != "COMPLETED") or (($x.state // "") | test("PENDING|EXPECTED")) then [$r, "pending", "", ""]
    elif (($x.conclusion // $x.state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")) then [$r, "green", "", ""]
    else [$r, "failed", ($x.conclusion // $x.state // ""), ($x.detailsUrl // $x.targetUrl // "")] end
  | @tsv' <<<"$PRS")

flaky() { # <conclusion> <job-id> — 0 a flake, 1 a real red, GH_READ_UNKNOWN when its annotations could not be read
  local notes
  case "$1" in TIMED_OUT|CANCELLED|STARTUP_FAILURE) return 0 ;; esac
  [ -n "$2" ] || return 1
  notes=$(gh_read "the annotations of check run $2" api "repos/$REPO_SLUG/check-runs/$2/annotations" --jq '.[].message') || return "$GH_READ_UNKNOWN"
  grep -iE -- "$FLAKE_RE" >/dev/null <<<"$notes"
}

waiting=""; unread=""
while IFS=$'\t' read -r name verdict concl url; do
  [ -n "${name:-}" ] || continue
  case "$verdict" in
    green) ;;
    pending|missing) waiting="$waiting${waiting:+, }$name" ;;
    failed)
      run=$(printf '%s' "$url" | sed -nE 's#.*/actions/runs/([0-9]+).*#\1#p')
      job=$(printf '%s' "$url" | sed -nE 's#.*/job/([0-9]+).*#\1#p')
      rec=$(jq -c --arg p "$HEAD_PR" --arg s "$SHA" --arg c "$name" \
             'if .reruns[$p].sha == $s then (.reruns[$p].checks[$c] // null) else null end' <<<"$ST")
      if [ "$rec" != null ] && [ -n "$job" ] && jq -e --arg j "$job" 'index($j) != null' >/dev/null <<<"$rec"; then
        waiting="$waiting${waiting:+, }$name (re-run starting)"; continue
      fi
      fl=1; [ "$rec" = null ] && [ -n "$run" ] && { flaky "$concl" "$job"; fl=$?; }
      if [ "$fl" = "$GH_READ_UNKNOWN" ]; then
        say "lane: unknown — whether $name on #$HEAD_PR is a flake could not be read; nothing done this pass"
        waiting="$waiting${waiting:+, }$name (unknown: its annotations could not be read)"; unread=1; continue
      fi
      if [ "$fl" = 0 ]; then
        act rerun "$HEAD_PR" "$SHA:$name" "$name $concl — an infrastructure flake, re-run once"
        if lane_shadow; then say "would re-run $name on #$HEAD_PR ($concl)"
        else
          swarm_gh run rerun "$run" --failed --repo "$REPO_SLUG" >/dev/null 2>&1 \
            && say "lane: re-ran $name on #$HEAD_PR ($concl)" || say "lane: re-run of $name on #$HEAD_PR refused"
          st --arg p "$HEAD_PR" --arg s "$SHA" --arg c "$name" --arg j "$job" '
            (if .reruns[$p].sha == $s then . else .reruns[$p] = {sha: $s, checks: {}} end)
            | .reruns[$p].checks[$c] = ((.reruns[$p].checks[$c] // []) + [$j])'
        fi
        waiting="$waiting${waiting:+, }$name (re-run)"; continue
      fi
      take_out "the required check '$name' failed ($concl)"; exit 0 ;;
  esac
done <<< "$CHECKS"

if [ -n "$waiting" ]; then
  [ -z "$unread" ] || stall "waiting for checks: $waiting"
  progress; head_status "waiting for checks: $waiting"; exit 0
fi

# ---- 4d. merge: one per pass ---------------------------------------------------
act merge "$HEAD_PR" "$SHA" "$METHOD at $SHA"
if lane_shadow; then
  say "would merge #$HEAD_PR ($METHOD, head $SHA)"
  head_status "green and up to date — would merge"; exit 0
fi
if err=$(swarm_gh pr merge "$HEAD_PR" --repo "$REPO_SLUG" "--$METHOD" --match-head-commit "$SHA" 2>&1); then
  say "lane: merged #$HEAD_PR ($METHOD, head $SHA)"
  drop "$HEAD_PR"
  status "$((WAITING - 1)) in line · merged #$HEAD_PR"
else
  say "lane: merge of #$HEAD_PR refused — $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
  stall "merge refused"
fi
