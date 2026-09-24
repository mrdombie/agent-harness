#!/usr/bin/env bash
# claim-lock.sh — atomic ticket claims, backed by git refs on origin.
#
# WHY THIS EXISTS
#   Claims used to live in three places that disagreed: INDEX.tsv's status
#   column, a claims/<n>.lock directory, and a $TMPDIR worktree. On 2026-08-07
#   the count was 15 tickets marked claimed against 4 locks on disk and 34
#   orphan worktrees. Eleven tickets were held by nothing at all — invisible to
#   /claim, so never handed out again, and invisible to the sweeper, so never
#   reclaimed.
#
#   The obvious fix — make the GitHub assignee the lock — does not work on this
#   repo. With one assignable user, two agents both run
#   `--add-assignee @me`, both read back the same name, and both believe they
#   won. That is precisely the two-agents-one-ticket bug, and it would have
#   survived the migration intact.
#
#   Git refs do work. Pushing a ref with `--force-with-lease=<ref>:` (an empty
#   expect-value, meaning "this ref must not exist") is a server-side
#   compare-and-swap: the first writer creates it, the second is rejected with
#   "stale info". Proven against origin on 2026-08-07 before this was written.
#   One `ls-remote` then enumerates every live claim in the system — the
#   reconciliation primitive neither INDEX.tsv nor the lock dir ever had.
#
# WHY --no-verify ON EVERY PUSH
#   .husky/pre-push runs `npm run lockfile:check` on every push, including refs
#   that carry no code. A claim ref points at a parentless commit on the empty
#   tree; there is no package.json in it to be out of sync. Skipping the hook
#   here does not skip it for any branch push.
#
# THE LOCK IS THE REF. Labels and assignees are a derived, human-visible mirror
# written after the ref succeeds. Never read them to decide whether a ticket is
# claimed — that is the mistake this script exists to end.
#
# USAGE
#   claim-lock.sh acquire <issue> --branch <b> --worktree <w> [--pid <p>]
#   claim-lock.sh release <issue> [--force]
#   claim-lock.sh update  <issue> [--force] <key>=<value>...
#   claim-lock.sh list [--json]
#   claim-lock.sh show <issue>
#   claim-lock.sh holds <issue>          # exit 0 if THIS agent holds it
#
# EXIT CODES
#   0   success
#   10  lost the race — another agent holds it (back off, take another ticket)
#   11  not claimed / not found
#   12  held by a different agent (release without --force)
#   1   error

# CLAIM_REPO is this script's own repo override (the fixtures use it); let the
# resolver see it too, so a caller outside any checkout still resolves.
if [ -n "${CLAIM_REPO:-}" ] && [ -z "${HARNESS_MAIN_REPO:-}" ]; then
  export HARNESS_MAIN_REPO="$CLAIM_REPO"
fi
# Project facts (repo slug, labels, state dir) come from harness.json via the
# resolver beside this script. Sourced BEFORE `set -e`: bash 3.2 does not
# suppress errexit inside a sourced file even in a `||` list, and the resolver
# has non-fatal probes that would otherwise end this script at the first one.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" || exit 1

set -euo pipefail

REMOTE="${CLAIM_REMOTE:-origin}"
NS="refs/claims"
CACHE="refs/claims-cache"
DEFAULT_REPO="$MAIN_REPO"

die() { printf 'claim-lock: %s\n' "$*" >&2; exit 1; }

# Resolve a repo to push from. Any worktree of the project will do — the refs live
# on origin, not locally.
resolve_repo() {
  # Test the OUTPUT, never the exit code. A BARE repo prints "false" and exits
  # 0, so an exit-code test takes this branch and --show-toplevel then dies
  # with "must be run in a work tree" — before the CLAIM_REPO fallback below
  # is ever reached, so setting CLAIM_REPO does not help either.
  if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    git rev-parse --show-toplevel
  elif [ -n "${CLAIM_REPO:-$DEFAULT_REPO}" ] && git -C "${CLAIM_REPO:-$DEFAULT_REPO}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "${CLAIM_REPO:-$DEFAULT_REPO}"
  else
    die "not in a git repo and '${CLAIM_REPO:-$DEFAULT_REPO}' is not one; run from a checkout, or set CLAIM_REPO / HARNESS_MAIN_REPO"
  fi
}

