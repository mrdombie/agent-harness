#!/usr/bin/env bash
# keep-fresh.sh — settle a conflicting pull request's mechanical clashes by rule, so a
# builder is sent only for a real one. One pass per run, under a lock of its own.
#
#   keep-fresh.sh            one pass; COORDINATOR_SHADOW=0 acts for real, anything else is shadow
#
# Most clashes with the integration branch are mechanical: a deploy stamp, a line added
# to package.json's scripts on both sides, a ratchet baseline both sides lowered, a
# changelog fragment. Sent to a builder, each costs a model run for what a rule settles.
#
# A pass, for each open, non-draft PR on the integration branch that GitHub reads as
# conflicting (REST: mergeable false and mergeable_state "dirty" — GitHub is the
# authority, never a local trial merge), oldest first, up to merge.keepFreshPerTick (5):
#   claimed       its ticket has a claim (claim-lock.sh list), a live run, or a session
#                 holds the PR (fix-lock.sh) → skipped: the run owns its branch
#   queued        its ticket is already queued as a repair → skipped, not counted: a builder is coming
#   tried         a real conflict was already found on this head → skipped until it moves
#   merge         a scratch worktree at the PR's head merges origin/<integration branch>
#     every conflicted file matches a merge.mechanical rule (keep-fresh-resolve.py)
#                 → resolved, committed as the merge, the sign-off push guard run on
#                   it as the pre-push would, pushed, and one comment naming file and rule
#     any other   → aborted; the branch is untouched and its ticket queued as a repair
#
# A PR that is merely behind and clean is never read past its state: merging the trunk
# into it only queues another CI run (merge.updateBehind: bot).
#
# SIGN-OFFS. The push is a merge commit and its resolution touches only rule files, so
# approval-kept.sh check — the one develop-merge rule the project's gate and the merge
# lane share — keeps a sign-off through it. The sign-off push guard runs first with the
# push's own ref line; a push it refuses is not made, and the PR goes to a builder.
#
# Project facts: merge.keepFresh (true turns this on), merge.keepFreshPerTick (5),
# merge.mechanical (the rules; empty, every conflict is real). README.md has the shapes.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/coordinator-env.sh" || exit 1

KF_LOG="$COORD_DIR/keep-fresh.log"
say() { printf '%s\n' "$*"; swarm_log "$KF_LOG" "$*"; }

[ "$(jq -r '.merge.keepFresh // false' "$HARNESS_CFG" 2>/dev/null)" = true ] \
  || { echo "keep-fresh: off — harness.json merge.keepFresh is not true"; exit 0; }
RULES=$(jq -c '.merge.mechanical // [] | if type == "array" then . else error("not a list") end' "$HARNESS_CFG" 2>/dev/null) \
  || { say "keep-fresh: harness.json merge.mechanical is not a list — doing nothing"; exit 1; }
PER_TICK=$(swarm_opt merge.keepFreshPerTick 5)
case "$PER_TICK" in ''|*[!0-9]*) PER_TICK=5 ;; esac

QUEUE="$SELF_DIR/coordinator-queue.sh"
RESOLVE="$SELF_DIR/keep-fresh-resolve.py"
GUARD="${KEEP_FRESH_PUSH_GUARD:-$SELF_DIR/signoff-push-guard.sh}"
FIXLOCK="${COORDINATOR_FIX_LOCK:-$SELF_DIR/fix-lock.sh}"
STATE_FILE="$COORD_DIR/keep-fresh.$(coord_mode).json"
touch "$COORD_ACTIONS"

LOCK="$COORD_DIR/keep-fresh.lock"
coord_lock "$LOCK" keep-fresh || { say "keep-fresh: $COORD_LOCK_WHY — exiting"; exit 0; }
SCRATCH=""; KF_REF=""
cleanup() {
  if [ -n "$SCRATCH" ] && [ -d "$SCRATCH" ]; then
    git -C "$MAIN_REPO" worktree remove --force "$SCRATCH/wt" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH"; git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  fi
  rm -rf "$LOCK"
}
trap cleanup EXIT

if held=$(swarm_held); then say "keep-fresh: held — $held"; exit 0; fi

