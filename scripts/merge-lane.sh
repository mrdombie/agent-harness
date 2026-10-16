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
#   2. members     open, not draft, on the trunk, no hold label, and auto-merge
#                  armed or the lane label. Live: the label goes on and auto-merge
#                  comes off, so the lane is the only thing that merges them.
#   3. order       the PR in flight stays head; then the first label (P0), then the
#                  pass that first saw it approved, then the PR number
#   4. the head    hold put back after the lane's update  → re-cleared only when
#                                 every commit since approval is a merge and the
#                                 update touched none of its screen files; else the
#                                 owner is told
#                  conflicting, or the update hits a conflict → out, fixer
#                  behind the trunk                      → update-branch, wait
#                  a required check pending or missing   → wait
#                  a required check red: a flake         → re-run once
#                                        anything else   → out, check named, fixer
#                  every required check green            → merge, end of pass
#
# Project facts, refused by key name when missing: merge.method, gates.requiredChecks.
# Optional: mergeLane.label (queue:merge), mergeLane.firstLabel (P0),
# mergeLane.flakePattern, design.surfacePaths (which files are screens).
#
# Shadow (the default): every act is written to actions.log as "would …"; nothing
# is merged, updated, labelled, re-run, spawned or notified.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1

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
SURFACE=$(jq -c '.design.surfacePaths // [] | if type == "array" then . else [] end' "$HARNESS_CFG" 2>/dev/null)
LANE_LABEL=$(swarm_opt mergeLane.label "queue:merge")
FIRST_LABEL=$(swarm_opt mergeLane.firstLabel "P0")
FLAKE_RE=$(swarm_opt mergeLane.flakePattern 'shutdown signal|lost communication with the server|runner .*(lost|did not respond|offline)|exit code 137|exit code 143|The operation was canceled|exceeded the maximum execution time')
NOTIFY="$SELF_DIR/coordinator-notify.sh"
QUEUE="$SELF_DIR/coordinator-queue.sh"
CLEAR_HOLD="$SELF_DIR/clear-hold.sh"

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

