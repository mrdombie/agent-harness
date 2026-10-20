#!/usr/bin/env bash
# stop-dev-servers.sh — stop the Next.js servers agents leave behind.
#
#   stop-dev-servers.sh --worktree <path>        stop every server running inside <path>
#   stop-dev-servers.sh --sweep [--dry-run]      stop servers in ticket worktrees nobody holds
#   stop-dev-servers.sh --session <pid> [--dry-run]  one preview per agent: stop the
#                                                servers <pid> started in every worktree
#                                                but the one it started a server in last
#
# Each agent starts a web and an api server to render its screen, and nothing
# stopped them when the ticket shipped. Measured on 2026-09-30: 16 servers up to
# six days old, swap at 44 GB of 45, and one worktree holding three. Stopping the
# ten oldest halved swap. So /finish stops its own worktree's servers, and the
# sweep — run at the end of every reconcile — stops what a crashed or abandoned
# window left.
#
# THE SWEEP STOPS A SERVER ONLY ON POSITIVE PROOF IT WAS ABANDONED, all of:
#   1. its worktree's folder is named for a ticket — <branchPrefix><digits>-… —
#      so the owner's own checkouts and previews never qualify. "Outside the
#      repo's worktrees" protects nothing where the main clone is bare and every
#      checkout, the owner's included, is a worktree (the first version did that,
#      and a dry run on the origin machine would have stopped a develop preview
#      up for six hours);
#   2. that ticket has no claim ref on origin, read with ls-remote — a read that
#      fails stops nothing, and a local cache that happens to be empty cannot
#      pass for "nothing is claimed". Or it is claimed and its holder is proved
#      gone: the run has an .ended record, or its pid on this host is dead;
#   3. no shell, editor or agent session has its working directory in that
#      worktree — somebody sitting there is somebody using it;
#   4. the server is over the minimum age (default 2 hours).
#
# A server is found by its WORKING DIRECTORY (`lsof -d cwd`), not its command
# line alone: `next-server` names no path, and a command-line kill is what the
# harness's broad-kill hook refuses, rightly. Its launcher is stopped too only
# when the launcher is itself a Next launcher in the same worktree — never a
# shell, never an agent session (`claude … --name claim-next` contains "next").
#
# Test overrides: STOP_DEV_CLAIMED (newline list of claimed ticket numbers, or
# the word FAIL), STOP_DEV_CLAIM_RECORDS (JSON array of claim records, as
# `claim-lock.sh list --json` prints them), STOP_DEV_STATE_DIR,
# STOP_DEV_BRANCH_PREFIX, STOP_DEV_MIN_AGE (seconds).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_AGE="${STOP_DEV_MIN_AGE:-7200}"
MODE="" TARGET="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) MODE=worktree; TARGET="${2:-}"; shift 2 ;;
    --sweep) MODE=sweep; shift ;;
    --session) MODE=session; TARGET="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "stop-dev-servers: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: stop-dev-servers.sh --worktree <path> | --sweep [--dry-run] | --session <pid> [--dry-run]" >&2; exit 2; }
command -v lsof >/dev/null || { echo "stop-dev-servers: no lsof here — cannot see working directories, stopping nothing"; exit 0; }

# ps elapsed time, [[dd-]hh:]mm:ss, in seconds.
age_sec() {
  local e="$1" d=0 h=0 m=0 s=0 a b c
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }   # /tmp and /private/tmp are one place
# Every process's working directory, read ONCE: one lsof for the machine takes a
# second, one per process takes half a minute, and this runs inside every /claim.
CWDS=$(lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')
cwd_of() { printf '%s\n' "$CWDS" | awk -F'\t' -v p="$1" '$1 == p {print $2; exit}'; }
inside() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }   # <path> <root>

