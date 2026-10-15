#!/usr/bin/env bash
# fix-lock.sh — one window fixes a red pull request at a time.
#
#   fix-lock.sh acquire <pr> [--why <text>]   0 = yours now (or already yours)
#   fix-lock.sh renew   <pr>                  0 = expiry pushed out; 12 = not yours
#   fix-lock.sh release <pr> [--force]        0 = released; 11 = not held; 12 = not yours
#   fix-lock.sh holds   <pr>                  0 = this window holds it
#   fix-lock.sh list [--json]
#
# EXIT CODES: 0 ok · 10 another window holds it (take other work) · 11 not held ·
#             12 held by another window · 1 error
#
# WHY. A ticket claim (claim-lock.sh) stops two windows building one ticket. It
# does not stop two windows FIXING one red PR: the ticket's claim is held by
# whoever opened the PR, and "a red PR takes the next free agent place" sends
# every window with a free place at the same PR. Two fixers push over each other
# and each re-run of CI is wasted on the other's half-fix.
#
# The lock is a git ref on origin, refs/fixing/<pr>, created with
# --force-with-lease=<ref>: (must not exist) — the same server-side
# compare-and-swap claim-lock.sh proved. The record names the WINDOW, not the
# machine: two windows on one Mac share a login and a host, so login@host (the
# claim identity) would call both of them the owner.
#
# A lock outlives a window that died, so it carries an expiry (FIX_LOCK_TTL_MIN,
# default 120) and the holder's pid. It is taken over only when the expiry has
# passed, or the holder is on THIS host and its pid is gone — both read before
# a lease-guarded replace, so two takers of one stale lock still get one winner.

if [ -n "${FIX_LOCK_REPO:-}" ] && [ -z "${HARNESS_MAIN_REPO:-}" ]; then
  export HARNESS_MAIN_REPO="$FIX_LOCK_REPO"
fi
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolkit-env.sh" 2>/dev/null || true
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/claim-proc.sh" || exit 1

set -uo pipefail

REMOTE="${FIX_LOCK_REMOTE:-origin}"
NS="refs/fixing"
CACHE="refs/fixing-cache"
TTL_MIN="${FIX_LOCK_TTL_MIN:-120}"
case "$TTL_MIN" in ''|*[!0-9]*) TTL_MIN=120 ;; esac

die() { printf 'fix-lock: %s\n' "$*" >&2; exit 1; }
now() { printf '%s' "${FIX_LOCK_NOW:-$(date +%s)}"; }

HOST=$(claim_host)
# The window: an explicit id (tests, a caller that knows it), else the Claude
# process this shell runs under — one per window, the same for its sub-agents.
WIN_PID="${FIX_LOCK_PID:-$(claim_session_pid)}"
WINDOW="${FIX_LOCK_WINDOW:-${NONSTOP_WINDOW:-$HOST:$WIN_PID}}"

resolve_repo() {
  if [ -n "${FIX_LOCK_REPO:-}" ] && git -C "$FIX_LOCK_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$FIX_LOCK_REPO"
  elif [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    git rev-parse --show-toplevel
  elif [ -n "${MAIN_REPO:-}" ] && git -C "$MAIN_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$MAIN_REPO"
  else
    die "not in a git repo; run from a checkout or set FIX_LOCK_REPO"
  fi
}

remote_sha() { git ls-remote "$REMOTE" "$NS/$1" 2>/dev/null | cut -f1; }
read_rec() { # <sha> — the record is the commit message of a parentless commit
  git fetch -q "$REMOTE" "+$NS/$2:$CACHE/$2" 2>/dev/null || true
  git show -s --format=%B "$1" 2>/dev/null | sed '/^$/d' | tail -1
}
make_rec() { # <pr> <why>
  local t; t=$(now)
  jq -cn --argjson pr "$1" --arg w "$WINDOW" --arg host "$HOST" --arg pid "$WIN_PID" \
    --argjson at "$t" --argjson exp "$(( t + TTL_MIN * 60 ))" --arg why "$2" \
    '{pr:$pr,window:$w,host:$host,pid:$pid,at:$at,expires:$exp,why:$why}' \
  | git commit-tree "$(git hash-object -t tree /dev/null)" -F -
}

# Why a held lock may be taken over, or nothing when it may not.
stale_why() { # <record>
  local exp host pid
  exp=$(jq -r '.expires // 0' <<<"$1" 2>/dev/null); host=$(jq -r '.host // ""' <<<"$1" 2>/dev/null)
  pid=$(jq -r '.pid // ""' <<<"$1" 2>/dev/null)
  case "$exp" in ''|*[!0-9]*) exp=0 ;; esac
  [ "$exp" -le "$(now)" ] && { printf 'expired'; return 0; }
  if [ "$host" = "$HOST" ] && ! claim_pid_alive "$pid"; then printf 'holder window gone'; return 0; fi
  return 1
}

