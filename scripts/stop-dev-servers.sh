#!/usr/bin/env bash
# stop-dev-servers.sh — stop the Next.js servers agents leave behind.
#
#   stop-dev-servers.sh --worktree <path>        stop every server running inside <path>
#   stop-dev-servers.sh --sweep [--dry-run]      stop servers in worktrees no live claim holds
#
# Each agent starts a web and an api server to render its screen, and nothing
# stopped them when the ticket shipped. Measured on 2026-09-30: 16 servers up to
# six days old, swap at 44 GB of 45, and one worktree holding three. Stopping the
# ten oldest halved swap. So /finish stops its own worktree's servers, and the
# sweep — run at the end of every reconcile — stops what a crashed or abandoned
# window left.
#
# The sweep NEVER touches:
#   - a server inside a worktree a live claim names (someone is working there);
#   - a server outside the repo's own worktrees (the owner's `npm run dev`);
#   - a server younger than the minimum age (default 2 hours), so a window that
#     is mid-claim, between taking the ref and writing its worktree, is safe.
# When it cannot tell — no repo, a claim list it cannot read — it stops nothing.
#
# A server is found by its WORKING DIRECTORY (`lsof -d cwd`), not its command
# line: `next-server` names no path, and matching on the command alone is what
# the harness's broad-kill hook refuses, rightly — it would stop every agent's.
#
# Test overrides: STOP_DEV_WORKTREES (newline list of agent worktrees),
# STOP_DEV_CLAIMS_JSON (a claim-lock `list --json` file), STOP_DEV_MIN_AGE (sec).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIN_AGE="${STOP_DEV_MIN_AGE:-7200}"
MODE="" TARGET="" DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) MODE=worktree; TARGET="${2:-}"; shift 2 ;;
    --sweep) MODE=sweep; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "stop-dev-servers: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: stop-dev-servers.sh --worktree <path> | --sweep [--dry-run]" >&2; exit 2; }

# ps elapsed time, [[dd-]hh:]mm:ss, in seconds.
age_sec() {
  local e="$1" d=0 h=0 m=0 s=0
  case "$e" in *-*) d="${e%%-*}"; e="${e#*-}" ;; esac
  IFS=: read -r a b c <<<"$e"
  if [ -n "${c:-}" ]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#$d * 86400 + 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}

# A path with symlinks resolved, so /tmp and /private/tmp are one place.
real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# "<pid> <ppid> <age-sec> <cwd>" for every Next.js server process.
servers() {
  ps -axo pid=,ppid=,etime=,command= 2>/dev/null | while read -r pid ppid etime cmd; do
    case "$cmd" in
      next-server*|next-build*|*"/next dev"*|*"/next start"*|*"next/dist/bin/next"*|*"exec next "*) ;;
      *) continue ;;
    esac
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [ -n "$cwd" ] || continue
    printf '%s %s %s %s\n' "$pid" "$ppid" "$(age_sec "$etime")" "$(real "$cwd")"
  done
}

inside() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }   # <path> <root>

# Stop a server and, when it is only a launcher for it, the process that started it.
stop() { # <pid> <ppid> <why>
  local pid="$1" ppid="$2" why="$3" pcmd
  if [ "$DRY" = 1 ]; then echo "would stop $pid — $why"; return; fi
  pcmd=$(ps -o command= -p "$ppid" 2>/dev/null || true)
  kill -TERM "$pid" 2>/dev/null || true
  case "$pcmd" in *next*|*"npm exec"*|*"npm run"*) kill -TERM "$ppid" 2>/dev/null || true ;; esac
  for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  echo "stopped $pid — $why"
}

if [ "$MODE" = worktree ]; then
  [ -n "$TARGET" ] && [ -d "$TARGET" ] || { echo "stop-dev-servers: no such worktree '$TARGET'" >&2; exit 0; }
  root=$(real "$TARGET")
  servers | while read -r pid ppid age cwd; do
    inside "$cwd" "$root" && stop "$pid" "$ppid" "its worktree is finishing ($cwd)"
  done
  exit 0
fi

# ---- sweep ------------------------------------------------------------------
if [ -n "${STOP_DEV_WORKTREES+x}" ]; then
  WORKTREES="$STOP_DEV_WORKTREES"
else
  . "$HERE/toolkit-env.sh" >/dev/null 2>&1 || { echo "stop-dev-servers: no repo here — stopping nothing"; exit 0; }
  main=$(real "$MAIN_REPO")
  WORKTREES=$(git -C "$MAIN_REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while read -r w; do [ "$(real "$w")" = "$main" ] || real "$w"; echo; done)
fi
if [ -n "${STOP_DEV_CLAIMS_JSON:-}" ]; then
  claims=$(cat "$STOP_DEV_CLAIMS_JSON" 2>/dev/null)
else
  claims=$(bash "$HERE/claim-lock.sh" list --json 2>/dev/null)
fi
printf '%s' "$claims" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "stop-dev-servers: the claims could not be read — stopping nothing"; exit 0; }
HELD=$(printf '%s' "$claims" | jq -r '.[].worktree // empty' | while read -r w; do [ -n "$w" ] && real "$w" && echo; done)

servers | while read -r pid ppid age cwd; do
  tree=""
  while read -r w; do [ -n "$w" ] && inside "$cwd" "$w" && { tree="$w"; break; }; done <<<"$WORKTREES"
  [ -n "$tree" ] || continue                                   # not an agent worktree
  held=0
  while read -r h; do [ -n "$h" ] && inside "$cwd" "$h" && { held=1; break; }; done <<<"$HELD"
  [ "$held" = 0 ] || continue                                  # someone is working there
  [ "$age" -ge "$MIN_AGE" ] || continue                        # too young to judge
  stop "$pid" "$ppid" "no claim holds $tree, up $(( age / 60 )) min"
done
exit 0