# A Next.js server process — the server itself, not whatever launched it.
is_server() {
  case "$1" in
    next-server*|next-build*) return 0 ;;
    node\ */next\ dev*|node\ */next\ start*|node\ *next/dist/bin/next\ *) return 0 ;;
  esac
  return 1
}
# A process that only exists to run next: safe to stop with its server.
is_launcher() {
  case "$1" in
    claude*|*/claude\ *|-*sh|*sh\ -c*|bash*|zsh*|sh\ *|login*|*launchd*) return 1 ;;
    "npm exec next"*|"npx next"*|node\ */next\ dev*|node\ */next\ start*|*"dotenv"*" next "*) return 0 ;;
  esac
  return 1
}

# "<pid> <ppid> <age-sec> <cwd>" for every server process.
servers() {
  ps -axo pid=,ppid=,etime=,command= 2>/dev/null | while read -r pid ppid etime cmd; do
    is_server "$cmd" || continue
    cwd=$(cwd_of "$pid"); [ -n "$cwd" ] || continue
    printf '%s %s %s %s\n' "$pid" "$ppid" "$(age_sec "$etime")" "$(real "$cwd")"
  done
}

# Stop a batch. <pid> <ppid> <root> per line on stdin, a reason in $1.
stop_all() {
  local why="$1" pid ppid root pcmd pcwd stopped=()
  while read -r pid ppid root; do
    [ -n "$pid" ] || continue
    if [ "$DRY" = 1 ]; then echo "would stop $pid — $why ($root)"; continue; fi
    kill -TERM "$pid" 2>/dev/null && stopped+=("$pid")
    pcmd=$(ps -o command= -p "$ppid" 2>/dev/null || true)
    if [ "$ppid" -gt 1 ] 2>/dev/null && is_launcher "$pcmd"; then
      pcwd=$(real "$(cwd_of "$ppid")")
      inside "$pcwd" "$root" && kill -TERM "$ppid" 2>/dev/null
    fi
    echo "stopped $pid — $why ($root)"
  done
  # One wait for the whole batch, not five seconds per server inside /claim.
  [ ${#stopped[@]} -gt 0 ] || return 0
  for _ in 1 2 3 4 5; do
    local left=0; for p in "${stopped[@]}"; do kill -0 "$p" 2>/dev/null && left=1; done
    [ "$left" = 0 ] && return 0; sleep 1
  done
  for p in "${stopped[@]}"; do kill -KILL "$p" 2>/dev/null; done
}

if [ "$MODE" = worktree ]; then
  [ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "stop-dev-servers: no such worktree '$TARGET'" >&2; exit 0; }
  root=$(real "$TARGET")
  servers | while read -r pid ppid age cwd; do
    inside "$cwd" "$root" && echo "$pid $ppid $root"
  done | stop_all "its worktree is finishing"
  exit 0
fi

# ---- session: one preview per agent --------------------------------------------
# The sweep spares a server while the agent that started it is still open, and a
# loop stays open for hours, moving from ticket to ticket and leaving a preview up
# in each: on 2026-10-15 that was 54 servers in 11 worktrees, 29 of 32 GB in use.
# So an agent keeps the previews in the worktree it started a server in LAST and
# loses the rest. Only servers descended from <pid> are candidates.
if [ "$MODE" = session ]; then
  case "$TARGET" in ''|0|1|*[!0-9]*) echo "stop-dev-servers: --session needs an agent's pid, not '$TARGET'" >&2; exit 0 ;; esac
  MINE=$(ps -axo pid=,ppid= 2>/dev/null | awk -v s="$TARGET" '
    { parent[$1] = $2 }
    END { for (p in parent) { q = p; for (d = 0; d < 64 && q > 1; d++) { q = parent[q]; if (q == s) { print p; break } } } }')
  # The nearest folder named for a ticket: <prefix-><digits>-… or <digits>-…
  ticket_tree() {
    local p="$1"
    while [ "$p" != / ] && [ -n "$p" ]; do
      basename "$p" | grep -E '^([A-Za-z]+-)?[0-9]+-' >/dev/null && { printf '%s' "$p"; return 0; }
      p=$(dirname "$p")
    done
    return 1
  }
  OWN=$(servers | while read -r pid ppid age cwd; do
    grep -qx "$pid" <<<"$MINE" || continue
    tree=$(ticket_tree "$cwd") || continue
    echo "$pid $ppid $age $tree"
  done)
  [ -n "$OWN" ] || exit 0
  KEEP=$(sort -k3,3n <<<"$OWN" | awk 'NF { print $4; exit }')
  awk -v k="$KEEP" 'NF && $4 != k { print $1, $2, $4 }' <<<"$OWN" \
    | stop_all "its agent has moved on to $(basename "$KEEP")"
  exit 0
fi

# ---- sweep: positive proof only -----------------------------------------------
if [ -z "${STOP_DEV_BRANCH_PREFIX+x}" ] || [ -z "${STOP_DEV_CLAIMED+x}" ]; then
  . "$HERE/toolkit-env.sh" >/dev/null 2>&1 || { echo "stop-dev-servers: no repo here — stopping nothing"; exit 0; }
fi
PREFIX="${STOP_DEV_BRANCH_PREFIX:-${BRANCH_PREFIX:-}}"
[ -n "$PREFIX" ] || { echo "stop-dev-servers: no branch prefix — cannot tell a ticket worktree, stopping nothing"; exit 0; }
. "$HERE/claim-proc.sh" || exit 0
. "$HERE/claim-liveness.sh" || exit 0
THIS_HOST=$(claim_host)
STATE="${STOP_DEV_STATE_DIR:-${STATE_DIR:-}}"
if [ -n "${STOP_DEV_CLAIMED+x}" ]; then
  [ "$STOP_DEV_CLAIMED" = FAIL ] && { echo "stop-dev-servers: the claims could not be read — stopping nothing"; exit 0; }
  CLAIMED="$STOP_DEV_CLAIMED"
  # A fixture's claim list must never be judged against the machine's real claims.
  RECORDS="${STOP_DEV_CLAIM_RECORDS:-[]}"
else
  # Time-limited: this runs inside /claim, and a stalled network must not hang it.
  CLAIMED=$(perl -e 'alarm shift; exec @ARGV' 20 git -C "$MAIN_REPO" ls-remote origin 'refs/claims/*' 2>/dev/null) \
    || { echo "stop-dev-servers: the claims could not be read from origin — stopping nothing"; exit 0; }
  CLAIMED=$(printf '%s\n' "$CLAIMED" | sed -n 's#.*refs/claims/\([0-9][0-9]*\)$#\1#p')
fi

# Every working directory on the machine that is NOT a server, its launcher, or
# anything they started: a shell, an editor, an agent — somebody there. A real
# Next server runs turbopack/webpack workers in its own folder; counted as
# occupants they made every server's worktree read as busy, and the sweep
# stopped nothing (review round 2 on #11167).
PS=$(ps -axo pid=,ppid=,command= 2>/dev/null)
ROOTS=$(printf '%s\n' "$PS" | while read -r pid ppid cmd; do
  { is_server "$cmd" || is_launcher "$cmd"; } && echo "$pid"
done)
SERVERS=$(printf '%s\n' "$PS" | while read -r pid ppid cmd; do is_server "$cmd" && echo "$pid"; done)
OURS=$(printf '%s\n' "$PS" | awk -v roots="$(printf '%s ' $ROOTS)" -v srv="$(printf '%s ' $SERVERS)" '
  BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) root[r[i]] = 1
          m = split(srv, s, " "); for (i = 1; i <= m; i++) server[s[i]] = 1 }
  { parent[$1] = $2; c = $0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+/, "", c); cmd[$1] = c }
  END {
    for (p in parent) { q = p; for (d = 0; d < 64 && q > 1; d++) { if (q in root) { print p; break } q = parent[q] } }
    # The npm / node / `sh -c next` chain that launched a server is the server, not somebody there.
    for (p in server) { q = parent[p]
      for (d = 0; d < 16 && q > 1 && (q in cmd); d++) {
        c = cmd[q]
        if (c ~ /claude/) break
        if (c !~ /^([^ ]*\/)?(npm|npx|pnpm|yarn|node)( |$)/ && c !~ /^npm-cli/ && c !~ /^([^ ]*\/)?(ba|z|da)?sh -c (exec )?next( |$)/) break
        print q; q = parent[q] } } }')
