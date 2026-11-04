#!/usr/bin/env bash
# builder-dev.sh — the dev server of one builder's tree, started and stopped by the driver.
#
#   builder-dev.sh start <tree> [--wait <sec>]   start it (or find it running); prints its URL
#   builder-dev.sh stop <tree>                   stop it and everything it started
#   builder-dev.sh status <tree>                 prints its URL; exit 1 when none runs
#   builder-dev.sh list                          "<port>\t<pgid>\t<tree>" for each one running
#
# WHY. Builders started their own servers and stopped them with pkill patterns, so one
# agent's `pkill -f 'next dev'` killed four peers' servers (2026-09-24) and a long loop
# left a preview in every tree it passed through (54 servers in 11 trees on 2026-10-15).
# The harness grew a hook refusing broad kills and another sweeping previews. Here each
# server runs in a PROCESS GROUP OF ITS OWN, recorded beside the port it holds; stop
# signals that group and nothing else, so it cannot reach a peer however its commands
# are named, and every child the server started goes with it.
#
# The port is the tree's ticket's (3000 + ticket mod 1000), or the next free one. It is
# reserved by an atomic mkdir in the record directory (BUILDER_DEV_DIR,
# ~/.cache/agent-harness/dev), so two builders starting at once never take the same one;
# a record whose group is gone is free again.
#
# The command: BUILDER_DEV_CMD, else harness.json `worktree.dev`, else `npm run dev` when
# the root package.json has a dev script. PORT is set in its environment (Next and most
# dev servers read it). No command: exit 3, nothing started.
set -uo pipefail
DEV_DIR="${BUILDER_DEV_DIR:-$HOME/.cache/agent-harness/dev}"
say() { echo "builder-dev: $*" >&2; }

real() { (cd "$1" 2>/dev/null && pwd -P); }
group_alive() { [ -n "${1:-}" ] && kill -0 -- "-$1" 2>/dev/null; }
port_free() { # <port> — nothing on this host listens there, on any address
  ! port_open "$1" && node -e 'const s = require("net").createServer(); s.once("error", () => process.exit(1));
    s.listen(+process.argv[1], () => s.close(() => process.exit(0)))' "$1" 2>/dev/null
}
port_open() { # <port> — something accepts a connection there
  node -e 'const c = require("net").connect(+process.argv[1], "127.0.0.1"); c.once("connect", () => process.exit(0));
    c.once("error", () => process.exit(1)); setTimeout(() => process.exit(1), 1000)' "$1" 2>/dev/null
}

dev_cmd() { # <tree>
  local cfg="${HARNESS_CFG_PATH:-$1/.claude/harness.json}" c=""
  if [ -n "${BUILDER_DEV_CMD:-}" ]; then printf '%s' "$BUILDER_DEV_CMD"; return 0; fi
  [ -f "$cfg" ] && c=$(jq -r '.worktree.dev // empty' "$cfg" 2>/dev/null)
  if [ -n "$c" ]; then printf '%s' "$c"; return 0; fi
  jq -e '.scripts.dev // empty' "$1/package.json" >/dev/null 2>&1 && { printf 'npm run dev'; return 0; }
  return 1
}

# records <tree> — the port of each live record for the tree; a dead record is removed.
records() {
  local r t g
  for r in "$DEV_DIR"/[0-9]*; do
    [ -d "$r" ] || continue
    t=$(cat "$r/tree" 2>/dev/null); g=$(cat "$r/pgid" 2>/dev/null)
    if [ -n "$g" ] && ! group_alive "$g"; then rm -rf "$r"; continue; fi
    # A reservation still being written (no pgid yet) belongs to whoever is writing it.
    [ -z "${1:-}" ] || [ "$t" = "$1" ] || continue
    if [ -z "$g" ]; then
      # …unless it has been unwritten for a minute: the writer died between mkdir and pgid.
      [ $(( $(date +%s) - $(stat -f %m "$r" 2>/dev/null || stat -c %Y "$r" 2>/dev/null || date +%s) )) -lt 60 ] || rm -rf "$r"
      continue
    fi
    printf '%s\n' "${r##*/}"
  done
}

