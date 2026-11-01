#!/usr/bin/env bash
# claim-proc.sh — the process and host facts the claim scripts depend on, asked
# the one way that works on macOS, Linux AND Windows (Git Bash / MSYS).
#
#   . "$(dirname "${BASH_SOURCE[0]}")/claim-proc.sh"
#
# A claim is only as good as the pid it records: reconcile-claims.sh tests that
# pid to decide whether the holder is alive, and a holder that reads dead with no
# pushed branch is RELEASED to the next agent. On Windows all three questions had
# a Unix-only answer, and together they made every claim read dead on arrival:
# `hostname -s` is refused, MSYS `ps` has no -o (so the walk to the claude
# ancestor fell back to $PPID), and a bash whose parent is the native claude.exe
# sees PPID 1 — which `kill -0` calls "no such process".

claim_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

claim_host() {
  hostname -s 2>/dev/null || hostname 2>/dev/null | cut -d. -f1
}

# A Windows claim may carry a NATIVE pid (see claim_win_session_pid), which only
# the Windows process table knows; `ps -W` lists it in its WINPID column. A
# native pid that equals a live MSYS pid reads alive — the safe direction, since
# the reconciler treats alive as leave-it-alone.
claim_pid_alive() { # <pid>
  case "${1:-}" in ''|null|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null && return 0
  claim_is_windows || return 1
  ps -W 2>/dev/null | awk -v p="$1" 'NR > 1 && $4 == p { f = 1 } END { exit !f }'
}

# ---- is this pid still the process that was recorded? ------------------------
# A pid is identity only together with when its process started. macOS hands
# pids out from a wrapping counter, so a record whose process died long ago can
# name a stranger, and `kill -0` answers for it: a run closed 18 days earlier
# held a build place because its pid had become siriactionsd. A reused pid always
# belongs to a process YOUNGER than the record, so the test is one-sided: the
# process must have started no later than the record's moment + PID_BORN_SLACK.
# The start is read from `ps -o etime=` (the same on BSD and procps, and free of
# the locale `lstart` prints in). Anything unreadable counts as the process:
# alive is the safe direction for every caller (a place counted, a lock held).
_CLAIM_PROC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)

