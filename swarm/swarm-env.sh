#!/usr/bin/env bash
# swarm-env.sh — the one place the swarm layer resolves WHERE things are and HOW
# it reaches the outside world.
#
#   . "$KIT_ROOT/swarm/swarm-env.sh" || exit 1
#
# Sets, on top of everything scripts/toolkit-env.sh sets:
#   SWARM_DIR        per-machine swarm state: the queue, repair attempts, holds
#   SWARM_LOGS       $STATE_DIR/logs — the same logs the spawner writes
#   RUNS_DIR         $STATE_DIR/runs — one record per spawned agent
#   SWARM_CAP        agents at once PER PROGRAMME (default 3)
#   SWARM_MIN_CPU_IDLE  busy below this sampled CPU idle percent (default 15)
#   SWARM_MAX_LOAD   runaway guard only: busy above this 1-minute load average (default 20 x cores)
#   SWARM_LIVE_URL   the live view's snapshot endpoint
#   SWARM_STATUS_REPO  optional: a repo to dispatch a rebuild at (empty = skip)
#   SWARM_REPORT_URL   optional: where the reporter POSTs (empty = skip)
#
# EVERY call out of this process goes through a function here, and every one of
# them is overridable by an environment variable. That is not a convenience: a
# swarm made of eight scripts that shelled out to gh, curl, sysctl and a spawner
# inline could not be tested at all, which is how it reached 2026-09-26 with the
# cap, the queue order and the stop-after-3 all unverified. The seams are:
#
#   SWARM_GH     the GitHub CLI          (default: gh)
#   SWARM_CURL   the HTTP client         (default: curl)
#   SWARM_SPAWN  the agent spawner       (default: the kit's spawn-claim.sh)
#   SWARM_LOAD   the load average        (default: read from the kernel)
#   SWARM_IDLE   the CPU idle percent    (default: sampled with top or /proc/stat)
#   SWARM_NOW    the clock, epoch secs   (default: date +%s)
#
# A test points them at recorders and asserts on what was recorded. Nothing in
# the scripts themselves knows it is being tested.

_swarm_self="${BASH_SOURCE[0]}"
. "$(cd "$(dirname "$_swarm_self")/../scripts" && pwd)/toolkit-env.sh" || return 1 2>/dev/null || exit 1
. "$(cd "$(dirname "$_swarm_self")" && pwd)/time.sh" || return 1 2>/dev/null || exit 1
unset _swarm_self

# gh keeps its token in the macOS keychain, which a launchd job cannot read: the
# access prompt has nowhere to show, so gh hangs. Measured 2026-09-20 — the
# scheduler ran 8 times and logged nothing after its first pass. A 0600 file the
# operator writes with `gh auth token > <file>` is the way in. Rotate it there.
SWARM_TOKEN_FILE="${SWARM_TOKEN_FILE:-$STATE_DIR/swarm/gh-token}"
if [ -z "${GH_TOKEN:-}" ] && [ -s "$SWARM_TOKEN_FILE" ]; then
  GH_TOKEN="$(cat "$SWARM_TOKEN_FILE")"; export GH_TOKEN
fi

SWARM_DIR="${SWARM_DIR:-$STATE_DIR/swarm}"
SWARM_LOGS="${SWARM_LOGS:-$STATE_DIR/logs}"
RUNS_DIR="${RUNS_DIR:-$STATE_DIR/runs}"
mkdir -p "$SWARM_DIR" "$SWARM_LOGS" "$RUNS_DIR" 2>/dev/null || true
# A launchd job's label. Two projects can share one machine, so it carries a key of the state directory.
swarm_job_label() { printf 'agent-harness.swarm.%s.%s' "$1" "$(printf '%s' "$STATE_DIR" | cksum | awk '{printf "%08x", $1}')"; }

# swarm_opt <dotted.key> <default> — an OPTIONAL project fact.
#
# toolkit_cfg refuses a missing key by name, which is right for a fact the kit
# cannot invent (the repo slug, the label names). These are different: a cap, a
# load ceiling and a port are machine tuning, identical on every project until
# someone tunes them, so a default here names no project and hides nothing.
# swarm_heal_parked_out <ticket> <pr-head> — 0 when the driver parked this ticket past
# its cap of driver-caused parks (driver.maxMachineParks, 2) on this same PR head. The
# healing lane leaves it for a person; a new head on the PR heals it again.
swarm_heal_parked_out() {
  local f="${DRIVER_DIR:-${STATE_DIR:-}/driver}/$1/state.json" n h cap="${DRIVER_MAX_MACHINE_PARKS:-2}"
  [ -n "$1" ] && [ -n "${2:-}" ] && [ -f "$f" ] || return 1
  n=$(jq -r '.counters.machine_parks // 0' "$f" 2>/dev/null); h=$(jq -r '.repair_pr_head // ""' "$f" 2>/dev/null)
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt "$cap" ] && [ "$h" = "$2" ]
}

swarm_opt() { local v; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }

SWARM_CAP="${SWARM_CAP:-$(swarm_opt swarm.cap 3)}"
# A ticket whose builder asked the owner something: no agent takes it until the answer.
LBL_OWNER_DECISION="${LBL_OWNER_DECISION:-$(swarm_opt labels.ownerDecision needs:owner-decision)}"
SWARM_MIN_CPU_IDLE="${SWARM_MIN_CPU_IDLE:-$(swarm_opt swarm.minCpuIdle 15)}"
SWARM_MAX_LOAD="${SWARM_MAX_LOAD:-$(swarm_opt swarm.maxLoad "")}"
SWARM_IDLE_SAMPLES="${SWARM_IDLE_SAMPLES:-$(swarm_opt swarm.idleSamples 5)}"
SWARM_IDLE_MAX_AGE="${SWARM_IDLE_MAX_AGE:-$(swarm_opt swarm.idleMaxAgeSec 1800)}"
export SWARM_IDLE_SAMPLES SWARM_IDLE_MAX_AGE
SWARM_PORT="${SWARM_PORT:-$(swarm_opt swarm.port 4777)}"
SWARM_LIVE_URL="${SWARM_LIVE_URL:-$(swarm_opt swarm.liveUrl "http://127.0.0.1:$SWARM_PORT/api/agents")}"
SWARM_STATUS_REPO="${SWARM_STATUS_REPO:-$(swarm_opt swarm.statusRepo "")}"
SWARM_REPORT_URL="${SWARM_REPORT_URL:-$(swarm_opt swarm.reportUrl "")}"
SWARM_BUDGET_USD="${SWARM_BUDGET_USD:-$(swarm_opt swarm.budgetUsd 150)}"
SWARM_USAGE_CEILING="${SWARM_USAGE_CEILING:-$(swarm_opt swarm.usageCeiling 0.95)}"
# At this share of either window a builder holds before its next step: the step it is
# on finishes, and nothing is killed or parked (swarm_usage_step_hold).
# The usage windows that can hold builders before a wall (swarm.usageWindows). Claude dropped
# its five-hour limit on 2026-10-31, so only the weekly window holds by default; a wall the
# API actually refuses on (a rejected event, the hook's hold file) holds whatever its window.
SWARM_USAGE_WINDOWS="${SWARM_USAGE_WINDOWS:-$(swarm_opt swarm.usageWindows seven_day)}"
SWARM_USAGE_WINDOWS=$(printf '%s' "$SWARM_USAGE_WINDOWS" | tr -d '[]"' | tr ',' ' ')
SWARM_USAGE_STEP_HOLD="${SWARM_USAGE_STEP_HOLD:-$(swarm_opt swarm.usageStepHold 0.95)}"
awk -v t="$SWARM_USAGE_STEP_HOLD" 'BEGIN{exit !(t ~ /^[0-9]*\.?[0-9]+$/ && t+0 > 0 && t+0 <= 1)}' || SWARM_USAGE_STEP_HOLD=0.95
SWARM_GH="${SWARM_GH:-gh}"
SWARM_CURL="${SWARM_CURL:-curl}"
SWARM_SPAWN="${SWARM_SPAWN:-$KIT_ROOT/scripts/spawn-claim.sh}"
# The programme label namespace. `project:` is the kit's own vocabulary — the
# same prefix /project, /work and /standup already read — not a project's name.
SWARM_PROGRAMME_PREFIX="${SWARM_PROGRAMME_PREFIX:-project:}"

# Every swarm read goes through the shared backoff (scripts/gh-batch.sh): once
# GitHub refuses the token for a rate limit, the swarm stops asking for a while
# instead of pressing on and keeping the limit, and every builder, shut.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/gh-batch.sh" || return 1 2>/dev/null || exit 1
swarm_gh()   { gh_call "$@"; }
swarm_curl() { "$SWARM_CURL" "$@"; }

# Epoch seconds. Overridable so a test can sit at a chosen minute instead of
# sleeping through one.
swarm_now() { if [ -n "${SWARM_NOW:-}" ]; then printf '%s' "$SWARM_NOW"; else date +%s; fi; }
swarm_stamp() { swarm_iso "$(swarm_now)"; }
swarm_day()   { swarm_iso "$(swarm_now)" | cut -dT -f1; }

# Is the machine busy: swarm/load.sh, shared with scripts/machine-gate.sh so the
# swarm and the session paths apply one test.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/load.sh" || return 1 2>/dev/null || exit 1
[ -n "$SWARM_MAX_LOAD" ] || SWARM_MAX_LOAD=$(swarm_default_max_load)

# Prints the reading; 0 when busy (cpu idle under the floor, or load over the backstop).
swarm_machine_busy() { swarm_busy "$SWARM_MIN_CPU_IDLE" "$SWARM_MAX_LOAD"; }

swarm_log() { # <logfile> <message…>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s %s\n' "$(swarm_stamp)" "$*" >> "$f"
}