# ---- the open pull requests --------------------------------------------------
PRS=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --base "$INTEGRATION_BRANCH" --limit 200 \
        --json number,headRefName,headRefOid,isDraft,baseRefName,labels,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup 2>/dev/null)
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
st --argjson prs "$PRS" '.out |= with_entries(.key as $k | .value as $v | select(any($prs[]; (.number|tostring) == $k and .headRefOid == $v)))'
CANDS=$(jq -c --arg trunk "$INTEGRATION_BRANCH" --arg hold "$HOLD_LABEL" --arg lane "$LANE_LABEL" --argjson out "$(jq -c .out <<<"$ST")" '
  [ .[] | select(.isDraft | not) | select(.baseRefName == $trunk)
    | select(any(.labels[]?; .name == $hold) | not)
    | select(.autoMergeRequest != null or any(.labels[]?; .name == $lane))
    | select($out[(.number|tostring)] != .headRefOid)
    | {n: .number, sha: .headRefOid} ]' <<<"$PRS")
HEAD_PR=$(jq -r '.head.pr // empty' <<<"$ST")
st --argjson c "$CANDS" --argjson now "$NOW" --arg head "$HEAD_PR" '
  .members |= with_entries(.key as $k | select($k == $head or any($c[]; (.n|tostring) == $k)))
  | reduce $c[] as $x (.; (.members[($x.n|tostring)]) as $m
      | if $m == null then .members[($x.n|tostring)] = {seen: $now, approved: $x.sha, updated: false}
        elif ($m.updated | not) then .members[($x.n|tostring)].approved = $x.sha
        else . end)'

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
ORDER=$(jq -c --argjson c "$CANDS" --argjson prs "$PRS" --arg first "$FIRST_LABEL" '
  .head.pr as $h | .members as $m
  | [ $c[] | .n as $n
      | {n: $n, h: (if $n == $h then 0 else 1 end),
         p: (if any($prs[] | select(.number == $n) | .labels[]?; .name == $first) then 0 else 1 end),
         s: ($m[($n|tostring)].seen // 0)} ]
  | sort_by(.h, .p, .s, .n) | map(.n)' <<<"$ST")
st --argjson o "$ORDER" '.order = $o'

drop() { # <pr> — gone from the lane's books
  st --arg p "$1" 'del(.members[$p]) | del(.reruns[$p]) | del(.acts[$p]) | if (.head.pr|tostring) == $p then .head = null else . end'
}

if [ -n "$HEAD_PR" ] && [ -z "$(pr_json "$HEAD_PR")" ]; then
  say "lane: head #$HEAD_PR is no longer open — merged or closed elsewhere"
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

# ---- fixers and leaving --------------------------------------------------------
ticket_of() { pr_field "$1" .headRefName | awk -v p="$BRANCH_PREFIX" 'index($0, p) == 1 { s = substr($0, length(p) + 1); if (match(s, /^[0-9]+/)) print substr(s, 1, RLENGTH) }'; }

fixer() { # <pr> <why>
  local pr="$1" why="$2" t note
  t=$(ticket_of "$pr")
  if [ -z "$t" ]; then
    owner "lane-noticket:$pr:$SHA" "PR #$pr left the merge lane ($why) and its branch names no ticket to send a fixer to"
    return 0
  fi
  note="Merge lane: PR #$pr left the lane — $why. Fix it on the PR's own branch and push; then re-arm auto-merge so it rejoins. Never merge it yourself: the lane merges."
  if lane_shadow; then say "would send a fixer to #$t"; return 0; fi
  if swarm_ticket_live "$t"; then say "lane: #$t already has an agent running — no second fixer"; return 0; fi
  # The coordinator tick owns every start: it reads the machine and the healing share.
  bash "$QUEUE" add "$t" --class repair --note "$note" >/dev/null 2>&1 \
    && say "lane: #$t queued as a repair — the coordinator starts its fixer" \
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
# A file is a screen when it matches an include of design.surfacePaths and no
# :(exclude). No surfacePaths: every file counts, which holds more, never less.
is_screen() { # <path>
  local f="$1" pat inc=0 hit=0
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    case "$pat" in
      ':(exclude)'*|':!'*)
        pat="${pat#:(exclude)}"; pat="${pat#:!}"; pat="${pat//\*\*\//}"; pat="${pat//\*\*/*}"
        [[ "$f" == $pat ]] && return 1 ;;
      *) inc=1; pat="${pat//\*\*\//}"; pat="${pat//\*\*/*}"; [[ "$f" == $pat ]] && hit=1 ;;
    esac
  done <<< "$(jq -r '.[]' <<<"$SURFACE")"
  [ "$inc" = 0 ] || [ "$hit" = 1 ]
}

# 0: only the trunk came in and none of the PR's screen files moved. 1: changed
# (CHANGE_WHY says how). 2: could not be read.
develop_only() { # <approved-sha> <head-sha>
  local since own f
  since=$(swarm_gh api "repos/$REPO_SLUG/compare/$1...$2" 2>/dev/null) || return 2
  own=$(swarm_gh api "repos/$REPO_SLUG/compare/$INTEGRATION_BRANCH...$2" 2>/dev/null) || return 2
  jq -e '.commits | type == "array"' >/dev/null 2>&1 <<<"$since" || return 2
  jq -e '.files | type == "array"' >/dev/null 2>&1 <<<"$own" || return 2
  if jq -e '.commits | length == 0 or any(.[]; (.parents | length) < 2)' >/dev/null <<<"$since"; then
    CHANGE_WHY="it carries a commit of its own since the approved ${1:0:7}"; return 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    is_screen "$f" || continue
    if jq -e --arg f "$f" 'any(.files[]?; .filename == $f)' >/dev/null <<<"$since"; then
      CHANGE_WHY="the update changed its screen file $f"; return 1
    fi
  done <<< "$(jq -r '.files[].filename' <<<"$own")"
  return 0
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
      elif bash "$CLEAR_HOLD" "$HEAD_PR" --reason "$reason" >> "$LANE_LOG" 2>&1; then say "lane: hold re-cleared on #$HEAD_PR — $reason"
      else say "lane: clear-hold on #$HEAD_PR failed — trying again next pass"; fi
      head_status "approval carried through a develop-only update" ;;
    1)
      say "lane: #$HEAD_PR changed after its update — $CHANGE_WHY; the hold stays"
      act held "$HEAD_PR" "$SHA" "$CHANGE_WHY"
      owner "lane-hold:$HEAD_PR:$SHA" "PR #$HEAD_PR needs your sign-off again: $CHANGE_WHY"
      drop "$HEAD_PR"; status "$WAITING in line · #$HEAD_PR back to the owner: $CHANGE_WHY" ;;
    *)
      say "lane: #$HEAD_PR is held and its update could not be compared — waiting"
      head_status "cannot compare its update with the approved head" ;;
  esac
  exit 0
fi

# ---- 4b. conflict, then behind -------------------------------------------------
if [ "$(pr_field "$HEAD_PR" .mergeable)" = CONFLICTING ]; then
  take_out "it conflicts with $INTEGRATION_BRANCH"; exit 0
fi
BEHIND=$(swarm_gh api "repos/$REPO_SLUG/compare/$INTEGRATION_BRANCH...$SHA" --jq .behind_by 2>/dev/null)
case "$BEHIND" in
  ''|*[!0-9]*) say "lane: cannot read how far #$HEAD_PR is behind — waiting"; head_status "cannot read how far behind it is"; exit 0 ;;
esac
if [ "$BEHIND" -gt 0 ]; then
  act update "$HEAD_PR" "$SHA" "$BEHIND behind $INTEGRATION_BRANCH"
  if lane_shadow; then
    say "would update #$HEAD_PR ($BEHIND behind $INTEGRATION_BRANCH)"
  else
    err=$(swarm_gh api -X PUT "repos/$REPO_SLUG/pulls/$HEAD_PR/update-branch" -f "expected_head_sha=$SHA" 2>&1 >/dev/null)
    if [ $? -eq 0 ]; then
      say "lane: updated #$HEAD_PR with $INTEGRATION_BRANCH"
      st --arg p "$HEAD_PR" '.members[$p].updated = true'
    elif printf '%s' "$err" | grep -qi conflict; then
      take_out "updating it with $INTEGRATION_BRANCH hit a merge conflict"; exit 0
    else
      say "lane: update of #$HEAD_PR refused — $(printf '%s' "$err" | tr '\n' ' ' | cut -c1-200)"
    fi
  fi
  head_status "updating with $INTEGRATION_BRANCH"; exit 0
fi

# ---- 4c. the required checks on this head --------------------------------------
# One row per required check: name, green|pending|missing|failed, conclusion, url.
CHECKS=$(jq -r --argjson n "$HEAD_PR" --argjson req "$REQUIRED" '
  (.[] | select(.number == $n) | .statusCheckRollup // []) as $c
  | $req[] as $r
  | ([ $c[] | select(.name == $r or .context == $r or (((.workflowName // "") + " / " + (.name // "")) == $r)) ] | last) as $x
  | if $x == null then [$r, "missing", "", ""]
    elif (($x.status // "COMPLETED") != "COMPLETED") or (($x.state // "") | test("PENDING|EXPECTED")) then [$r, "pending", "", ""]
    elif (($x.conclusion // $x.state // "") | test("^(SUCCESS|NEUTRAL|SKIPPED)$")) then [$r, "green", "", ""]
    else [$r, "failed", ($x.conclusion // $x.state // ""), ($x.detailsUrl // $x.targetUrl // "")] end
  | @tsv' <<<"$PRS")

flaky() { # <conclusion> <job-id>
  case "$1" in TIMED_OUT|CANCELLED|STARTUP_FAILURE) return 0 ;; esac
  [ -n "$2" ] || return 1
  swarm_gh api "repos/$REPO_SLUG/check-runs/$2/annotations" --jq '.[].message' 2>/dev/null | grep -qiE -- "$FLAKE_RE"
}

waiting=""
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
      if [ "$rec" = null ] && [ -n "$run" ] && flaky "$concl" "$job"; then
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
  head_status "waiting for checks: $waiting"; exit 0
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
  head_status "merge refused; trying again next pass"
fi