proc_born() { # <pid> — the epoch its process started; 1 when unreadable
  local et d=0 h=0 m=0 s=0
  et=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')
  case "$et" in
    *-*:*:*) d=${et%%-*}; et=${et#*-}; h=${et%%:*}; et=${et#*:}; m=${et%%:*}; s=${et#*:} ;;
    *:*:*)   h=${et%%:*}; et=${et#*:}; m=${et%%:*}; s=${et#*:} ;;
    *:*)     m=${et%%:*}; s=${et#*:} ;;
    *) return 1 ;;
  esac
  case "$d$h$m$s" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $(( $(date +%s) - ((10#$d * 24 + 10#$h) * 60 + 10#$m) * 60 - 10#$s ))
}

pid_born_by() { # <pid> <epoch> — it answers, and its process started by <epoch> (+ slack)
  claim_pid_alive "${1:-}" || return 1
  local ref="${2:-}" born
  case "$ref" in ''|*[!0-9]*|0) return 0 ;; esac
  born=$(proc_born "$1") || return 0
  [ "$born" -le $(( ref + ${PID_BORN_SLACK:-120} )) ]
}

pid_is_run() { # <pid> <ISO time the record was made, e.g. a run's started_at>
  local ref=""
  if [ -n "${2:-}" ]; then
    type swarm_epoch >/dev/null 2>&1 || . "$_CLAIM_PROC_DIR/../swarm/time.sh" 2>/dev/null
    type swarm_epoch >/dev/null 2>&1 && ref=$(swarm_epoch "$2")
  fi
  pid_born_by "${1:-}" "$ref"
}

pid_file_alive() { # <pid-file> [pid] — the pid it holds (its first word) answers and started by the file's writing
  local p="${2:-}" ref
  [ -n "$p" ] || { read -r p _ < "$1"; } 2>/dev/null
  ref=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)
  pid_born_by "$p" "$ref"
}

# One row of MSYS `ps -p <pid>`: "<pid> <ppid> <pgid> <winpid> …", after the
# status letter MSYS sometimes prints in front of it.
_claim_msys_ps_field() { # <pid> <field#>
  ps -p "$1" 2>/dev/null | awk -v n="$2" 'NR == 2 { sub(/^[[:space:]]*[A-Z][[:space:]]+/, ""); split($0, f); print f[n] }'
}

# The Windows pid of the claude.exe this shell runs under — or, with none, of the
# nearest ancestor that is not a shell (npm's node, a terminal), which outlives
# the command the way $PPID does on Unix (~0.5s, once a claim).
#
# Two trees, walked in order. MSYS emulates fork, so a child bash's Windows
# parent is an intermediate that has already exited and the Windows chain breaks
# there; the MSYS tree is intact. So climb MSYS parents to the top shell (PPID 1,
# i.e. launched by a native process), then walk the Windows tree from its pid.
claim_win_session_pid() {
  claim_is_windows || return 1
  local p=$$ pp w out i=0
  while [ "$i" -lt 64 ]; do
    pp=$(_claim_msys_ps_field "$p" 2)
    case "$pp" in ''|*[!0-9]*|1|0) break ;; esac
    p=$pp; i=$((i+1))
  done
  w=$(_claim_msys_ps_field "$p" 4)
  case "$w" in ''|*[!0-9]*) w=$(cat "/proc/$$/winpid" 2>/dev/null) ;; esac
  case "$w" in ''|*[!0-9]*) return 1 ;; esac
  out=$(powershell.exe -NoProfile -NonInteractive -Command "\$p=$w; \$near=0; for(\$i=0; \$i -lt 32; \$i++){ \$x=Get-CimInstance Win32_Process -Filter \"ProcessId=\$p\"; if(-not \$x){ break }; if(\$x.Name -eq 'claude.exe'){ \$p; exit 0 }; if(\$i -gt 0 -and \$near -eq 0 -and \$x.Name -notmatch '^(bash|sh|dash)\.exe$'){ \$near=\$p }; \$p=\$x.ParentProcessId }; if(\$near){ \$near; exit 0 }; exit 1" 2>/dev/null | tr -d '\r')
  case "$out" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$out"
}

# The pid a claim records, which reconcile-claims.sh tests to decide whether the
# holder is still alive. It therefore has to name a process that lives as long
# as the AGENT, not as long as the command.
#
# `$$` does not. Every tool call gets a fresh shell that exits the moment the
# call returns, so a claim stamped with `$$` reads as abandoned within seconds
# of being taken. Measured: a claim recorded pid 75901; one call later that pid
# was already dead. An agent that had claimed a ticket but not yet pushed a
# branch fell straight through the reconciler's evidence checks to RELEASED, and
# a peer picked up work already in progress — twice in one session.
claim_session_pid() {
  # A spawned run names its session outright: spawn-claim.sh exports the pid of
  # the wrapper subshell that `wait`s on the agent, alive exactly as long as it.
  if [ -n "${CLAIM_SESSION_PID:-}" ] && claim_pid_alive "$CLAIM_SESSION_PID"; then
    printf '%s' "$CLAIM_SESSION_PID"; return 0
  fi
  # Walk up to the nearest `claude` ancestor, which is the session itself.
  local p=$$ cmd
  while [ "$p" -gt 1 ]; do
    cmd=$(ps -o comm= -p "$p" 2>/dev/null) || break
    case "$cmd" in *claude*) printf '%s' "$p"; return 0 ;; esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] || break
  done
  # Windows: the walk above stops at once (no `ps -o`), and $PPID is 1 under a
  # native claude.exe — so ask the Windows process table instead.
  p=$(claim_win_session_pid) && { printf '%s' "$p"; return 0; }
  # No claude ancestor (a cron or a bare shell). $PPID at least outlives the
  # innermost subshell, and a wrong-but-live pid is safer here than a dead one:
  # the reconciler treats "alive" as leave-it-alone.
  printf '%s' "$PPID"
}