# ---- cli-signal reader: begin ----------------------------------------------
# The ONE place a builder log is read for a limit or error. scripts/check-signal-source.sh
# fails on such a read anywhere else.
#
# The plan's usage limit. On 2026-09-21 every spawn between 16:44 and 18:18 UTC
# ended in seconds with "You've hit your session limit · resets 7:20pm", and the
# scheduler relaunched the same two tickets 36 times. A spawn during the hold
# only burns another slot, so read the newest run's log and wait out the reset.
#
# TWO readings, in that order, because the sentence is not reliable and the
# structured event is. Measured across 245 logs carrying a limit line on
# 2026-09-27:
#
#   432  "resets 7:20pm (Europe/London)"      — the session wall
#    28  "resets 8pm (Europe/London)"         — a weekly wall, no minutes
#     4  "resets Sep 29 at 9pm (Europe/London)" — a weekly wall NAMING A DATE
#     8  "hit your session limit"             — no reset time at all
#   245  carried rate_limit_event.rate_limit_info.resetsAt  (all of them)
#
# The old regex required a digit straight after "resets ", so the dated weekly
# wording matched nothing and set no hold — and the daemon spawned into the wall
# on 2026-09-27. The epoch field is exact, names its window, and is present on
# every one, so it leads; the sentence stays as the fallback for a log that
# carries it without an event.
#
# `status` is on EVERY event and is "allowed" or "allowed_warning" 6,352 times
# against 238 "rejected". Only the rejection is a wall — holding on the field's
# mere presence would stop the swarm permanently.
swarm_usage_event_hold() {
  local newest row n epoch kind now
  newest=$(ls -t "$SWARM_LOGS"/claim-*.log 2>/dev/null | head -1)
  [ -n "$newest" ] || return 1
  # The LAST rejection in the newest log. Earlier ones in the same run are history.
  row=$(swarm_usage_cli_events "$newest" | awk -F'\t' '$2=="rejected"' | tail -1)
  [ -n "$row" ] || return 1
  n=$(printf '%s' "$row" | cut -f1)
  epoch=$(printf '%s' "$row" | cut -f3)
  kind=$(printf '%s' "$row" | cut -f4)
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(swarm_now)
  [ "$epoch" -gt "$now" ] || return 1
  if [ "${SWARM_USAGE_WHY:-0}" = 1 ]; then
    printf 'rate-limit event, %s line %s' "$(basename "$newest")" "$n"; return 0
  fi
  printf '%s (%s window)' "$(swarm_iso "$epoch")" "$kind"
}

