#!/usr/bin/env bash
# load.sh — is the machine busy? Sourced by swarm-env.sh and by
# scripts/machine-gate.sh, which must read it without a project config.
#
# BUSY MEANS THE CPU HAS NO ROOM: sampled idle below a floor (swarm.minCpuIdle,
# default 15%). The 1-minute load average is a RUNAWAY GUARD only, at a ceiling
# ordinary work never reaches (swarm.maxLoad, default 20 x cores). On 2026-10-15
# macOS counted 4,898 threads into a load of 40-103 on 10 cores while top showed
# 41% idle, and the old load-only gate turned agents away six times in a row; on
# 2026-10-16 it read 119-140, once 140 at 41% idle, so 8 x cores still blocked.
#
#   swarm_busy <min-idle> <max-load>  prints the reading; 0 when busy, 1 when clear
#   swarm_cpu_idle                    idle percent, sampled over ~1-2s
#   swarm_load                        the 1-minute load average, a whole number
#   swarm_cores                       logical cores
#   swarm_free_mem_gb                 free memory in whole GB, empty when unread
#
# Seams, each read on EVERY call so a test can move them while a waiter polls:
#   SWARM_LOAD / SWARM_LOAD_FILE   a fixed load / a file holding it
#   SWARM_IDLE / SWARM_IDLE_FILE   a fixed idle percent / a file holding it
#   SWARM_CORES                    a fixed core count
#   SWARM_FREE_MEM_GB / _FILE      a fixed free-memory reading / a file holding it
#   SWARM_IDLE_CACHE               where one real sample is shared for 5s
#                                  (default ~/.cache/agent-harness/cpu-idle)
#
# top on macOS, /proc on Linux — the CI runner is Linux and the operator's
# machine is not, so a script that knows only one of them is a script that is
# only ever tested on the other.
swarm_load() {
  if [ -n "${SWARM_LOAD_FILE:-}" ] && [ -f "$SWARM_LOAD_FILE" ]; then
    local f; f=$(head -1 "$SWARM_LOAD_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_LOAD:-}" ]; then printf '%s' "${SWARM_LOAD%%.*}"; return; fi
  local l=""
  l=$(/usr/sbin/sysctl -n vm.loadavg 2>/dev/null | awk '{print int($2)}')
  [ -n "$l" ] || l=$(awk '{print int($1)}' /proc/loadavg 2>/dev/null)
  printf '%s' "${l:-0}"
}

swarm_cores() {
  if [ -n "${SWARM_CORES:-}" ]; then printf '%s' "$SWARM_CORES"; return; fi
  local c=""
  c=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null)
  [ -n "$c" ] || c=$(nproc 2>/dev/null)
  [ -n "$c" ] || c=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  case "$c" in ''|*[!0-9]*|0) c=4 ;; esac
  printf '%s' "$c"
}

# The idle percent from `top -l 2` output on stdin. The FIRST sample is not a
# measurement over the interval, so only the last "CPU usage" line counts.
swarm_parse_top_idle() {
  awk '/^CPU usage:/{l=$0} END{
         if (l == "") exit 1
         n = split(l, w, " ")
         for (i = 2; i <= n; i++) if (w[i] ~ /^idle/) { v = w[i-1]; sub(/%.*/, "", v); printf "%d", v + 0.5; exit 0 }
         exit 1 }'
}

# The idle percent between two /proc/stat "cpu" lines: idle + iowait over all.
swarm_parse_stat_idle() { # <line-before> <line-after>
  awk -v a="$1" -v b="$2" 'BEGIN{
    n = split(a, x, " "); split(b, y, " ")
    for (i = 2; i <= n; i++) t += y[i] - x[i]
    id = (y[5] - x[5]) + (y[6] - x[6])
    if (t <= 0) exit 1
    printf "%d", id * 100 / t + 0.5 }'
}

