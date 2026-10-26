#!/usr/bin/env bash
# develop-hook-red.sh — every check the commit and push hooks run, run on the trunk's head,
# so a red the trunk carries is filed when it lands, not when a builder's hook meets it.
# Required checks are not enough: a hook that enforces more than the trunk is held to
# refuses builders on a red only builders ever see.
#
#   develop-hook-red.sh start [dry]   from housekeeping: a sweep of the trunk head in the
#       background, unless that head was swept, one is running, the hooks run no check
#       (driver/hook-checks.sh), or the last began under coordinator.hookSweepGapMinutes
#       (default 15) ago. Returns at once. dry: says what it would start.
#   develop-hook-red.sh sweep [<sha>]  the sweep: each check run on that commit alone
#       (driver_base_check, cached per commit for every builder). The red ones, a suite
#       by the checks its own "N of M failed: a, b" line names, go to develop-red.tsv as ONE row, which
#       develop-red.sh files as one ticket at the front of the queue. Unknown is never red.
#   exit 0 · 1 the sweep could not run · 2 usage
#
#   develop-hook-swept.tsv  <sha> \t <epoch> \t green | red:<checks> [unknown:<checks>]
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$SELF_DIR/.." && pwd)"
. "$KIT/driver/driver-env.sh" || exit 1
. "$KIT/driver/hook-checks.sh" || exit 1

die() { echo "develop-hook-red: $*" >&2; exit 2; }
SWEPT="${DEVELOP_HOOK_SWEPT:-$STATE_DIR/swarm/develop-hook-swept.tsv}"
LOCK="${DEVELOP_HOOK_LOCK:-$STATE_DIR/swarm/develop-hook-sweep.lock}"
LOG="${DEVELOP_HOOK_LOG:-$STATE_DIR/swarm/develop-hook-sweep.log}"
mkdir -p "$(dirname "$SWEPT")" 2>/dev/null; touch "$SWEPT" 2>/dev/null

swept() { awk -F'\t' -v s="$1" '$1 == s { h = 1 } END { exit !h }' "$SWEPT" 2>/dev/null; }
holder_alive() { local p; p=$(cat "$LOCK/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }

head_sha() {
  GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o ConnectTimeout=5}" \
    git -C "$MAIN_REPO" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 fetch -q origin \
    "+refs/heads/$INTEGRATION_BRANCH:refs/remotes/origin/$INTEGRATION_BRANCH" >/dev/null 2>&1 || true  # unbounded-ok: bounded by the connect and low-speed limits
  git -C "$MAIN_REPO" rev-parse -q --verify "origin/$INTEGRATION_BRANCH^{commit}" 2>/dev/null
}

start() {
  local dry="${1:-}" sha s7 checks gap last
  sha=$(head_sha) || { echo "origin/$INTEGRATION_BRANCH could not be read; no hook sweep this pass"; return 0; }
  s7=$(printf '%s' "$sha" | cut -c1-7)
  swept "$sha" && return 0
  checks=$(driver_hook_checks "$MAIN_REPO" "$sha")
  if [ -z "$checks" ]; then
    [ -n "$dry" ] || printf '%s\t%s\t%s\n' "$sha" "$(date +%s)" "green" >> "$SWEPT"
    return 0
  fi
  if [ -d "$LOCK" ] && holder_alive; then return 0; fi
  gap=$(driver_opt coordinator.hookSweepGapMinutes 15); case "$gap" in ''|*[!0-9]*) gap=15 ;; esac
  last=$(cat "$LOCK.since" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( $(date +%s) - last )) -ge $(( gap * 60 )) ] || return 0
  if [ -n "$dry" ]; then echo "would run the hooks' checks on $INTEGRATION_BRANCH@$s7: $(printf '%s' "$checks" | paste -sd, - | sed 's/,/, /g')"; return 0; fi
  date +%s > "$LOCK.since"
  nohup bash "$SELF_DIR/develop-hook-red.sh" sweep "$sha" >> "$LOG" 2>&1 < /dev/null &
  echo "running the hooks' checks on $INTEGRATION_BRANCH@$s7 in the background: $(printf '%s' "$checks" | paste -sd, - | sed 's/,/, /g')"
}

sweep() {
  local sha="${1:-}" s7 checks c v out names red="" unk="" verdict
  [ -n "$sha" ] || sha=$(head_sha) || { echo "origin/$INTEGRATION_BRANCH could not be read"; return 1; }
  s7=$(printf '%s' "$sha" | cut -c1-7)
  mkdir "$LOCK" 2>/dev/null || { holder_alive && { echo "a sweep is running"; return 0; }; rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || return 1; }
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT
  swept "$sha" && return 0
  checks=$(driver_hook_checks "$MAIN_REPO" "$sha")
  out=$(mktemp "${TMPDIR:-/tmp}/develop-hook-red.XXXXXX")
  for c in $checks; do
    : > "$out"
    v=$(BASE_CHECK_OUT="$out" driver_base_check "$MAIN_REPO" "$sha" "$c")
    case "$v" in
      red) names=$(grep -E '[0-9]+ of [0-9]+ failed: ' "$out" 2>/dev/null | tail -1 | sed 's/.*failed: //' | tr ',' '\n' \
             | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -E '^[A-Za-z0-9][A-Za-z0-9:_./-]*$')
           [ -n "$names" ] || names="$c"
           red=$(printf '%s\n%s\n' "$red" "$names" | awk 'NF' | sort -u | paste -sd, -) ;;
      green) : ;;
      *) unk="$unk${unk:+,}$c" ;;
    esac
  done
  rm -f "$out"
  verdict="${red:+red:$red}${unk:+${red:+ }unknown:$unk}"
  printf '%s\t%s\t%s\n' "$sha" "$(date +%s)" "${verdict:-green}" >> "$SWEPT"
  if [ -n "$red" ]; then
    driver_base_red_note "" "$sha" "$red" ""
    echo "$INTEGRATION_BRANCH@$s7 is red on ${red//,/, } — noted for the develop-red ticket"
  else
    echo "$INTEGRATION_BRANCH@$s7: every hook check green${unk:+ that could run (${unk//,/, } could not)}"
  fi
}

case "${1:-}" in
  start) start "${2:-}" ;;
  sweep) sweep "${2:-}" ;;
  *) die "usage: develop-hook-red.sh start [dry] | sweep [<sha>]" ;;
esac