# lsof already reports resolved paths, so one join does it — not one lookup per process.
OCCUPIED=$({ printf '%s\n' "$OURS" | sed 's/^/O\t/'; printf '%s\n' "$CWDS" | sed 's/^/C\t/'; } \
  | awk -F'\t' '$1 == "O" { ours[$2] = 1; next } $1 == "C" && !($2 in ours) && $3 != "/" { print $3 }' | sort -u)

occupied() { local o; while read -r o; do [ -n "$o" ] && inside "$o" "$1" && return 0; done <<<"$OCCUPIED"; return 1; }

# Read once, and only when a claimed ticket has a server: list --json fetches.
RECORDS="${RECORDS-}" RECORDS_READ=0
records() {
  [ "$RECORDS_READ" = 1 ] && return 0
  RECORDS_READ=1
  [ -n "$RECORDS" ] && return 0
  # Judged by its output: list --json prints every claim and can still exit 1.
  RECORDS=$(perl -e 'alarm shift; exec @ARGV' 20 bash "$HERE/claim-lock.sh" list --json 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$RECORDS" || RECORDS="[]"
}

# 0 only on proof the holder is gone; a claim from another host or with no record keeps the server.
holder_gone() { # <ticket>
  local rec run host pid
  records
  rec=$(jq -c --arg n "$1" '[.[] | select((.issue | tostring) == $n)][0] // empty' <<<"$RECORDS" 2>/dev/null)
  [ -n "$rec" ] || return 1
  run=$(jq -r '.run_id // empty' <<<"$rec")
  [ -n "$run" ] && [ -n "$STATE" ] && [ -f "$STATE/runs/$run.ended" ] && return 0
  host=$(jq -r '.host // empty' <<<"$rec"); pid=$(jq -r '.pid // empty' <<<"$rec")
  [ "$host" = "$THIS_HOST" ] || return 1
  case "$pid" in ''|null|*[!0-9]*) return 1 ;; esac
  if [ "$pid" != "${CLAIM_EXITED_PID:-}" ]; then claim_pid_alive "$pid" && return 1; fi
  claim_run_fresh "$1" "$STATE" && return 1
  return 0
}