cmd_acquire() {
  local pr="$1" why="" sha old rec out
  shift
  [ "${1:-}" = "--why" ] && why="${2:-}"
  sha=$(make_rec "$pr" "$why") || die "could not build the record"
  if out=$(git push --no-verify "$REMOTE" "$sha:$NS/$pr" --force-with-lease="$NS/$pr:" 2>&1); then
    printf 'fixing PR #%s (%s)\n' "$pr" "$WINDOW"; return 0
  fi
  old=$(remote_sha "$pr")
  [ -n "$old" ] || { printf '%s\n' "$out" >&2; die "push failed for PR #$pr"; }
  rec=$(read_rec "$old" "$pr")
  if [ "$(jq -r '.window // ""' <<<"$rec" 2>/dev/null)" = "$WINDOW" ]; then
    printf 'fixing PR #%s (already yours)\n' "$pr"; return 0
  fi
  local stale
  if stale=$(stale_why "$rec"); then
    # Lease on the sha we judged: a second taker of the same stale lock loses here.
    if git push --no-verify "$REMOTE" "$sha:$NS/$pr" --force-with-lease="$NS/$pr:$old" >/dev/null 2>&1; then
      printf 'fixing PR #%s (took over: %s)\n' "$pr" "$stale"; return 0
    fi
  fi
  printf 'PR #%s is being fixed by %s — take other work\n' "$pr" "$(jq -r '.window // "?"' <<<"$rec" 2>/dev/null)" >&2
  return 10
}

mine_or_rc() { # <pr> → sets OLD and REC; returns 0 mine, 11 not held, 12 other
  OLD=$(remote_sha "$1"); [ -n "$OLD" ] || return 11
  REC=$(read_rec "$OLD" "$1")
  [ "$(jq -r '.window // ""' <<<"$REC" 2>/dev/null)" = "$WINDOW" ] && return 0
  return 12
}

cmd_renew() {
  local rc=0; mine_or_rc "$1" || rc=$?
  [ "$rc" -eq 0 ] || { printf 'PR #%s is not yours to renew\n' "$1" >&2; return "$rc"; }
  local sha; sha=$(make_rec "$1" "$(jq -r '.why // ""' <<<"$REC")")
  git push --no-verify "$REMOTE" "$sha:$NS/$1" --force-with-lease="$NS/$1:$OLD" >/dev/null 2>&1 \
    || { printf 'renew lost a race on PR #%s\n' "$1" >&2; return 10; }
  printf 'renewed PR #%s\n' "$1"
}

cmd_release() {
  local pr="$1" force="${2:-}" rc=0
  mine_or_rc "$pr" || rc=$?
  [ "$rc" -eq 11 ] && { printf 'PR #%s is not held\n' "$pr" >&2; return 11; }
  if [ "$rc" -eq 12 ] && [ "$force" != "--force" ]; then
    printf 'refusing: PR #%s is held by %s\n' "$pr" "$(jq -r '.window // "?"' <<<"$REC")" >&2; return 12
  fi
  git push --no-verify "$REMOTE" --delete "$NS/$pr" >/dev/null 2>&1 || die "could not delete $NS/$pr"
  git update-ref -d "$CACHE/$pr" 2>/dev/null || true
  printf 'released PR #%s\n' "$pr"
}

cmd_holds() { local rc=0; mine_or_rc "$1" || rc=$?; return "$rc"; }

cmd_list() {
  git fetch -q --prune "$REMOTE" "+$NS/*:$CACHE/*" 2>/dev/null || true
  local r rows=""
  for r in $(git for-each-ref --format='%(refname)' "$CACHE" 2>/dev/null); do
    rows="$rows$(git show -s --format=%B "$r" | sed '/^$/d' | tail -1)"$'\n'
  done
  if [ "${1:-}" = "--json" ]; then
    printf '%s' "$rows" | sed '/^$/d' | jq -s --arg w "$WINDOW" --argjson now "$(now)" \
      'map(. + {mine: (.window == $w), expired: (.expires <= $now)})'
  else
    [ -n "$rows" ] || { echo "no PR is being fixed"; return 0; }
    printf '%s' "$rows" | sed '/^$/d' | jq -r '"PR #\(.pr)\t\(.window)\t\(.why)"'
  fi
}

main() {
  [ $# -ge 1 ] || die "usage: fix-lock.sh {acquire|renew|release|holds|list} [pr]"
  command -v jq >/dev/null || die "jq is required"
  cd "$(resolve_repo)" || exit 1
  local cmd="$1"; shift
  case "$cmd" in
    acquire|renew|release|holds)
      case "${1:-}" in ''|*[!0-9]*) die "$cmd needs a PR number" ;; esac ;;
  esac
  case "$cmd" in
    acquire) cmd_acquire "$@" ;;
    renew)   cmd_renew "$1" ;;
    release) cmd_release "$@" ;;
    holds)   cmd_holds "$1" ;;
    list)    cmd_list "$@" ;;
    *) die "unknown command: $cmd" ;;
  esac
}
main "$@"