# Who holds a claim: the GitHub login of the human whose token this agent runs
# on, at the machine it runs on — so two developers' agents are told apart.
# A record may carry the bare hostname (older claims): owns_claim accepts it.
THIS_HOST=$(hostname -s)
AGENT_ID="${CLAIM_AGENT:-$(toolkit_login)@$THIS_HOST}"
agent_id() { echo "$AGENT_ID"; }
# Ours if the agent matches, or — for a claim taken before ids carried the login,
# or from a shell where gh could not answer — it was taken on THIS machine.
owns_claim() { # <claim json>
  local who host; who=$(jq -r '.agent // ""' <<<"$1"); host=$(jq -r '.host // ""' <<<"$1")
  [ "$who" = "$AGENT_ID" ] && return 0
  [ "$host" = "$THIS_HOST" ] && { [ "$who" = "$THIS_HOST" ] || [ "${AGENT_ID#unknown@}" = "$THIS_HOST" ]; }
}

# ── Legacy lockfiles (#8677) ────────────────────────────────────────────────
# The migration from claims/<n>.lock to refs/claims/<n> is not finished. Until
# it is, "the ref is free" does not mean "the ticket is free": a ticket held by
# an unmigrated lockfile is invisible to a ref-only check, so `acquire` hands it
# out and two agents build it.
#
# Observed 2026-08-08: the ref for #8663 was granted at 00:54Z while a peer had
# held the lockfile since 00:41Z and had modified four files nine minutes
# earlier. The only reason it was caught is that `git worktree add` collided on
# the branch name — a different slug and both would have shipped it.
#
# Delete this block, and the two call sites, once claims/ is empty.
LOCK_DIR="${CLAIM_LOCK_DIR:-$STATE_DIR/claims}"

legacy_lock_path() { printf '%s/%s.lock' "$LOCK_DIR" "$1"; }
legacy_lock_held() { [ -d "$(legacy_lock_path "$1")" ]; }

# Best-effort holder description for the refusal message. A lockfile with no
# readable meta.json still counts as held — we refuse on the directory, not on
# being able to parse it.
legacy_lock_holder() {
  local meta; meta="$(legacy_lock_path "$1")/meta.json"
  [ -f "$meta" ] || { printf 'legacy lockfile (no meta.json)'; return; }
  jq -r '"legacy lockfile · branch \(.branch // "?") · claimed \(.claimed_at // "?")"' "$meta" 2>/dev/null \
    || printf 'legacy lockfile (unreadable meta.json)'
}

# Build the claim record and park it in a parentless commit on the empty tree.
# The commit is the lock's payload: everything the reconciler needs to decide
# whether this claim is alive, without consulting any local state.
make_claim_commit() {
  local issue="$1" branch="$2" worktree="$3" pid="$4" at="$5" empty_tree meta
  empty_tree=$(git hash-object -t tree /dev/null)
  meta=$(jq -cn \
    --argjson issue "$issue" \
    --arg agent "$(agent_id)" \
    --argjson pid "$pid" \
    --arg branch "$branch" \
    --arg worktree "$worktree" \
    --arg host "$(hostname -s)" \
    --arg at "$at" \
    '{issue:$issue,agent:$agent,pid:$pid,branch:$branch,worktree:$worktree,host:$host,claimed_at:$at}')
  git commit-tree "$empty_tree" -m "$meta"
}

read_claim() { git show -s --format=%B "$1" 2>/dev/null | sed '/^$/d' | tail -1; }

sync_cache() {
  git fetch -q --prune "$REMOTE" "+$NS/*:$CACHE/*" 2>/dev/null || true
}

# The pid recorded in a claim is what `reconcile-claims.sh` tests with `kill -0`
# to decide whether the holder is still alive. It therefore has to name a
# process that lives as long as the AGENT, not as long as the command.
#
# `$$` does not. Every tool call gets a fresh shell that exits the moment the
# call returns, so a claim stamped with `$$` reads as abandoned within seconds
# of being taken. Measured: a claim recorded pid 75901; one call later that pid
# was already dead. An agent that had claimed a ticket but not yet pushed a
# branch fell straight through the reconciler's evidence checks to RELEASED, and
# a peer picked up work already in progress — twice in one session.
#
# Walk up to the nearest `claude` ancestor, which is the session itself.
session_pid() {
  local p=$$ cmd
  while [ "$p" -gt 1 ]; do
    cmd=$(ps -o comm= -p "$p" 2>/dev/null) || break
    case "$cmd" in *claude*) printf '%s' "$p"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] || break
  done
  # No claude ancestor (a cron or a bare shell). $PPID at least outlives the
  # innermost subshell, and a wrong-but-live pid is safer here than a dead one:
  # the reconciler treats "alive" as leave-it-alone.
  printf '%s' "$PPID"
}

