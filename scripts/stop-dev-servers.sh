#!/usr/bin/env bash
# stop-dev-servers.sh — stop the Next.js servers agents leave behind.
#
#   stop-dev-servers.sh --worktree <path>        stop every server running inside <path>
#   stop-dev-servers.sh --sweep [--dry-run]      stop servers in ticket worktrees nobody holds
#   stop-dev-servers.sh --session <pid> [--dry-run]  one preview per agent: stop the
#                                                servers <pid> started in every worktree
#                                                but the one it started a server in last
#   stop-dev-servers.sh --strays [--dry-run]     reap ANY process left running in a
#                                                worktree nothing owns (see "strays" below)
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
    --strays) MODE=strays; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "stop-dev-servers: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "usage: stop-dev-servers.sh --worktree <path> | --sweep [--dry-run] | --session <pid> [--dry-run] | --strays [--dry-run]" >&2; exit 2; }
# WSL images often ship without lsof; /proc says the same thing there.
command -v lsof >/dev/null || [ -d /proc/self/cwd ] \
  || { echo "stop-dev-servers: no lsof and no /proc here — cannot see working directories, stopping nothing"; exit 0; }

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
read_cwds() {
  if command -v lsof >/dev/null; then
    lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}'
  else
    local d c; for d in /proc/[0-9]*; do c=$(readlink "$d/cwd" 2>/dev/null) && printf '%s\t%s\n' "${d#/proc/}" "$c"; done
  fi
}
CWDS=$(read_cwds)
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