# The CLI's own limit signals, one row each: `<line>\trejected\t<epoch>\t<window>`,
# `<line>\twindow\t<epoch>\t<window>\t<utilization>`, `<line>\terror\t<text>` or
# `<line>\tauth\t<text>`. The same sentence inside a tool result is a quote, never a wall.
swarm_usage_cli_events() { # <log>
  grep -nE '"type":"(rate_limit_event|result)"|"model":"<synthetic>"' "$1" 2>/dev/null \
  | jq -rR 'capture("^(?<n>[0-9]+):(?<j>.*)$") as $c | ($c.j | fromjson?) as $e
      | select($e | type == "object")
      | if $e.type == "rate_limit_event" and $e.rate_limit_info.status == "rejected" then
          [$c.n, "rejected", ($e.rate_limit_info.resetsAt | tostring), ($e.rate_limit_info.rateLimitType // "")]
        elif $e.type == "result" and $e.is_error == true and ($e.result | type) == "string" then
          [$c.n, "error", $e.result]
        elif $e.type == "rate_limit_event" then
          ($e.rate_limit_info.unifiedWindows // {} | to_entries[]
           | select((.value.resetsAt | type) == "number" and (.value.utilization | type) == "number")
           | [$c.n, "window", (.value.resetsAt | tostring), .key, (.value.utilization | tostring)])
        elif $e.type == "assistant" and $e.message.model == "<synthetic>" and ($e.error // "") != "" then
          ([$c.n, "error", ([$e.message.content[]? | select(.type == "text") | .text] | join(" "))],
           (if $e.error == "authentication_failed" then [$c.n, "auth", ($e.message.content[0].text // "")] else empty end))
        else empty end
      | map(gsub("[\t\n]"; " ")) | join("\t")' 2>/dev/null
}

swarm_usage_text_hold() {
  local newest row n text reset h m ap now_m reset_m dated
  newest=$(ls -t "$SWARM_LOGS"/claim-*.log 2>/dev/null | head -1)
  [ -n "$newest" ] || return 1
  # A log carrying the CLI's own rejection has said when it resets: the event
  # reading above answers, and once that reset passes the wording must not
  # re-hold — a dated wall's text holds for ever, and no newer log ever lands.
  swarm_usage_cli_events "$newest" | awk -F'\t' '$2=="rejected"{f=1} END{exit !f}' && return 1
  # Only the CLI's own error text: a sentence anywhere else in the log is a quote.
  row=$(swarm_usage_cli_events "$newest" | awk -F'\t' '$2=="error"' \
        | grep -E "hit your (session|weekly) limit" | tail -1)
  [ -n "$row" ] || return 1
  n=$(printf '%s' "$row" | cut -f1)
  text=$(printf '%s' "$row" | cut -f3-)
  # Both wordings. The optional "<Mon> <D> at " is the weekly wall's.
  reset=$(printf '%s' "$text" | grep -oE "resets ([A-Z][a-z]{2} [0-9]{1,2} at )?[0-9]{1,2}(:[0-9]{2})?(am|pm)" \
          | tail -1 | sed 's/resets //')
  [ -n "$reset" ] || return 1
  local src
  src="CLI error text, $(basename "$newest") line $n"
  case "$reset" in *" at "*) dated=1; reset="${reset##* at }" ;; *) dated=0 ;; esac
  h=$(printf '%s' "$reset" | cut -d: -f1 | tr -dc 0-9)
  case "$reset" in *:*) m=$(printf '%s' "$reset" | cut -d: -f2 | tr -dc 0-9) ;; *) m=0 ;; esac
  ap=$(printf '%s' "$reset" | tr -dc a-z)
  [ "$ap" = "pm" ] && [ "$h" -lt 12 ] && h=$((h+12))
  [ "$ap" = "am" ] && [ "$h" -eq 12 ] && h=0
  [ "${SWARM_USAGE_WHY:-0}" = 1 ] && reset="$src"
  # A wall that NAMES A DATE resets today at the earliest, so it always holds:
  # the time-of-day alone cannot say whether it is today or three days out, and
  # the event reading above is the one that answers that exactly.
  [ "$dated" = 1 ] && { printf '%s' "$reset"; return 0; }
  # awk, not $(( )): "08" is eight to awk and an invalid octal literal to the
  # shell, and 08:00 and 09:00 are the two hours a usage wall most often names.
  now_m=$(swarm_clock "$(swarm_now)" | awk '{print $1 * 60 + $2}')
  reset_m=$(( h * 60 + 10#$m ))
  # The second test is the midnight wrap: a reset time that already passed by a
  # long way is yesterday's, not a hold that should last 23 hours.
  if [ "$now_m" -lt "$reset_m" ] || [ $(( reset_m - now_m )) -lt -1380 ]; then
    printf '%s' "$reset"; return 0
  fi
  return 1
}

# Did this run stop on the plan's limit, by the CLI's own signals in its log.
swarm_usage_log_limited() { # <log>
  swarm_usage_cli_events "$1" \
    | awk -F'\t' '$2=="rejected" || ($2=="error" && $3 ~ /hit your (session|weekly) limit/){f=1} END{exit !f}'
}
# Did this run stop because the CLI lost its login.
swarm_login_log_lost() { # <log>
  swarm_usage_cli_events "$1" | awk -F'\t' '$2=="auth"{f=1} END{exit !f}'
}
# When the plan's limit stopped this log, `<epoch>\t<text>` for a hold to wait out:
# the rejection's own epoch, else the reset the error text names, else an hour.
swarm_usage_log_reset() { # <log>
  local ev row epoch text
  swarm_usage_log_limited "$1" || return 1
  ev=$(swarm_usage_cli_events "$1")
  row=$(printf '%s\n' "$ev" | awk -F'\t' '$2=="rejected"' | tail -1)
  text=$(printf '%s\n' "$ev" | awk -F'\t' '$2=="error" && $3 ~ /hit your (session|weekly) limit/' | tail -1 | cut -f3-)
  [ -n "$text" ] || text="the plan's usage limit (rate-limit event)"
  epoch=$(printf '%s' "$row" | cut -f3)
  case "$epoch" in ''|*[!0-9]*)
    epoch=$(USAGE_LIMIT_NOW="$(swarm_now)" bash "$KIT_ROOT/hooks/usage-limit.sh" --reset-epoch "$text" 2>/dev/null) ;;
  esac
  case "$epoch" in ''|*[!0-9]*) epoch=$(( $(swarm_now) + 3600 )) ;; esac
  printf '%s\t%s\n' "$epoch" "$(printf '%s' "$text" | tr '\n\t' '  ' | cut -c1-200)"
}

# A window already at swarm.usageCeiling: a run started now dies at the wall mid-work.
swarm_usage_near_hold() {
  local newest rows last pick now
  newest=$(ls -t "$SWARM_LOGS"/claim-*.log 2>/dev/null | head -1)
  [ -n "$newest" ] || return 1
  rows=$(swarm_usage_cli_events "$newest" | awk -F'\t' '$2=="window"')
  [ -n "$rows" ] || return 1
  last=$(printf '%s\n' "$rows" | tail -1 | cut -f1)
  now=$(swarm_now)
  pick=$(printf '%s\n' "$rows" | awk -F'\t' -v l="$last" -v c="$SWARM_USAGE_CEILING" -v now="$now" -v ws=" $SWARM_USAGE_WINDOWS " '
    $1 == l && index(ws, " " $4 " ") && $5 + 0 >= c + 0 && $3 + 0 > now + 0 && $3 + 0 > best + 0 { best = $3; w = $4; u = $5 }
    END { if (best) printf "%s\t%s\t%d", best, w, u * 100 + 0.5 }')
  [ -n "$pick" ] || return 1
  if [ "${SWARM_USAGE_WHY:-0}" = 1 ]; then
    printf 'usage at %s%% of the %s window, %s line %s' "$(printf '%s' "$pick" | cut -f3)" \
      "$(printf '%s' "$pick" | cut -f2)" "$(basename "$newest")" "$last"; return 0
  fi
  printf '%s (%s window at %s%%)' "$(swarm_iso "$(printf '%s' "$pick" | cut -f1)")" \
    "$(printf '%s' "$pick" | cut -f2)" "$(printf '%s' "$pick" | cut -f3)"
}
# A file's mtime, on either stat, always as digits (0 when unreadable).
swarm_mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m="" ;; esac
  [ -n "$m" ] || { m=$(stat -f %m "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m=0 ;; esac; }
  printf '%s' "$m"
}

# THE ACCOUNT A READING WAS TAKEN UNDER. Usage is the plan's, and the plan is the login's:
# on 2026-10-24 the login changed and both hosts held on the old account's 95% week. So the
# account (orgId, else email, from `claude auth status --json`) is read at most once a minute
# and kept in swarm/.account as "<id>\t<changed-at>\t<checked-at>". A log names no account,
# so a log observed before the last change is dropped; a heartbeat or a published reading
# carries its account and counts only when it is this host's. Unread, the last known stands;
# never known, readings count as they did before (no account on either side).
SWARM_ACCOUNT_FILE="${SWARM_ACCOUNT_FILE:-$SWARM_DIR/.account}"
swarm_account() {
  local f="$SWARM_ACCOUNT_FILE" now id was="" ch=0 ck=0
  now=$(swarm_now)
  [ -s "$f" ] && IFS=$'\t' read -r was ch ck < "$f"
  case "$ch" in ''|*[!0-9]*) ch=0 ;; esac; case "$ck" in ''|*[!0-9]*) ck=0 ;; esac
  if [ -z "${SWARM_ACCOUNT:-}" ] && [ -n "$was" ] && [ $(( now - ck )) -lt 60 ]; then printf '%s' "$was"; return 0; fi
  id="${SWARM_ACCOUNT:-}"
  [ -n "$id" ] || id=$("${SWARM_CLAUDE_BIN:-claude}" auth status --json 2>/dev/null | jq -r '.orgId // .email // empty' 2>/dev/null)
  if [ -z "$id" ]; then printf '%s' "$was"; return 0; fi
  [ "$id" = "$was" ] || ch=$now
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\t%s\t%s\n' "$id" "$ch" "$now" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f"
  printf '%s' "$id"
}
# swarm_account_since — when the current account took over (0: never changed, or never known).
swarm_account_since() {
  local s; swarm_account >/dev/null
  s=$(awk -F'\t' 'NR == 1 { print $2 + 0 }' "$SWARM_ACCOUNT_FILE" 2>/dev/null)
  case "$s" in ''|*[!0-9]*) s=0 ;; esac; printf '%s' "$s"
}

# swarm_usage_freshest_at <window> [readings json] — "<utilization>\t<reset epoch>\t<observed epoch>"
# for that window (five_hour, seven_day) while it is open, from the newest builder logs
# here (prose claim logs, driver step logs; observed = the log's mtime), every host's
# heartbeat in the coordinator's fleet file, and the readings passed ([{u, reset, at}]).
# The window is the account's, so any host's reading counts. The NEWEST observed
# reading names the window by its reset: a reading with another reset is another
# window (the account was switched, or the window reset) and is dropped, never
# compared. Only inside that one window does utilization only rise, so the highest
# of its readings wins. Resets within 10 min are one window. A reading with no `at`
# (an older harness's heartbeat) is the oldest.
swarm_usage_freshest_at() {
  local w="${1:-five_hour}" extra="${2:-[]}" now files f m best acct since
  now=$(swarm_now); acct=$(swarm_account); since=$(swarm_account_since)
  # shellcheck disable=SC2012  # names we wrote, no newlines
  files=$(ls -t "$SWARM_LOGS"/claim-*.log "${DRIVER_DIR:-$STATE_DIR/driver}"/*/steps/*.log 2>/dev/null | head -8)
  best=$( { while IFS= read -r f; do
              [ -n "$f" ] || continue
              m=$(swarm_mtime "$f")
              # A log names no account: one observed before the account changed is another account's.
              [ "$m" -ge "$since" ] || continue
              swarm_usage_cli_events "$f" | awk -F'\t' -v w="$w" -v m="$m" '$2 == "window" && $4 == w { print $5 "\t" $3 "\t" m }'
            done <<< "$files"
            jq -r --arg w "$w" --arg a "$acct" '.hosts[]? | select((.account // "") == $a) | .usage? | .[$w]? // empty | select((.u | type) == "number" and (.reset | type) == "number")
                                | "\(.u)\t\(.reset)\t\((.at // 0) | tonumber? // 0)"' "${COORDINATOR_DIR:-$STATE_DIR/coordinator}/fleet.json" 2>/dev/null
            printf '%s' "$extra" | jq -r --arg a "$acct" '.[]? | select(type == "object" and (.account // "") == $a and (.u | type) == "number" and (.reset | type) == "number")
                                          | "\(.u)\t\(.reset)\t\((.at // 0) | tonumber? // 0)"' 2>/dev/null
          } | awk -F'\t' -v now="$now" '
            $2 + 0 > now + 0 {
              n++; U[n] = $1 + 0; R[n] = $2 + 0; A[n] = $3 + 0
              # The newest observation; at the same time, the later reset (a log that spans a reset).
              if (n == 1 || A[n] > na || (A[n] == na && R[n] > nr)) { na = A[n]; nr = R[n] }
            }
            END { for (i = 1; i <= n; i++) { d = R[i] - nr; if (d < 0) d = -d
                    if (d <= 600 && (!p || U[i] > bu)) { p = 1; bu = U[i]; br = R[i] } }
                  if (p) printf "%s\t%d\t%d", bu, br, na }')
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# swarm_usage_probe — a host on a usage hold with no reading newer than swarm.usageProbeMin (15)
# makes one tiny call and logs it where the readers look, at most once a probe interval. Held
# builders log nothing, so a hold read under an account since switched, or a window since reset,
# never cleared (2026-10-24: both hosts held on the old account's 95% week after a login change).
# 0 when it probed; 1 when it did not need to or could not.
swarm_usage_probe() {
  local min every now newest m stamp last log dir
  min="${SWARM_USAGE_PROBE_MIN:-$(swarm_opt swarm.usageProbeMin 15 2>/dev/null || echo 15)}"
  case "$min" in ''|*[!0-9]*) min=15 ;; esac
  [ "$min" -gt 0 ] || return 1
  every=$(( min * 60 )); now=$(swarm_now)
  # shellcheck disable=SC2012  # names we wrote
  newest=$(ls -t "$SWARM_LOGS"/claim-*.log "${DRIVER_DIR:-$STATE_DIR/driver}"/*/steps/*.log 2>/dev/null | head -1)
  if [ -n "$newest" ]; then
    m=$(swarm_mtime "$newest"); [ $(( now - ${m:-0} )) -ge "$every" ] || return 1
  fi
  stamp="$SWARM_LOGS/.usage-probe.at"; last=$(cat "$stamp" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -ge "$every" ] || return 1
  mkdir -p "$SWARM_LOGS" 2>/dev/null; printf '%s' "$now" > "$stamp"
  log="$SWARM_LOGS/claim-usage-probe-$(date -u +%Y%m%dT%H%M%SZ)-0.log"
  dir=$(mktemp -d 2>/dev/null) || return 1
  ( cd "$dir" && ${SWARM_USAGE_PROBE_CMD:-claude -p "Reply with the single word ok." --model haiku --output-format stream-json --verbose} ) > "$log" 2>&1 < /dev/null
  rm -rf "$dir"
  grep -q '"type":"rate_limit_event"' "$log" 2>/dev/null
}

# swarm_usage_freshest <window> [readings json] — "<utilization>\t<reset epoch>": the
# reading swarm_usage_freshest_at picks, without when it was observed.
swarm_usage_freshest() {
  local r
  r=$(swarm_usage_freshest_at "$@") || return 1
  printf '%s' "${r%$'\t'*}"
}

# swarm_usage_step_hold — "<reset epoch>\t<window>\t<percent>" while a holding window is at
# or over swarm.usageStepHold: a step started now would likely meet the wall, so a
# running builder waits before its next step. 1 when neither is.
swarm_usage_step_hold() {
  local w r u
  for w in $SWARM_USAGE_WINDOWS; do
    r=$(swarm_usage_freshest "$w") || continue
    u=${r%%$'\t'*}
    awk -v u="$u" -v c="$SWARM_USAGE_STEP_HOLD" 'BEGIN{exit !(u + 0 >= c + 0)}' || continue
    printf '%s\t%s\t%s' "${r#*$'\t'}" "$w" "$(awk -v u="$u" 'BEGIN{printf "%d", u * 100 + 0.5}')"
    return 0
  done
  return 1
}

# Did this model call fail at the API rather than answer: an API Error result, an
# is_error result naming an overload, rate limit, safeguards flag, 5xx, timeout or
# dropped connection, a 5xx/429 api_error_status, or no result at all. Prints what
# failed. A result carrying structured output, and prose from a run that did not
# error, are answers — a phrase QUOTED in an answer is never the signal.
swarm_api_error_log() { # <log>
  local r
  [ -s "$1" ] || { printf 'the call left an empty transcript'; return 0; }
  # Only the CLI's own result lines, which it writes compact, one per line.
  r=$(grep -F '"type":"result"' "$1" 2>/dev/null | jq -r -s '
    ([.[] | select(.type == "result")] | last) as $r
    | if $r == null then "no result came back"
      elif ($r.structured_output? // null) != null then empty
      else (($r.result // "") | tostring) as $x
        | (($r.api_error_status // 0) | tonumber? // 0) as $st
        | if ($x | test("^\\s*API Error"; "i")) or $st >= 500 or $st == 429
             or (($r.is_error // false) == true
                 and ($x == "" or ($x | test("overloaded|rate.?limit|safeguards|usage policy|\\b5[0-9][0-9]\\b|server error|timed? ?out|connection (error|reset)"; "i"))))
          then (if $x == "" then "an API error with no message" else ($x | gsub("\\s+"; " ") | .[0:300]) end)
          else empty end
      end' 2>/dev/null)
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}
# ---- cli-signal reader: end ------------------------------------------------

# A window that hit the wall: hooks/usage-limit.sh (StopFailure) writes
# $STATE_DIR/usage-hold as `<epoch>\t<text>`. The limit is the account's, so a
# wall an interactive window hit holds the timers too. A reset already passed
# holds nothing.
swarm_usage_file_hold() {
  local e
  e=$(cut -f1 "${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}" 2>/dev/null | head -1)
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  [ "$e" -gt "$(swarm_now)" ] || return 1
  if [ "${SWARM_USAGE_WHY:-0}" = 1 ]; then
    printf 'file %s: %s' "${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}" \
      "$(cut -f2- "${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}" 2>/dev/null | head -1 | cut -c1-120)"
    return 0
  fi
  printf '%s (recorded by a window)' "$(swarm_iso "$e")"
}

# swarm_usage_hold_write <epoch> <text> — record a wall in the hold file the file
# reader above answers from, keeping the LATER of two walls (a weekly wall outlasts
# the session wall that hit first). The same format hooks/usage-limit.sh writes.
swarm_usage_hold_write() {
  local f="${SWARM_USAGE_HOLD_FILE:-$STATE_DIR/usage-hold}" cur
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  cur=$(cut -f1 "$f" 2>/dev/null | head -1); case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  [ "$1" -gt "$cur" ] || return 0
  printf '%s\t%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\n\t' '  ' | cut -c1-200)" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
}

swarm_usage_hold() { swarm_usage_file_hold || swarm_usage_event_hold || swarm_usage_near_hold || swarm_usage_text_hold; }
# Where the hold swarm_usage_hold answers came from: the file, or the log and line.
swarm_usage_hold_source() { SWARM_USAGE_WHY=1 swarm_usage_hold; }

# ---- the live view -----------------------------------------------------------
# One snapshot, cached for this process, so a pass that asks three questions
# makes one request.
#
# STALE DATA IS NOT AN ANSWER. The snapshot carries the moment it was taken, and
# a view that is still serving a page from twenty minutes ago is describing a
# machine that no longer exists — a set of agents that have since exited, or a
# set that has since started. An answer older than SWARM_STALE_SEC is discarded
# here, which sends every caller down the same path as no answer at all: busy.
SWARM_STALE_SEC="${SWARM_STALE_SEC:-$(swarm_opt swarm.staleSec 120)}"
swarm_snapshot() {
  if [ -z "${_SWARM_SNAP+x}" ]; then
    local raw at age
    raw=$(swarm_curl -s -m 5 "$SWARM_LIVE_URL" 2>/dev/null || true)
    if [ -n "$raw" ]; then
      at=$(printf '%s' "$raw" | jq -r '.at // empty' 2>/dev/null)
      if [ -n "$at" ]; then
        age=$(( $(swarm_now) - $(swarm_epoch "$at") ))
        if [ "$age" -gt "$SWARM_STALE_SEC" ] || [ "$age" -lt -"$SWARM_STALE_SEC" ]; then
          _SWARM_SNAP_STALE="$age"; raw=""
        fi
      fi
    fi
    _SWARM_SNAP="$raw"
  fi
  printf '%s' "$_SWARM_SNAP"
}
# Why the snapshot was unusable, for a log line that distinguishes "nothing
# answered" from "something answered with yesterday".
swarm_snapshot_why() {
  if [ -n "${_SWARM_SNAP_STALE:-}" ]; then printf 'its answer was %ss old' "$_SWARM_SNAP_STALE"
  else printf 'it did not answer'; fi
}

# How many agents are running for one programme, per the live view.
#
# NO ANSWER MEANS BUSY, NEVER ROOM. A down live view used to read as zero
# agents, so the scheduler filled every slot on a machine that already had a
# full set running. 99 is the number the original scripts used and it is the
# whole safety property of this function: the swarm holds when it cannot see.
swarm_live_count() { # <programme>
  local snap n
  snap=$(swarm_snapshot)
  [ -n "$snap" ] || { printf '99'; return; }
  n=$(printf '%s' "$snap" | jq --arg p "${1:-}" \
        '[.live[] | select($p == "" or .project == $p)] | length' 2>/dev/null)
  case "$n" in ''|*[!0-9]*) printf '99' ;; *) printf '%s' "$n" ;; esac
}

# ---- run records -------------------------------------------------------------
# A run is live when it has no .ended marker AND its agent's pid still exists.
# The marker alone is not enough: five August records had no marker and a dead
# pid, because the wrapper was killed before it could write one, and counting
# those as running made the launcher report eight running with three alive.
swarm_record_alive() { # <runs/xxx.json>
  [ -f "${1%.json}.ended" ] && return 1
  local pid
  pid=$(jq -r '.child_pid // .pid // 0' "$1" 2>/dev/null)
  [ "${pid:-0}" -gt 0 ] 2>/dev/null && kill -0 "$pid" 2>/dev/null
}

swarm_ticket_live() { # <ticket> — 0 when an agent is running for it
  local j
  for j in "$RUNS_DIR"/claim-"$1"-*.json; do
    [ -f "$j" ] && swarm_record_alive "$j" && return 0
  done
  return 1
}

swarm_running_total() {
  local n=0 j
  for j in "$RUNS_DIR"/claim-*.json; do
    [ -f "$j" ] && swarm_record_alive "$j" && n=$((n+1))
  done
  printf '%s' "$n"
}

# ---- tickets -----------------------------------------------------------------
# A ticket rolled into a batch ticket: the batch's one PR builds it, so no agent starts it alone.
LBL_BATCHED="${LBL_BATCHED:-$(swarm_opt labels.batched status:batched)}"
export LBL_BATCHED
# One open list of small fixes per screen (scripts/polish-list.sh), never one ticket per fix.
LBL_POLISH_LIST="${LBL_POLISH_LIST:-$(swarm_opt labels.polishList polish-list)}"
LBL_SCREEN_PREFIX="${LBL_SCREEN_PREFIX:-$(swarm_opt labels.screenPrefix screen:)}"
export LBL_POLISH_LIST LBL_SCREEN_PREFIX
# The statuses that mean "a person or another PR owns this; never send an agent".
# Read from the config so a project's own names are honoured, plus needsHuman and
# the hold label, which are the two stops the swarm itself sets.
swarm_blocking_labels() {
  printf '%s\n' "$LBL_IN_REVIEW" "$LBL_BLOCKED" "$LBL_NEEDS_HUMAN" "$LBL_PARKED" "$HOLD_LABEL" "$LBL_OWNER_DECISION" "$LBL_BATCHED" $DECISION_LABELS \
    | awk 'NF && !seen[$0]++'
}

# Is this ticket spawnable right now? Echoes a reason and returns 1 when not.
#
# "The issue is open" is true of every ticket until its PR MERGES, which is why
# the open-PR probe is here: on 2026-09-19 a version without it re-spawned three
# tickets whose PRs were already open and waiting on a person.
swarm_spawnable() { # <ticket>
  local t="$1" meta st lab l openpr
  meta=$(swarm_gh issue view "$t" --repo "$REPO_SLUG" --json state,labels \
           -q '.state+" "+([.labels[].name]|join(","))' 2>/dev/null)
  [ -n "$meta" ] || { echo "  #$t could not be read — skip"; return 1; }
  st=${meta%% *}; lab=${meta#* }
  [ "$st" = "OPEN" ] || { echo "  #$t $st — skip"; return 1; }
  while read -r l; do
    [ -n "$l" ] || continue
    case ",$lab," in *",$l,"*) echo "  #$t $l — skip"; return 1 ;; esac
  done <<EOS
$(swarm_blocking_labels)
EOS
  openpr=$(swarm_gh pr list --repo "$REPO_SLUG" --state open \
             --search "head:$BRANCH_PREFIX$t/" --json number -q 'length' 2>/dev/null)
  [ "${openpr:-0}" = "0" ] || { echo "  #$t has an open PR — skip"; return 1; }
  swarm_ticket_live "$t" && { echo "  #$t already running — skip"; return 1; }
  return 0
}

# A ticket's programme, from its labels; empty when it carries none.
swarm_programme_of() { # <ticket>
  swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels \
    -q "[.labels[].name | select(startswith(\"$SWARM_PROGRAMME_PREFIX\"))] | first // \"\"" 2>/dev/null \
    | sed "s/^$SWARM_PROGRAMME_PREFIX//"
}

# Spawn one agent. A brief file becomes CLAIM_EXTRA — that is the whole content
# of the 58 hand-written launchers this replaces.
#
# Output goes to a FILE, never a command substitution: the spawned agent inherits
# stdout, so capturing it with $(...) blocks until the agent exits. The scheduler
# logged nothing for forty minutes at a time while quietly spawning.
# The hold. `install.sh hold "<reason>"` writes it; while it exists nothing
# spawns, whichever job asks and however the supervisor came back. Stopping the
# task was not enough: on 2026-09-29 a stopped swarm was re-installed by someone
# nobody could name, waited out the plan's usage limit, and spent ~110M tokens in
# two hours re-running tickets that had failed the night before (#42).
SWARM_HOLD_FILE="${SWARM_HOLD_FILE:-$SWARM_DIR/HOLD}"
swarm_held() { [ -f "$SWARM_HOLD_FILE" ] || return 1; head -1 "$SWARM_HOLD_FILE"; }
# Process fixes trump everything (owner call 2026-10-20): a ticket wearing this label
# starts first, and a hold whose reason says it is "for process fixes", or that carries
# an `allow: process` line, still lets these through while it holds everything else.
SWARM_PROCESS_LABEL="${COORDINATOR_PROCESS_LABEL:-$(swarm_opt coordinator.processLabel process)}"
swarm_hold_lets_process() {
  [ -f "$SWARM_HOLD_FILE" ] || return 1
  grep -qiE 'for process fixes' <<<"$(head -1 "$SWARM_HOLD_FILE")" && return 0
  grep -qiE "^[[:space:]]*allow:[[:space:]]*(process|$SWARM_PROCESS_LABEL)[[:space:]]*\$" "$SWARM_HOLD_FILE"
}
# Read whole, then matched: a piped grep -q under pipefail can fail on SIGPIPE.
swarm_ticket_is_process() { # <ticket> — 0 when it wears the process label; unread is not
  local ls; ls=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '.labels[].name' 2>/dev/null) || return 1
  grep -qxF -- "$SWARM_PROCESS_LABEL" <<<"$ls"
}

swarm_spawn() { # <ticket> [brief-file] [budget]
  local t="$1" brief="${2:-}" budget="${3:-$SWARM_BUDGET_USD}" out
  local held
  if held=$(swarm_held); then
    if swarm_hold_lets_process && swarm_ticket_is_process "$t"; then
      echo "held for everything but process fixes — #$t is one: $held" >&2
    else
      echo "held — not spawning #$t: $held" >&2
      return 1
    fi
  fi
  out=$(mktemp)
  (
    [ -n "$brief" ] && [ -f "$brief" ] && CLAIM_EXTRA="$(cat "$brief")" && export CLAIM_EXTRA
    CLAIM_BUDGET_USD="$budget" CLAIM_REPO="${CLAIM_REPO:-$MAIN_REPO}" \
      "$SWARM_SPAWN" "$t" > "$out" 2>&1 < /dev/null
  )
  local rc=$?
  cat "$out"; rm -f "$out"
  return $rc
}

# Ask a status page to rebuild, when the project has one. No page: no ping, and
# nothing pretends otherwise.
swarm_ping_page() {
  [ -n "$SWARM_STATUS_REPO" ] || return 0
  swarm_gh api "repos/$SWARM_STATUS_REPO/dispatches" -f event_type=claim-changed >/dev/null 2>&1
}

export SWARM_DIR SWARM_HOLD_FILE SWARM_PROCESS_LABEL SWARM_LOGS RUNS_DIR SWARM_CAP SWARM_MIN_CPU_IDLE SWARM_MAX_LOAD SWARM_PORT SWARM_LIVE_URL
export SWARM_STATUS_REPO SWARM_REPORT_URL SWARM_BUDGET_USD SWARM_USAGE_CEILING SWARM_GH SWARM_CURL SWARM_SPAWN
export SWARM_PROGRAMME_PREFIX SWARM_TOKEN_FILE SWARM_STALE_SEC LBL_OWNER_DECISION
