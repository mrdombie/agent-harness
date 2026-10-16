#!/usr/bin/env bash
# load.sh — is the machine busy? Sourced by swarm-env.sh and by
# scripts/machine-gate.sh, which must read it without a project config.
#
# BUSY MEANS THE CPU HAS NO ROOM: the median of the recent idle samples below a
# floor (swarm.minCpuIdle, default 15%). The 1-minute load average is a RUNAWAY
# GUARD only, at a ceiling ordinary work never reaches (swarm.maxLoad, default
# 20 x cores). On 2026-10-15 macOS counted 4,898 threads into a load of 40-103 on 10 cores while top showed
# 41% idle, and the old load-only gate turned agents away six times in a row; on
# 2026-10-16 it read 119-140, once 140 at 41% idle, so 8 x cores still blocked.
#
#   swarm_busy <min-idle> <max-load>  prints the reading; 0 when busy, 1 when clear
#   swarm_cpu_idle                    idle percent, sampled over ~1-2s
#   swarm_cpu_idle_smoothed           "<median> <samples>" over the recent samples;
#                                     samples 0 when a fixed seam stands in
#   swarm_load                        the 1-minute load average, a whole number
#   swarm_cores                       logical cores
#   Every reading prints NOTHING when it could not be taken. swarm_busy (the
#   gate) reads that as idle 100 / load 0 / 4 cores; the coordinator as no room.
#   swarm_free_mem_gb                 available memory less swap in use, whole GB; empty when unread
#
# Seams, each read on EVERY call so a test can move them while a waiter polls:
#   SWARM_LOAD / SWARM_LOAD_FILE   a fixed load / a file holding it
#   SWARM_IDLE / SWARM_IDLE_FILE   a fixed idle percent / a file holding it
#   SWARM_CORES / SWARM_CORES_FILE a fixed core count / a file holding it
#   SWARM_FREE_MEM_GB / _FILE      a fixed free-memory reading / a file holding it
#   SWARM_IDLE_CACHE               where one real sample is shared for 5s
#                                  (default ~/.cache/agent-harness/cpu-idle)
#   SWARM_IDLE_HISTORY             where recent samples are kept (default the
#                                  cache path + .history); unset beside a fixed
#                                  SWARM_IDLE / _FILE, the fixed value alone counts
#   SWARM_IDLE_SAMPLES             samples the median is taken over (default 5)
#   SWARM_IDLE_MAX_AGE             oldest sample counted, in seconds (default 1800)
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
  case "$l" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$l"
}

swarm_cores() {
  if [ -n "${SWARM_CORES_FILE:-}" ] && [ -f "$SWARM_CORES_FILE" ]; then
    local f; f=$(head -1 "$SWARM_CORES_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_CORES:-}" ]; then printf '%s' "$SWARM_CORES"; return; fi
  local c=""
  c=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null)
  [ -n "$c" ] || c=$(nproc 2>/dev/null)
  [ -n "$c" ] || c=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
  case "$c" in ''|*[!0-9]*|0) return 0 ;; esac
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

# Idle percent, or nothing when no sample could be taken. swarm_busy reads nothing
# as 100 (the load backstop still holds); the coordinator reads it as no room.
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
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  mkdir -p "$(dirname "$cache")" 2>/dev/null \
    && printf '%s %s\n' "$now" "$v" > "$cache.$$" 2>/dev/null && mv -f "$cache.$$" "$cache" 2>/dev/null
  printf '%s' "$v"
}

# The median of the last SWARM_IDLE_SAMPLES readings no older than SWARM_IDLE_MAX_AGE,
# this one included: one sample read 5%, 55%, 19%, 4% within minutes on a busy Mac.
swarm_cpu_idle_smoothed() {
  local v hist n age now last
  v=$(swarm_cpu_idle)
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  if [ -z "${SWARM_IDLE_HISTORY:-}" ] && { [ -n "${SWARM_IDLE_FILE:-}" ] || [ -n "${SWARM_IDLE:-}" ]; }; then
    printf '%s 0' "$v"; return
  fi
  hist="${SWARM_IDLE_HISTORY:-${SWARM_IDLE_CACHE:-$HOME/.cache/agent-harness/cpu-idle}.history}"
  n="${SWARM_IDLE_SAMPLES:-5}"; case "$n" in ''|*[!0-9]*|0) n=5 ;; esac
  age="${SWARM_IDLE_MAX_AGE:-1800}"; case "$age" in ''|*[!0-9]*|0) age=1800 ;; esac
  now=$(date +%s)
  mkdir -p "$(dirname "$hist")" 2>/dev/null
  last=$(tail -1 "$hist" 2>/dev/null | awk '{print $1}')
  # A reading inside the cache's 5s is the same sample: counting it twice weights it.
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -lt 5 ] 2>/dev/null || printf '%s %s\n' "$now" "$v" >> "$hist" 2>/dev/null
  if [ "$(wc -l < "$hist" 2>/dev/null || echo 0)" -gt 200 ]; then
    tail -50 "$hist" > "$hist.$$" 2>/dev/null && mv -f "$hist.$$" "$hist" 2>/dev/null
  fi
  awk -v from=$(( now - age )) '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $1 >= from { print $2 }' "$hist" 2>/dev/null \
    | tail -n "$n" | sort -n \
    | awk -v cur="$v" '{ x[NR] = $1 } END {
        if (NR == 0) { printf "%s 1", cur; exit }
        if (NR % 2) m = x[(NR + 1) / 2]; else m = (x[NR / 2] + x[NR / 2 + 1]) / 2
        printf "%d %d", m + 0.5, NR }'
}