cmd_acquire() {
  local issue="" branch="" worktree="" pid="" at=""
  pid="$(session_pid)"
  issue="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)     branch="$2"; shift 2 ;;
      --worktree)   worktree="$2"; shift 2 ;;
      --pid)        pid="$2"; shift 2 ;;
      --claimed-at) at="$2"; shift 2 ;;   # adoption only: preserve original time
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$issue" ] || die "acquire needs an issue number"
  [ -n "$branch" ] || die "acquire needs --branch"
  [ -n "$at" ] || at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # #8677 — refuse before the CAS if a legacy lockfile holds this ticket. Same
  # exit code as losing the ref race, so every caller already handles it.
  if legacy_lock_held "$issue"; then
    printf 'lost the race for #%s\n' "$issue" >&2
    printf 'held by: %s\n' "$(legacy_lock_holder "$issue")" >&2
    return 10
  fi

  local sha ref out
  ref="$NS/$issue"
  sha=$(make_claim_commit "$issue" "$branch" "$worktree" "$pid" "$at")

  # The CAS. An empty expect-value means "must not already exist".
  if out=$(git push --no-verify "$REMOTE" "$sha:$ref" --force-with-lease="$ref:" 2>&1); then
    printf 'acquired #%s\n' "$issue"
    return 0
  fi

  if grep -qiE 'stale info|already exists|non-fast-forward|rejected' <<<"$out"; then
    sync_cache
    local holder
    holder=$(read_claim "$CACHE/$issue" 2>/dev/null || true)
    printf 'lost the race for #%s\n' "$issue" >&2
    [ -n "$holder" ] && printf 'held by: %s\n' "$holder" >&2
    return 10
  fi

  printf '%s\n' "$out" >&2
  die "push failed for #$issue"
}