stop_group() { # <pgid>
  local g="$1" i=0
  group_alive "$g" || return 0
  kill -TERM -- "-$g" 2>/dev/null
  while group_alive "$g" && [ "$i" -lt "${BUILDER_DEV_STOP_SEC:-10}" ]; do sleep 1; i=$((i + 1)); done
  group_alive "$g" && kill -KILL -- "-$g" 2>/dev/null
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    mkdir -p "$DEV_DIR" 2>/dev/null
    for p in $(records ""); do printf '%s\t%s\t%s\n' "$p" "$(cat "$DEV_DIR/$p/pgid")" "$(cat "$DEV_DIR/$p/tree")"; done
    exit 0 ;;
  start|stop|status) ;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
TREE=$(real "${1:-}") || { say "no such tree '${1:-}'"; exit 2; }
[ -n "$TREE" ] || { say "usage: builder-dev.sh $cmd <tree>"; exit 2; }
shift
WAIT=0
while [ $# -gt 0 ]; do case "$1" in --wait) WAIT="${2:-0}"; shift 2 ;; *) say "unknown argument $1"; exit 2 ;; esac; done
mkdir -p "$DEV_DIR" 2>/dev/null || { say "cannot write $DEV_DIR"; exit 1; }

case "$cmd" in
  status)
    p=$(records "$TREE" | head -1)
    [ -n "$p" ] || exit 1
    echo "http://localhost:$p"; exit 0 ;;
  stop)
    n=0
    for p in $(records "$TREE"); do
      stop_group "$(cat "$DEV_DIR/$p/pgid")"; rm -rf "${DEV_DIR:?}/$p"; n=$((n + 1))
    done
    [ "$n" -eq 0 ] || echo "builder-dev: stopped $n server(s) in $TREE"
    exit 0 ;;
esac

# start
p=$(records "$TREE" | head -1)
if [ -n "$p" ]; then echo "http://localhost:$p"; exit 0; fi
c=$(dev_cmd "$TREE") || { say "$TREE has no dev command (worktree.dev, or a dev script) — nothing started"; exit 3; }

ticket=$(basename "$TREE" | sed -n 's/^[A-Za-z_]*-\{0,1\}\([0-9][0-9]*\).*/\1/p')
[ -n "$ticket" ] || ticket="${DRIVER_TICKET:-$(printf '%s' "$TREE" | cksum | cut -d' ' -f1)}"
base=$(( ${BUILDER_DEV_BASE_PORT:-3000} + ticket % 1000 ))
port=""; i=0
records "" >/dev/null   # clears dead reservations first
while [ "$i" -lt 200 ]; do
  cand=$(( base + i )); i=$((i + 1))
  [ "$cand" -lt 65535 ] || cand=$(( ${BUILDER_DEV_BASE_PORT:-3000} + i ))
  mkdir "$DEV_DIR/$cand" 2>/dev/null || continue
  if port_free "$cand"; then port=$cand; break; fi
  rm -rf "${DEV_DIR:?}/$cand"
done
[ -n "$port" ] || { say "no free port from $base"; exit 1; }
R="$DEV_DIR/$port"
printf '%s\n' "$TREE" > "$R/tree"

# setpgrp before exec: the server and every child it starts share a group of their own.
( cd "$TREE" && PORT="$port" exec perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' bash -c "$c" ) \
  > "$R/log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$R/pgid"
disown "$pid" 2>/dev/null || true

if [ "$WAIT" -gt 0 ] 2>/dev/null; then
  i=0
  until port_open "$port"; do
    group_alive "$pid" || { say "the server in $TREE exited before it listened — $(tail -3 "$R/log" | tr '\n' ' ')"; rm -rf "$R"; exit 1; }
    [ "$i" -lt "$WAIT" ] || { say "the server in $TREE is not listening on $port after ${WAIT}s (left running; log $R/log)"; break; }
    sleep 1; i=$((i + 1))
  done
fi
echo "http://localhost:$port"