_swarm_sample_idle() {
  local v="" a b
  if [ -x /usr/bin/top ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    v=$(/usr/bin/top -l 2 -n 0 -s 1 2>/dev/null | swarm_parse_top_idle)
  elif [ -r /proc/stat ]; then
    a=$(grep -m1 '^cpu ' /proc/stat); sleep 1; b=$(grep -m1 '^cpu ' /proc/stat)
    v=$(swarm_parse_stat_idle "$a" "$b")
  fi
  printf '%s' "$v"
}

# Idle percent. A reading nobody could take is 100: the load backstop still holds.
swarm_cpu_idle() {
  if [ -n "${SWARM_IDLE_FILE:-}" ] && [ -f "$SWARM_IDLE_FILE" ]; then
    local f; f=$(head -1 "$SWARM_IDLE_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_IDLE:-}" ]; then printf '%s' "${SWARM_IDLE%%.*}"; return; fi
  local cache="${SWARM_IDLE_CACHE:-$HOME/.cache/agent-harness/cpu-idle}" now at v
  now=$(date +%s)
  if [ -f "$cache" ] && read -r at v < "$cache" && [ -n "${v:-}" ] && [ $(( now - ${at:-0} )) -lt 5 ] 2>/dev/null; then
    printf '%s' "$v"; return
  fi
  v=$(_swarm_sample_idle)
  case "$v" in ''|*[!0-9]*) printf '100'; return ;; esac
  mkdir -p "$(dirname "$cache")" 2>/dev/null \
    && printf '%s %s\n' "$now" "$v" > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null
  printf '%s' "$v"
}

# Free memory in whole GB from `vm_stat` on stdin: free + inactive + speculative
# pages, which macOS hands back on demand. "Pages free" alone reads near zero.
swarm_parse_vm_stat_free_gb() {
  awk '/page size of/{for(i=1;i<=NF;i++) if($i=="of"){ps=$(i+1)}}
       /^Pages (free|inactive|speculative):/{v=$NF; sub(/\./,"",v); p+=v; seen=1}
       END{ if (!seen || ps <= 0) exit 1; printf "%d", p * ps / 1073741824 }'
}

# Free memory in whole GB, or nothing when it could not be read.
#   SWARM_FREE_MEM_GB / SWARM_FREE_MEM_FILE   a fixed reading / a file holding it
swarm_free_mem_gb() {
  if [ -n "${SWARM_FREE_MEM_FILE:-}" ] && [ -f "$SWARM_FREE_MEM_FILE" ]; then
    local f; f=$(head -1 "$SWARM_FREE_MEM_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_FREE_MEM_GB:-}" ]; then printf '%s' "${SWARM_FREE_MEM_GB%%.*}"; return; fi
  local v=""
  if [ -x /usr/bin/vm_stat ]; then
    v=$(/usr/bin/vm_stat 2>/dev/null | swarm_parse_vm_stat_free_gb)
  elif [ -r /proc/meminfo ]; then
    v=$(awk '/^MemAvailable:/{printf "%d", $2 / 1048576; exit}' /proc/meminfo 2>/dev/null)
  fi
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# The default runaway guard: 20 load per core. Not a busy test — the idle floor is.
swarm_default_max_load() { printf '%s' $(( 20 * $(swarm_cores) )); }

# swarm_busy <min-idle> <max-load> — prints what it read; 0 when busy, 1 when clear.
#   busy:  "cpu idle 9%, floor 15%"  or  "load 201, limit 200"
#   clear: "cpu idle 41%, load 52"
swarm_busy() {
  local min="${1:-15}" max="${2:-}" idle load
  [ -n "$max" ] || max=$(swarm_default_max_load)
  idle=$(swarm_cpu_idle); load=$(swarm_load)
  if [ "${idle:-100}" -lt "$min" ]; then printf 'cpu idle %s%%, floor %s%%' "$idle" "$min"; return 0; fi
  if [ "${load:-0}" -gt "$max" ]; then printf 'load %s, limit %s' "$load" "$max"; return 0; fi
  printf 'cpu idle %s%%, load %s' "$idle" "$load"
  return 1
}