cmd_release() {
  local issue="$1" force=0
  shift || true
  [ "${1:-}" = "--force" ] && force=1

  sync_cache
  local meta
  meta=$(read_claim "$CACHE/$issue" 2>/dev/null || true)
  if [ -z "$meta" ]; then
    printf '#%s is not claimed\n' "$issue" >&2
    return 11
  fi

  # Refuse to release another agent's claim unless told to. Reclaiming a live
  # peer's ticket is how two agents end up on one branch.
  if [ "$force" -eq 0 ]; then
    local owner; owner=$(jq -r '.agent' <<<"$meta" 2>/dev/null || echo "")
    if ! owns_claim "$meta"; then
      printf 'refusing: #%s is held by %s, not %s (use --force to override)\n' \
        "$issue" "$owner" "$(agent_id)" >&2
      return 12
    fi
  fi

  git push --no-verify "$REMOTE" --delete "$NS/$issue" >/dev/null 2>&1 \
    || die "failed to delete $NS/$issue"
  printf 'released #%s\n' "$issue"

  # 2026-08-25 — PUT THE TICKET BACK ON THE BOARD.
  #
  # Releasing deleted the ref and nothing restored the label, so a released
  # ticket ended up carrying NO status at all: not claimed, and invisible to
  # /claim, which only ever selects `status:ready`. It was neither held nor
  # offered. 23 open issues were in that state when this was found — 9 of them
  # #9335 batch children released during the 09:15 CI outage the same morning.
  #
  # Bookkeeping, not the lock: the ref is already gone, so a failure here must
  # never fail the release. Every branch is non-fatal.
  #
  # DELIBERATE STATES ARE LEFT ALONE. A parked ticket carries
  # `needs:human-approval` and usually `status:in-review` with an open PR — that
  # is a human gate, not an abandoned claim, and re-offering it would hand a
  # second agent work that is already built and waiting on a person.
  if command -v gh >/dev/null 2>&1; then
    local _st _labels _both
    _both=$(gh issue view "$issue" --repo "$REPO_SLUG" --json state,labels \
              --jq '"\(.state)|\([.labels[].name]|join(","))"' 2>/dev/null || true)
    _st=${_both%%|*}
    _labels=${_both#*|}
    if [ "$_st" = "OPEN" ]; then
      case ",$_labels," in
        *,"$HOLD_LABEL",*) : ;;                                   # parked for a human
        *,"$LBL_IN_REVIEW",*|*,"$LBL_PARKED",*) : ;;              # deliberate holds
        *,"$LBL_NEEDS_HUMAN",*|*,"$LBL_BLOCKED",*) : ;;           # escalated
        *,"$LBL_DRAFTING",*|*,"$LBL_GATED",*) : ;;                # not claimable anyway
        *,"$LBL_PM_DECISION",*|*,"$LBL_EXTERNAL_BLOCKED",*|*,"$LBL_PM_TRACK",*) : ;;
        *,"$LBL_CLAIMED",*)
          # A SHIPPED ticket is not an abandoned one. /finish releases (7a) BEFORE
          # it closes the issue (7d), so at this moment a just-merged ticket still
          # reads OPEN + status:claimed and is indistinguishable from a dead claim
          # by labels alone. Restoring it here would put `status:ready` on a
          # ticket that closes seconds later — exactly the stale-label mess this
          # guard was written to clean up. Observed on #9479, 2026-08-26.
          #
          # A merged PR naming the ticket is the discriminator: abandoned claims
          # do not have one.
          if gh pr list --repo "$REPO_SLUG" --state merged --limit 20 \
               --search "$issue in:title" --json number --jq 'length' 2>/dev/null \
               | grep -qv '^0$'; then
            printf '  #%s has a merged PR — shipped, not abandoned; leaving the label alone\n' "$issue"
          else
            gh issue edit "$issue" --repo "$REPO_SLUG" \
              --remove-label "$LBL_CLAIMED" --add-label "$LBL_READY" >/dev/null 2>&1 \
              && printf '  #%s back on the board (%s)\n' "$issue" "$LBL_READY"
          fi
          ;;
        *)
          # No status label at all — the shape this guard exists to prevent.
          gh issue edit "$issue" --repo "$REPO_SLUG" \
            --add-label "$LBL_READY" >/dev/null 2>&1 \
            && printf '  #%s had no status — set %s\n' "$issue" "$LBL_READY"
          ;;
      esac
    fi
  fi
}