# ---- state: the head a real conflict was found on, and the last state read per PR ----
ST=$(jq -c 'if type == "object" then . else {} end' "$STATE_FILE" 2>/dev/null) || ST=""
[ -n "$ST" ] || ST='{}'
ST=$(jq -c '{tried: (.tried // {}), seen: (.seen // {})}' <<<"$ST")
st() { ST=$(jq -c "$@" <<<"$ST"); }
save() { local tmp; tmp=$(mktemp "$COORD_DIR/.keep-fresh.XXXXXX") && printf '%s\n' "$ST" > "$tmp" && mv "$tmp" "$STATE_FILE"; }
trap 'save; cleanup' EXIT
act() { printf '%s\t%s\t%s\t%s\t%s\n' "$(swarm_stamp)" "$(coord_mode)" "$1" "$2" "${3:-}" >> "$COORD_ACTIONS"; }

# ---- what a live run holds: fails closed, since a branch a run is on is never ours ----
CLAIMS=$(if [ -n "${COORDINATOR_CLAIMS_CMD:-}" ]; then $COORDINATOR_CLAIMS_CMD; else bash "$CL" list --json 2>/dev/null; fi)
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$CLAIMS" \
  || { say "keep-fresh: the claim list could not be read — touching nothing"; exit 0; }
FIXING=$(FIX_LOCK_REPO="${FIX_LOCK_REPO:-${MAIN_REPO:-}}" bash "$FIXLOCK" list --json 2>/dev/null \
  | jq -r '.[]? | select(.expired | not) | .pr | tostring' 2>/dev/null)
# A ticket already queued for repair has a builder coming: its PR is passed over, so the
# per-pass limit goes to the PRs nothing has picked up yet.
REPAIRS=$(bash "$QUEUE" list 2>/dev/null | awk '$3 == "repair" { sub(/^#/, "", $2); print $2 }')
queued_n=0
claimed() { # <ticket> <branch> <pr> — prints who, 0 when held
  if [ -n "$1" ] && jq -e --arg t "$1" 'any(.[]; (.issue | tostring) == $t)' >/dev/null <<<"$CLAIMS"; then echo "a claim on #$1"; return 0; fi
  if jq -e --arg b "$2" 'any(.[]; (.branch // "") == $b)' >/dev/null <<<"$CLAIMS"; then echo "a claim on $2"; return 0; fi
  if [ -n "$1" ] && swarm_ticket_live "$1"; then echo "a live run for #$1"; return 0; fi
  if grep -qxF -- "$3" <<<"$FIXING"; then echo "a session fixing it (fix-lock)"; return 0; fi
  return 1
}

# ---- the open pull requests, over REST --------------------------------------------
PRS=$(swarm_gh api "repos/$REPO_SLUG/pulls?state=open&base=$INTEGRATION_BRANCH&per_page=100" --paginate 2>/dev/null | jq -cs 'add // []' 2>/dev/null)
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$PRS" || { say "keep-fresh: the open pull requests could not be read — next pass"; exit 0; }
git -C "$MAIN_REPO" fetch -q origin "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/origin/$INTEGRATION_BRANCH" 2>/dev/null \
  || { say "keep-fresh: could not fetch $INTEGRATION_BRANCH — next pass"; exit 0; }
TRUNK=$(git -C "$MAIN_REPO" rev-parse -q --verify "refs/remotes/origin/$INTEGRATION_BRANCH^{commit}" 2>/dev/null) \
  || { say "keep-fresh: $INTEGRATION_BRANCH cannot be read — next pass"; exit 0; }