# ---- strays: any process left in a worktree nothing owns ------------------------
# The sweep above stops Next servers only. A test run, a type check or a watcher
# outlives its ticket just as well: on 2026-10-22 a `ci-tooling-scope/test.sh` sat
# 12h29m at 95% of a core in a closed ticket's worktree, beside a 3-day tsc and a
# 6-day vitest, all reparented to launchd — CPU the coordinator counts as taken.
#
# A process is a stray when its cwd (or a path in its argv) is inside a worktree
# under the project's worktree root (ticket folders only, as above) or the harness
# worktree root (every folder: only builds live there), and ALL of:
#   - it is not a person's: walking up its ancestry, a terminal host (VS Code,
#     Terminal, iTerm, tmux, sshd, login) or a login shell with no `claude` above it
#     comes before any `claude`. A process whose nearest such ancestor is a `claude`
#     — an agent session, a VS Code extension session, a subagent's Bash — is AGENT
#     WORK: kept only under a live claim or run (or anywhere in the harness root,
#     whose builders have neither) and only up to the max age, however
#     alive its session is (the 12-hour test script was a VS Code session's
#     subagent's). An agent session (`claude`) itself is never a stray;
#   - it is older than STOP_DEV_STRAY_MIN_AGE (coordinator.strayMinAgeMin, 30 min);
#   - its worktree has no live run (runs/<id>.worktrees, no .ended, pid alive) and,
#     for a ticket folder, no live claim (the rule `holder_gone` applies above) and
#     no fresh driver state;
#   - nobody sits there: no interactive or agent process has its cwd in it — or one
#     does, the claim is gone, and the process is past STOP_DEV_STRAY_MAX_AGE
#     (coordinator.strayMaxAgeMin, 3 h).
# A stray gets TERM, then KILL after STOP_DEV_STRAY_GRACE seconds. Next servers
# and their launchers are left to the server sweep.
if [ "$MODE" = strays ]; then
  STRAY_MIN="${STOP_DEV_STRAY_MIN_AGE:-1800}" STRAY_MAX="${STOP_DEV_STRAY_MAX_AGE:-10800}" GRACE="${STOP_DEV_STRAY_GRACE:-10}"
  for v in "$STRAY_MIN" "$STRAY_MAX" "$GRACE"; do
    case "$v" in ''|*[!0-9]*) echo "strays: an age or grace setting is not a whole number ('$v') — reaping nothing"; exit 0 ;; esac
  done
  if [ -n "${STOP_DEV_PROJECT_ROOT+x}" ]; then PROOT="$STOP_DEV_PROJECT_ROOT"
  else PROOT=$(toolkit_worktree_root 2>/dev/null) || PROOT=""; fi
  HROOT="${STOP_DEV_HARNESS_ROOT-$HOME/.harness-worktrees}"
  [ -z "$PROOT" ] || [ ! -d "$PROOT" ] || PROOT=$(real "$PROOT")
  [ -z "$HROOT" ] || [ ! -d "$HROOT" ] || HROOT=$(real "$HROOT")
  [ -n "$PROOT$HROOT" ] || { echo "strays: no worktree root to look in — reaping nothing"; exit 0; }

  # This script and everything above it, whatever their cwd.
  SELF_CHAIN=$(ps -axo pid=,ppid= 2>/dev/null | awk -v s="$$" '{ parent[$1] = $2 } END { q = s; for (d = 0; d < 64 && q > 1; d++) { print q; q = parent[q] } }')

  # One pass over the process table: "<class>\t<pid>\t<age>\t<cpu>\t<kind>\t<worktree>\t<command>".
  # class: I a person, A agent session, G agent work, S server, C candidate.
  ROWS=$({ printf '%s\n' "$CWDS" | sed 's/^/W\t/'
           printf '%s\n' "$SELF_CHAIN" | sed 's/^/M\t/'
           ps -axo pid=,ppid=,etime=,pcpu=,command= 2>/dev/null | sed 's/^/P\t/'; } \
    | awk -F'\t' -v proot="$PROOT" -v hroot="$HROOT" -v prefix="$PREFIX" '
    function secs(e,   d, n, a) { d = 0
      if (index(e, "-")) { d = substr(e, 1, index(e, "-") - 1); e = substr(e, index(e, "-") + 1) }
      n = split(e, a, ":")
      if (n == 3) return d * 86400 + a[1] * 3600 + a[2] * 60 + a[3]
      return d * 86400 + a[1] * 60 + a[2] }
    # The worktree <path> is in, as "<kind>\t<worktree>", or "".
    function tree(path,   root, kind, i, rest, name) {
      for (i = 1; i <= 2; i++) {
        root = (i == 1 ? first : second); kind = (i == 1 ? firstk : secondk)
        if (root == "" || index(path "/", root "/") != 1) continue
        rest = substr(path, length(root) + 2); if (rest == "") return ""
        name = rest; sub(/\/.*/, "", name)
        if (kind == "project") { n = name; if (prefix != "" && index(n, prefix) == 1) n = substr(n, length(prefix) + 1)
          if (n !~ /^[0-9]+-/) return "" }
        return kind "\t" root "/" name }
      return "" }
    function argv_tree(c,   i, root, j, rest, t) {
      for (i = 1; i <= 2; i++) {
        root = (i == 1 ? first : second); if (root == "") continue
        j = index(c, root "/"); if (!j) continue
        rest = substr(c, j); sub(/[ \t"'"'"':;=].*/, "", rest)
        t = tree(rest); if (t != "") return t }
      return "" }
    function login_shell(c) { return c ~ /^-[a-z]*sh( |$)/ }
    function interactive(c) {
      return c ~ /^(\/usr\/bin\/)?login( |$)/ ||
             c ~ /Visual Studio Code|Code Helper|\.vscode-server\/|code-server|Cursor\.app|Terminal\.app|iTerm|Warp\.app|^(\/[^ ]*\/)?tmux|^(\/[^ ]*\/)?screen( |$)|^sshd:/ }
    function agent(c) { return c ~ /^([^ ]*\/)?claude( |$)/ }
    function server(c) { return c ~ /^next-(server|build)/ || c ~ /^node [^ ]*\/next (dev|start)/ || c ~ /next\/dist\/bin\/next / ||
                                c ~ /^(npm exec next|npx next)/ }
    BEGIN { # the longer root first, so a project root nested in the harness root wins
      if (length(proot) >= length(hroot)) { first = proot; firstk = "project"; second = hroot; secondk = "harness" }
      else { first = hroot; firstk = "harness"; second = proot; secondk = "project" } }
    $1 == "W" { cwd[$2] = $3; next }
    $1 == "M" { mine[$2] = 1; next }
    $1 == "P" { line = substr($0, 3); sub(/^[ \t]+/, "", line)
      split(line, f, /[ \t]+/); pid = f[1]; ppid[pid] = f[2]; et[pid] = f[3]; cpu[pid] = f[4]
      c = line; for (k = 1; k <= 4; k++) sub(/^[^ \t]+[ \t]+/, "", c); cmd[pid] = c; order[++np] = pid }
    END {
      for (i = 1; i <= np; i++) { p = order[i]
        if (p in mine) continue
        t = (p in cwd) ? tree(cwd[p]) : ""
        bycwd = (t != "")
        if (t == "") t = argv_tree(cmd[p])
        if (t == "") continue
        # The nearest marker wins: a claude above it makes it agent work (G), a terminal
        # host makes it a person (I). A login shell counts as a person only with no claude
        # above it (on WSL it sits under /init, with no host to see).
        cls = "C"; q = p; shell = 0
        for (d = 0; d < 64 && q > 1 && (q in cmd); d++) {
          if (agent(cmd[q])) { cls = (q == p ? "A" : "G"); break }
          if (interactive(cmd[q])) { cls = "I"; break }
          if (login_shell(cmd[q])) shell = 1
          q = ppid[q] }
        if (cls == "C" && shell) cls = "I"
        if ((cls == "C" || cls == "G") && server(cmd[p])) cls = "S"
        # Only somebody whose cwd is there is sitting there; an argv mention is not.
        if ((cls == "I" || cls == "A") && !bycwd) cls = cls "x"
        printf "%s\t%s\t%d\t%s\t%s\t%s\n", cls, p, secs(et[p]), cpu[p], t, cmd[p] } }')

  # Worktrees somebody sits in: a person's process or an agent session, never agent work.
  SEATED=$(awk -F'\t' '$1 == "I" || $1 == "A" { print $6 }' <<<"$ROWS" | sort -u)
  # Worktrees a live run names. A run with no .ended whose pid is dead owns nothing.
  LIVE_RUNS=""
  if [ -n "$STATE" ] && [ -d "$STATE/runs" ]; then
    for f in "$STATE"/runs/*.worktrees; do
      [ -f "$f" ] || continue
      rid="${f%.worktrees}"; [ -e "$rid.ended" ] && continue
      pids=$(jq -r '[.pid, .child_pid] | map(select(. != null)) | .[]' "$rid.json" 2>/dev/null)
      live=0; for p in $pids; do claim_pid_alive "$p" && live=1; done
      [ "$live" = 1 ] || continue
      while read -r w; do [ -n "$w" ] && LIVE_RUNS="$LIVE_RUNS$(real "$w")"$'\n'; done < "$f"
    done
  fi
  run_owns() { local w; while read -r w; do [ -n "$w" ] && { inside "$w" "$1" || inside "$1" "$w"; } && return 0; done <<<"$LIVE_RUNS"; return 1; }
  # 0 when a live claim (or a fresh driver run) holds this ticket folder.
  claim_holds() { # <worktree>
    local n base; base=$(basename "$1"); n=$(printf '%s' "${base#"$PREFIX"}" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p')
    [ -n "$n" ] || return 1
    claim_run_fresh "$n" "$STATE" && return 0
    grep -qx "$n" <<<"$CLAIMED" || return 1
    holder_gone "$n" && return 1
    return 0
  }

  hits=0 inwt=0 young=0 harness=0 owned=0 seated=0 inter=0 REAP=()
  while IFS=$'\t' read -r cls pid age cpu kind wt cmd; do
    [ -n "$pid" ] || continue
    inwt=$((inwt+1))
    case "$cls" in I|Ix) inter=$((inter+1)); continue ;; C|G) ;; *) continue ;; esac
    [ "$age" -ge "$STRAY_MIN" ] || { young=$((young+1)); continue; }
    if [ "$cls" = G ]; then
      # Agent work: a live claim or run keeps it up to the cap, nothing else does.
      if [ "$age" -ge "$STRAY_MAX" ]; then why="agent work past the $((STRAY_MAX / 60))-minute cap"
      elif run_owns "$wt" || { [ "$kind" = project ] && claim_holds "$wt"; }; then owned=$((owned+1)); continue
      # Harness builders work there with no claim or run record, and one test run takes
      # ~25 minutes under load: their work keeps to the cap, not the minimum age.
      elif [ "$kind" = harness ]; then harness=$((harness+1)); continue
      else why="agent work with no live claim or run on its worktree"; fi
    else
    run_owns "$wt" && { owned=$((owned+1)); continue; }
    if [ "$kind" = project ] && claim_holds "$wt"; then owned=$((owned+1)); continue; fi
    why="no live claim or run owns its worktree, nobody is working there"
    if grep -qxF "$wt" <<<"$SEATED"; then
      [ "$age" -ge "$STRAY_MAX" ] || { seated=$((seated+1)); continue; }
      why="its worktree's claim is gone and it is past the $((STRAY_MAX / 60))-minute cap"
    fi
    fi
    line=$(printf 'pid %s, %dm old, %s%% CPU, in %s — %s: %.160s' "$pid" $((age / 60)) "$cpu" "$wt" "$why" "$cmd")
    hits=$((hits+1))
    if [ "$DRY" = 1 ]; then echo "strays: would reap $line"; continue; fi
    kill -TERM "$pid" 2>/dev/null && { REAP+=("$pid"); echo "strays: reaped $line"; }
  done <<<"$ROWS"
  if [ ${#REAP[@]} -gt 0 ]; then
    for _ in $(seq 1 "$GRACE"); do
      left=0
      for p in "${REAP[@]}"; do   # a zombie is reaped already, it only waits on its parent
        kill -0 "$p" 2>/dev/null || continue
        case "$(ps -o stat= -p "$p" 2>/dev/null)" in *Z*) ;; *) left=1 ;; esac
      done
      [ "$left" = 0 ] && break; sleep 1
    done
    for p in "${REAP[@]}"; do kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null && echo "strays: $p ignored TERM for ${GRACE}s — killed"; done
  fi
  verb=reaped; [ "$DRY" = 1 ] && verb="would reap"
  echo "strays: $verb $hits of $inwt process(es) in worktrees; kept $owned owned by a live claim or run, $young under $((STRAY_MIN / 60))m, $seated with somebody working there, $harness harness agent work under the cap, $inter interactive"
  exit 0
fi

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