cmd_list() {
  sync_cache
  local json=0
  [ "${1:-}" = "--json" ] && json=1

  local refs; refs=$(git for-each-ref --format='%(refname)' "$CACHE" 2>/dev/null || true)

  # #8677 — a lockfile with no ref is still a live claim. Listing refs only is
  # what let `acquire` hand out a ticket a peer was building: the one command
  # that is supposed to show every claim in the system did not show it.
  local legacy=""
  if [ -d "$LOCK_DIR" ]; then
    local d n
    for d in "$LOCK_DIR"/*.lock; do
      [ -d "$d" ] || continue
      n=$(basename "$d" .lock)
      case "$n" in ''|*[!0-9]*) continue ;; esac        # skip #NNN / SH-NNN legacy forms
      git show-ref --verify --quiet "$CACHE/$n" 2>/dev/null && continue   # already migrated
      legacy="${legacy}${n}"$'\n'
    done
    legacy=$(printf '%s' "$legacy" | sed '/^$/d')
  fi

  if [ -z "$refs" ] && [ -z "$legacy" ]; then
    [ "$json" -eq 1 ] && echo "[]" || echo "no live claims"
    return 0
  fi

  if [ "$json" -eq 1 ]; then
    {
      # `mine` is decided here, by owns_claim — the one rule (login@host, with
      # the bare-host fallback) — so no reader re-derives it from the agent string.
      [ -n "$refs" ] && while IFS= read -r r; do
        c=$(read_claim "$r") || continue
        if owns_claim "$c"; then jq -c '. + {mine: true}' <<<"$c"; else jq -c '. + {mine: false}' <<<"$c"; fi
      done <<<"$refs"
      [ -n "$legacy" ] && while IFS= read -r n; do
        jq -c --argjson issue "$n" '. + {issue: $issue, source: "legacy-lockfile"}' \
          "$LOCK_DIR/$n.lock/meta.json" 2>/dev/null \
          || jq -cn --argjson issue "$n" '{issue: $issue, source: "legacy-lockfile"}'
      done <<<"$legacy"
    } | jq -s '.'
  else
    FMT='%-8s %-30s %-34s %s\n'
    # shellcheck disable=SC2059
    printf "$FMT" ISSUE AGENT BRANCH CLAIMED_AT
    [ -n "$refs" ] && while IFS= read -r r; do
      read_claim "$r" | jq -r '[("#"+(.issue|tostring)),.agent,.branch,.claimed_at]|@tsv' 2>/dev/null \
        | awk -F'\t' -v fmt="$FMT" '{printf fmt,$1,$2,$3,$4}'
    done <<<"$refs"
    # Marked so the row's origin is legible, and so it is obvious which claims
    # still need migrating.
    [ -n "$legacy" ] && while IFS= read -r n; do
      jq -r --argjson issue "$n" \
        '[("#"+($issue|tostring)),"LOCKFILE(unmigrated)",(.branch // "?"),(.claimed_at // "?")]|@tsv' \
        "$LOCK_DIR/$n.lock/meta.json" 2>/dev/null \
        | awk -F'\t' -v fmt="$FMT" '{printf fmt,$1,$2,$3,$4}' \
        || printf "$FMT" "#$n" "LOCKFILE(unmigrated)" "?" "?"
    done <<<"$legacy"
  fi
}

# Update a claim record in place: read-modify-write under CAS, so a concurrent
# writer cannot be silently clobbered. Used for the Step 4.5 attestations
# (mockup_viewed / backend_contract_acknowledged) and for run_id / run_log,
# all of which are only known after the claim is already held. /finish reads
# the attestations back and refuses the merge if either is missing or false.
cmd_update() {
  local issue="$1"; shift
  local force=0
  [ "${1:-}" = "--force" ] && { force=1; shift; }
  [ $# -gt 0 ] || die "update needs at least one key=value"

  sync_cache
  local cur_sha meta
  cur_sha=$(git ls-remote "$REMOTE" "$NS/$issue" | cut -f1)
  [ -n "$cur_sha" ] || { printf '#%s is not claimed\n' "$issue" >&2; return 11; }
  meta=$(read_claim "$CACHE/$issue")

  if [ "$force" -eq 0 ]; then
    local owner; owner=$(jq -r '.agent' <<<"$meta")
    owns_claim "$meta" || {
      printf 'refusing: #%s is held by %s (use --force)\n' "$issue" "$owner" >&2; return 12; }
  fi

  local k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if jq -e . >/dev/null 2>&1 <<<"$v"; then          # true/false/123/"x"
      meta=$(jq -c --arg k "$k" --argjson v "$v" '.[$k]=$v' <<<"$meta")
    else                                              # bare string
      meta=$(jq -c --arg k "$k" --arg v "$v" '.[$k]=$v' <<<"$meta")
    fi
  done

  local empty_tree new_sha
  empty_tree=$(git hash-object -t tree /dev/null)
  new_sha=$(git commit-tree "$empty_tree" -m "$meta")
  git push --no-verify "$REMOTE" "$new_sha:$NS/$issue" \
    --force-with-lease="$NS/$issue:$cur_sha" >/dev/null 2>&1 \
    || { printf 'update lost a race on #%s — re-read and retry\n' "$issue" >&2; return 10; }
  printf 'updated #%s\n' "$issue"
}

cmd_show() {
  sync_cache
  local meta; meta=$(read_claim "$CACHE/$1" 2>/dev/null || true)
  [ -n "$meta" ] || { printf '#%s is not claimed\n' "$1" >&2; return 11; }
  jq '.' <<<"$meta"
}

cmd_holds() {
  sync_cache
  local meta; meta=$(read_claim "$CACHE/$1" 2>/dev/null || true)
  [ -n "$meta" ] || return 11
  owns_claim "$meta" || return 12
  return 0
}

main() {
  [ $# -ge 1 ] || die "usage: claim-lock.sh {acquire|release|list|show|holds} ..."
  command -v jq >/dev/null || die "jq is required"
  REPO_DIR=$(resolve_repo) || exit 1
  cd "$REPO_DIR"

  local cmd="$1"; shift
  case "$cmd" in
    acquire) cmd_acquire "$@" ;;
    release) cmd_release "$@" ;;
    update)  cmd_update "$@" ;;
    list)    cmd_list "$@" ;;
    show)    cmd_show "$@" ;;
    holds)   cmd_holds "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