# "cpu idle 40%", with the sample count when the figure is a median.
swarm_idle_label() { # <idle> <samples>
  if [ "${2:-0}" -gt 0 ] 2>/dev/null; then printf 'cpu idle %s%% (median of %s)' "$1" "$2"
  else printf 'cpu idle %s%%' "$1"; fi
}

# Free memory in whole GB: what the kernel says is available, less swap in use.
# Inactive pages are not free on a swapping machine: on 2026-10-16 vm_stat's
# free + inactive read 6 GB with 15.5 of 16 GB swap used and load 96.
#   swarm_free_mem_calc <available-bytes> <swap-used-bytes>
swarm_free_mem_calc() {
  awk -v a="$1" -v u="$2" 'BEGIN{ if (a == "" || a !~ /^[0-9.]+$/ || u !~ /^[0-9.]+$/) exit 1
    g = (a - u) / 1073741824; if (g < 0) g = 0; printf "%d", g }'
}
# The used figure in bytes from `sysctl -n vm.swapusage` on stdin ("used = 14747.50M").
swarm_parse_swapusage_used() {
  awk '{ for (i = 1; i <= NF; i++) if ($i == "used") { v = $(i+2); m = 1
           if (v ~ /G$/) m = 1073741824; else if (v ~ /M$/) m = 1048576; else if (v ~ /K$/) m = 1024
           sub(/[KMG]$/, "", v); printf "%d", v * m; found = 1; exit } }
       END { if (!found) exit 1 }'
}

# Free memory in whole GB, or nothing when it could not be read.
#   SWARM_FREE_MEM_GB / SWARM_FREE_MEM_FILE   a fixed reading / a file holding it
swarm_free_mem_gb() {
  if [ -n "${SWARM_FREE_MEM_FILE:-}" ] && [ -f "$SWARM_FREE_MEM_FILE" ]; then
    local f; f=$(head -1 "$SWARM_FREE_MEM_FILE" 2>/dev/null); printf '%s' "${f%%.*}"; return
  fi
  if [ -n "${SWARM_FREE_MEM_GB:-}" ]; then printf '%s' "${SWARM_FREE_MEM_GB%%.*}"; return; fi
  local v="" lvl mem used
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    lvl=$(/usr/sbin/sysctl -n kern.memorystatus_level 2>/dev/null)
    mem=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null)
    used=$(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null | swarm_parse_swapusage_used)
    case "$lvl$mem" in ''|*[!0-9]*) ;; *) v=$(swarm_free_mem_calc "$(( mem / 100 * lvl ))" "${used:-}") ;; esac
  elif [ -r /proc/meminfo ]; then
    v=$(awk '/^MemAvailable:/{a=$2} /^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
             END{ if (a == "") exit 1; g = (a - (t - f)) / 1048576; if (g < 0) g = 0; printf "%d", g }' /proc/meminfo 2>/dev/null)
  fi
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# The default runaway guard: 20 load per core. Not a busy test — the idle floor is.
swarm_default_max_load() { local c; c=$(swarm_cores); case "$c" in ''|*[!0-9]*|0) c=4 ;; esac; printf '%s' $(( 20 * c )); }

# swarm_busy <min-idle> <max-load> — prints what it read; 0 when busy, 1 when clear.
#   busy:  "cpu idle 9% (median of 5), floor 15%"  or  "load 201, limit 200"
#   clear: "cpu idle 41% (median of 5), load 52"
swarm_busy() {
  local min="${1:-15}" max="${2:-}" idle="" n=0 sm load
  [ -n "$max" ] || max=$(swarm_default_max_load)
  sm=$(swarm_cpu_idle_smoothed); load=$(swarm_load)
  [ -n "$sm" ] && read -r idle n <<< "$sm"
  if [ "${idle:-100}" -lt "$min" ]; then printf '%s, floor %s%%' "$(swarm_idle_label "$idle" "$n")" "$min"; return 0; fi
  if [ "${load:-0}" -gt "$max" ]; then printf 'load %s, limit %s' "$load" "$max"; return 0; fi
  printf '%s, load %s' "$([ -n "$idle" ] && swarm_idle_label "$idle" "$n" || echo 'cpu idle unread')" "${load:-unread}"
  return 1
}