servers | while read -r pid ppid age cwd; do
  # 1. which ticket worktree, if any: the nearest folder named <prefix><digits>-…
  tree="" n="" p="$cwd"
  while [ "$p" != / ] && [ -n "$p" ]; do
    base=$(basename "$p")
    # /claim names the folder ${TICKET,,}-…, which carries the prefix only when
    # the ticket was given with it: both sh-10576-… and 10576-… are ticket folders.
    case "$base" in "$PREFIX"[0-9]*-*|[0-9]*-*)
      n=$(printf '%s' "${base#"$PREFIX"}" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p')
      [ -n "$n" ] && { tree="$p"; break; } ;;
    esac
    p=$(dirname "$p")
  done
  [ -n "$tree" ] || continue
  # 2. its ticket is not claimed. (Not `printf | grep -q`: under pipefail a grep
  # that stops at its first match breaks the pipe behind it, and the pipeline
  # then reads as "no match" — which in step 3 stopped a server under somebody.)
  claimed=0; grep -qx "$n" <<<"$CLAIMED" && claimed=1
  # 3. nobody sitting in it
  occupied "$tree" && continue
  # 4. old enough
  [ "$age" -ge "$MIN_AGE" ] || continue
  # 2, claimed: its holder is gone. Last, because reading the records fetches.
  [ "$claimed" = 0 ] || holder_gone "$n" || continue
  echo "$pid $ppid $tree"
done | stop_all "no live claim holds its ticket, nobody is working there"
exit 0