PRUNED=$(jq_slurp prs "$PRS" -- jq -c '$prs[0] as $prs
  | .tried |= with_entries(select(.key as $k | any($prs[]; (.number|tostring) == $k)))
  | .seen |= with_entries(select(.key as $k | any($prs[]; (.number|tostring) == $k)))' <<<"$ST") \
  && ST="$PRUNED" || { say "keep-fresh: the state could not be pruned against the open pull requests — next pass"; exit 0; }

ROWS=$(jq -r --arg repo "$REPO_SLUG" '
  sort_by(.number)[] | select(.draft | not) | select((.head.repo.full_name // "") == $repo)
  | [.number, .head.ref, .head.sha] | @tsv' <<<"$PRS")

queue_repair() { # <ticket> <pr> <why>
  local note="Keep fresh: PR #$2 clashes with $INTEGRATION_BRANCH and a rule cannot settle it — $3. Merge $INTEGRATION_BRANCH into its branch, resolve, and push."
  [ -n "$1" ] || { say "keep-fresh: #$2's branch names no ticket — no repair to queue"; return 0; }
  if coord_shadow; then say "would queue #$1 as a repair — $3"; return 0; fi
  bash "$QUEUE" add "$1" --class repair --note "$note" >/dev/null 2>&1 \
    && say "keep-fresh: #$1 queued as a repair — $3" || say "keep-fresh: could not queue #$1 as a repair"
}

comment_body() { # <resolved tsv> <trunk> <new sha>
  printf 'Kept fresh: merged `%s` (%s) into this branch as `%s`. Every conflict was mechanical and was settled by a `merge.mechanical` rule:\n\n' \
    "$INTEGRATION_BRANCH" "${2:0:7}" "${3:0:7}"
  while IFS=$'\t' read -r f r; do [ -n "$f" ] && printf -- '- `%s` — %s\n' "$f" "$r"; done <<<"$1"
  printf '\nNo other file changed. A real conflict would have been left for a builder.\n'
}

# One PR: 0 done (pushed, queued or nothing to do), 1 not attempted this pass.
fresh_one() { # <pr> <branch> <head>
  local n="$1" br="$2" head="$3" t who v ms mg wt out rc resolved new why
  t=$(printf '%s\n' "$br" | branch_tickets | cut -f1)
  if [ -n "$t" ] && grep -qxF -- "$t" <<<"$REPAIRS"; then
    say "keep-fresh: #$n — #$t is already queued for repair — skipped"; queued_n=$((queued_n + 1)); return 1
  fi
  # A real conflict stays real until the head moves; a shadow pass says "would" once a head.
  if jq -e --arg p "$n" --arg h "$head" '.tried[$p] | select(.head == $h) | .outcome | IN("real", "would-push")' >/dev/null 2>&1 <<<"$ST"; then return 1; fi
  # A state already read on this head against this trunk is not asked for again.
  ms=$(jq -r --arg p "$n" --arg h "$head" --arg tr "$TRUNK" '.seen[$p] | select(.head == $h and .trunk == $tr) | .state // empty' <<<"$ST" 2>/dev/null)
  if [ -z "$ms" ]; then
    v=$(swarm_gh api "repos/$REPO_SLUG/pulls/$n" 2>/dev/null)
    mg=$(jq -r 'if .mergeable == null then "unknown" else (.mergeable | tostring) end' <<<"$v" 2>/dev/null)
    ms=$(jq -r '.mergeable_state // "unknown"' <<<"$v" 2>/dev/null)
    [ "$(jq -r '.head.sha // ""' <<<"$v" 2>/dev/null)" = "$head" ] || return 1
    case "$mg:$ms" in
      false:dirty) ms=dirty ;;
      unknown:*|*:unknown) return 1 ;;   # GitHub is still working it out: next pass
      *) st --arg p "$n" --arg h "$head" --arg tr "$TRUNK" --arg s "$ms" '.seen[$p] = {head: $h, trunk: $tr, state: $s}'; return 1 ;;
    esac
  fi
  [ "$ms" = dirty ] || return 1
  if who=$(claimed "$t" "$br" "$n"); then say "keep-fresh: #$n clashes but $who — skipped"; return 1; fi

  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/keep-fresh-$n.XXXXXX") || return 1
  KF_REF="refs/keep-fresh/pr-$n"
  wt="$SCRATCH/wt"; mkdir -p "$SCRATCH/hooks"
  if ! git -C "$MAIN_REPO" fetch -q origin "+refs/heads/$br:refs/keep-fresh/pr-$n" 2>/dev/null \
     || [ "$(git -C "$MAIN_REPO" rev-parse -q --verify "refs/keep-fresh/pr-$n" 2>/dev/null)" != "$head" ]; then
    say "keep-fresh: #$n's branch could not be fetched at $head — next pass"; cleanup_scratch; return 1
  fi
  git -C "$MAIN_REPO" worktree add -q --detach "$wt" "$head" >/dev/null 2>&1 \
    || { say "keep-fresh: no scratch worktree for #$n — next pass"; cleanup_scratch; return 1; }
  # No hook of the project's runs here: its checks are CI's, and the sign-off guard is run below.
  g() { git -C "$wt" -c core.hooksPath="$SCRATCH/hooks" "$@"; }
  out=$(g merge --no-ff --no-edit -m "Merge $INTEGRATION_BRANCH into $br" "refs/remotes/origin/$INTEGRATION_BRANCH" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    say "keep-fresh: #$n — GitHub reads it conflicting but $INTEGRATION_BRANCH merges cleanly here; its reading may be stale, nothing pushed"
    st --arg p "$n" --arg h "$head" --arg tr "$TRUNK" '.seen[$p] = {head: $h, trunk: $tr, state: "merges-here"}'
    cleanup_scratch; return 0
  fi
  if [ -z "$(g ls-files -u 2>/dev/null)" ]; then
    say "keep-fresh: #$n — merging $INTEGRATION_BRANCH failed with nothing conflicted: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
    cleanup_scratch; return 1
  fi
  printf '%s\n' "$RULES" > "$SCRATCH/rules.json"
  resolved=$(cd "$wt" && python3 -I "$RESOLVE" "$SCRATCH/rules.json" 2>"$SCRATCH/resolve.err"); rc=$?
  if [ "$rc" -ne 0 ]; then
    g merge --abort >/dev/null 2>&1 || true
    if [ "$rc" -eq 1 ]; then
      why=$(printf '%s\n' "$resolved" | awk -F'\t' 'NF { printf "%s%s (%s)", sep, $1, $2; sep = "; " }')
    else
      why="the rules could not be applied: $(tr '\n' ' ' < "$SCRATCH/resolve.err" | cut -c1-200)"
    fi
    say "keep-fresh: #$n has a real conflict — $why; its branch is untouched"
    act real-conflict "$n" "$why"
    st --arg p "$n" --arg h "$head" '.tried[$p] = {head: $h, outcome: "real"}'
    queue_repair "$t" "$n" "$why"
    cleanup_scratch; return 0
  fi
  if ! g commit -q --no-edit --no-verify >/dev/null 2>&1; then
    say "keep-fresh: #$n — the resolved merge could not be committed"; g merge --abort >/dev/null 2>&1; cleanup_scratch; return 1
  fi
  new=$(g rev-parse HEAD)
  rules_line=$(printf '%s\n' "$resolved" | awk -F'\t' 'NF { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
  if coord_shadow; then
    say "would push #$n: $INTEGRATION_BRANCH merged, $rules_line"
    act would-push "$n" "$rules_line"
    st --arg p "$n" --arg h "$head" '.tried[$p] = {head: $h, outcome: "would-push"}'
    cleanup_scratch; return 0
  fi
  # The pre-push contract, as `git push` would hand it to the project's own hook.
  if ! (cd "$wt" && printf 'HEAD %s refs/heads/%s %s\n' "$new" "$br" "$head" \
          | HARNESS_CFG_PATH="$HARNESS_CFG" bash "$GUARD" origin >"$SCRATCH/guard.out" 2>&1); then
    why="the sign-off push guard refused it: $(tr '\n' ' ' < "$SCRATCH/guard.out" | cut -c1-200)"
    say "keep-fresh: #$n — $why; nothing pushed"
    st --arg p "$n" --arg h "$head" '.tried[$p] = {head: $h, outcome: "real"}'
    queue_repair "$t" "$n" "$why"; cleanup_scratch; return 0
  fi
  # A plain push: a branch that moved since it was read is refused, never overwritten.
  if ! out=$(g push -q --no-verify origin "$new:refs/heads/$br" 2>&1); then
    say "keep-fresh: #$n — the push was refused ($(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)); next pass"
    cleanup_scratch; return 1
  fi
  say "keep-fresh: #$n pushed $new — $INTEGRATION_BRANCH merged, $rules_line"
  act pushed "$n" "$new: $rules_line"
  swarm_gh api -X POST "repos/$REPO_SLUG/issues/$n/comments" -f body="$(comment_body "$resolved" "$TRUNK" "$new")" >/dev/null 2>&1 \
    || say "keep-fresh: #$n pushed; its comment could not be posted"
  cleanup_scratch; return 0
}
cleanup_scratch() {
  [ -n "$SCRATCH" ] || return 0
  git -C "$MAIN_REPO" worktree remove --force "$SCRATCH/wt" >/dev/null 2>&1 || true
  rm -rf "$SCRATCH"; git -C "$MAIN_REPO" worktree prune >/dev/null 2>&1 || true
  [ -z "$KF_REF" ] || git -C "$MAIN_REPO" update-ref -d "$KF_REF" >/dev/null 2>&1 || true
  SCRATCH=""; KF_REF=""
}

done_n=0
# Read on its own descriptor: nothing a PR's pass runs may eat the next row.
while IFS=$'\t' read -r n br head <&3; do
  [ -n "${n:-}" ] || continue
  [ "$done_n" -lt "$PER_TICK" ] || { say "keep-fresh: $PER_TICK this pass — the rest next pass"; break; }
  if fresh_one "$n" "$br" "$head"; then done_n=$((done_n + 1)); fi
done 3<<<"$ROWS"
say "keep-fresh: $done_n settled or sent on this pass, $queued_n already queued for repair ($(coord_mode))"
