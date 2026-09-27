#!/usr/bin/env bash
# status-line.sh — the one line at the bottom of every Claude Code window:
# how many agents are working, and how many things are waiting on the operator.
#
#   status-line.sh              the line, read from cache  (what Claude Code runs)
#   status-line.sh --print      compute it now, write the cache, print it
#   status-line.sh --install    point ~/.claude/settings.json at this script
#   status-line.sh --uninstall  take it back out
#
# A MISSING ANSWER IS NEVER "NOTHING RUNNING". The live view can be down, its
# snapshot can be twenty minutes old, the cache can itself go stale, and whatever
# is listening on the port can answer 200 with something that is not a snapshot at
# all — and in every one of those a count would be a lie in the most expensive
# direction, because an operator who reads "no agents working" off an
# idle-looking line starts more work on a machine that is already full. Each of
# them prints "swarm view not answering" instead.
#
# WHY IT IS CACHED. Claude Code runs this on every render. Measured: 170 ms to
# source swarm-env.sh, 95 ms for the live view, 581 ms for the forge — 846 ms of
# work per render. The render path therefore reads one file and exits, and the
# recompute happens in a detached process behind it. THE RENDER PATH NEVER CALLS
# THE FORGE, on any path including a cold start: the forge call has no timeout we
# can set, and swarm-env.sh's own header records it hanging on a keychain prompt
# with nowhere to show. A render that hangs is a window with no status line.
#
# A plugin cannot ship a statusLine: the CLI's plugin content list is
# .claude-plugin/, commands/, skills/, agents/, hooks/, themes/, output-styles/,
# monitors/, workflows/, SKILL.md, .mcp.json and .lsp.json, and nothing else. So
# the kit ships this script and --install writes the settings entry.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
WARNING='swarm view not answering'

# A number, or the default. Every one of these is read from the environment, and
# `[ "$age" -gt "120s" ]` returns 2 — which a plain `if` reads as "not stale", so
# one typo would show a stale count forever.
num() { case "${1:-}" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
TTL=$(num "${SWARM_STATUS_TTL:-}" 10)          # older than this: refresh behind you
MAX_AGE=$(num "${SWARM_STATUS_MAX_AGE:-}" 120) # older than this: no longer an answer
GH_TTL=$(num "${SWARM_STATUS_GH_TTL:-}" 120)   # how long one forge answer is reused

now() { if [ -n "${SWARM_NOW:-}" ]; then printf '%s' "$SWARM_NOW"; else date +%s; fi; }

# A file's mtime, on either stat, ALWAYS as digits.
#
# `stat -f %m` on GNU means file-SYSTEM: it treats %m as a filename, fails on
# that, and still prints six lines of filesystem blurb TO STDOUT at exit 1. So
# `stat -f %m || stat -c %Y` concatenated the blurb with the answer, and
# `$(( now - <blurb> ))` died under set -u with "File: unbound variable" — a
# blank status line and exit 1 on every Linux render, measured in ubuntu:latest.
# Hence both halves: the GNU form is tried first, and the result is classified
# rather than trusted.
mtime() {
  local m
  m=$(stat -c %Y "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m="" ;; esac
  [ -n "$m" ] || { m=$(stat -f %m "$1" 2>/dev/null); case "$m" in ''|*[!0-9]*) m=0 ;; esac; }
  printf '%s' "$m"
}
age_of() { printf '%s' "$(( $(now) - $(mtime "$1") ))"; }

# ---- the render path ---------------------------------------------------------
# Resolved WITHOUT sourcing anything: that is the 170 ms this path exists to not
# spend. toolkit-env.sh already records the state directory here for the global
# hooks, which run in sessions started outside any checkout — the same problem.
cheap_state_dir() {
  if [ -n "${HARNESS_STATE_DIR:-}" ]; then printf '%s' "$HARNESS_STATE_DIR"; return; fi
  local f="$HOME/.claude/.harness-last-state-dir"
  [ -s "$f" ] && head -1 "$f"
}

# The recompute, in a session of its own so a closed window cannot take it down.
#
# ONE AT A TIME. Without the lock every render inside the refresh window started
# another recompute — 20 renders, 20 processes, measured — and it is worst exactly
# when it hurts, because a slow live view holds each one open for the full curl
# timeout. The lock is a directory (an atomic create) with its age bounded, so a
# child killed before its trap cannot wedge the refresh forever.
#
# Stdin is closed deliberately: the child inherits the statusLine's session-JSON
# pipe otherwise, and holds it for as long as the recompute runs.
refresh_detached() { # <cache-path>
  [ -n "${SWARM_STATUS_NO_REFRESH:-}" ] && return 0
  # Overridable for the same reason every call out of the swarm is: a test that
  # has to swap a tracked file in the worktree leaves the recorder behind when it
  # dies mid-case, and the recorder can then be committed.
  local d lock; d="${SWARM_DETACH:-$(dirname "$SELF")/detach.sh}"; lock="$1.lock"
  [ -x "$d" ] || return 0
  if ! mkdir "$lock" 2>/dev/null; then
    [ "$(age_of "$lock")" -gt "$MAX_AGE" ] || return 0
    rmdir "$lock" 2>/dev/null; mkdir "$lock" 2>/dev/null || return 0
  fi
  "$d" bash "$SELF" --refresh "$1" >/dev/null 2>&1 </dev/null &
  return 0
}

render() {
  local state cache age
  state=$(cheap_state_dir)
  cache="${state:+$state/swarm/status-line.txt}"
  # No cache at all is a COLD START, not a stale answer — so it computes, and the
  # very first render is correct rather than a warning about nothing. It computes
  # WITHOUT the forge (--no-forge), because a render must not be able to hang.
  if [ -z "$cache" ] || [ ! -s "$cache" ]; then compute --no-forge "$cache"; return; fi
  age=$(age_of "$cache")
  # A negative age is a cache written "in the future" — a pinned or skewed clock.
  # That is not staleness, so it reads as current.
  if [ "$age" -gt "$MAX_AGE" ]; then printf '%s\n' "$WARNING"; else cat "$cache"; fi
  [ "$age" -gt "$TTL" ] && refresh_detached "$cache"
  return 0
}

# ---- computing the line ------------------------------------------------------
# How many things are waiting on the operator: open pull requests carrying the
# hold label. Cached in a file of its own, because this is the 581 ms.
#
# Three outcomes, and the third is the one that matters: a number, a cached
# number, or UNKNOWN. Never zero-because-we-could-not-ask.
hold_count() { # <ask-the-forge: 1|0>
  local f="$SWARM_DIR/hold-prs.count" n
  if [ -s "$f" ]; then
    # ONE staleness rule for both caches: over the limit is stale, everything
    # else is current. A negative age is a clock disagreeing with the
    # filesystem, not staleness, and refetching on it fired the forge call again
    # every time the two differed.
    [ "$(age_of "$f")" -le "$GH_TTL" ] && { cat "$f"; return; }
  fi
  if [ "${1:-1}" != 1 ]; then
    # The render path. A number we already have is still an answer; asking is not
    # allowed here, so with nothing cached the honest word is UNKNOWN.
    if [ -s "$f" ]; then cat "$f"; else printf 'UNKNOWN'; fi
    return
  fi
  n=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --label "$HOLD_LABEL" \
        --limit 100 --json number -q 'length' 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*)
      if [ -s "$f" ]; then cat "$f"; else printf 'UNKNOWN'; fi ;;
    *)
      mkdir -p "$SWARM_DIR" 2>/dev/null
      printf '%s\n' "$n" > "$f.tmp" && mv "$f.tmp" "$f"
      printf '%s' "$n" ;;
  esac
}

# Anything that is not a plain count is UNKNOWN. The catch-all used to print the
# value it could not classify, so an empty count rendered as "·  need you".
compose() { # <agents> <holds>
  local line
  case "${1:-}" in
    ''|*[!0-9]*) line="$WARNING" ;;
    0)           line='no agents working' ;;
    1)           line='1 agent working' ;;
    *)           line="$1 agents working" ;;
  esac
  case "${2:-}" in
    ''|*[!0-9]*) line="$line · approvals unknown" ;;
    0)           : ;;
    1)           line="$line · 1 needs you" ;;
    *)           line="$line · $2 need you" ;;
  esac
  printf '%s\n' "$line"
}

compute() { # [--no-forge] [cache-path]
  local ask=1 want_cache=""
  while [ $# -gt 0 ]; do
    case "$1" in --no-forge) ask=0 ;; *) want_cache="$1" ;; esac; shift
  done
  . "$(dirname "$SELF")/swarm-env.sh" || { printf '%s\n' "$WARNING"; return 0; }
  local snap agents line cache
  snap=$(swarm_snapshot)
  # The shape is checked, not assumed. `jq '.live | length'` answers 0 for a body
  # with no `live` key at all — so anything on the port that returns 200 and is
  # not a snapshot printed the one sentence this file exists to forbid. Its
  # sibling swarm_live_count already fails safe this way.
  agents=$(printf '%s' "$snap" \
    | jq -e 'if (.live|type) == "array" then (.live|length) else error("not a snapshot") end' 2>/dev/null) || agents=UNKNOWN
  line=$(compose "$agents" "$(hold_count "$ask")")
  # The path the RENDER path resolved, when it gave one. Resolving it twice —
  # once from the recorded state dir and once from the checkout's config — put a
  # window on a machine with two projects reading a cache nothing was refreshing.
  cache="${want_cache:-$SWARM_DIR/status-line.txt}"
  mkdir -p "$(dirname "$cache")" 2>/dev/null
  printf '%s\n' "$line" > "$cache.tmp" && mv "$cache.tmp" "$cache"
  printf '%s\n' "$line"
}

# ---- wiring it into the CLI --------------------------------------------------
settings_path() { printf '%s' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }

# Refuses on unparseable settings and writes through a temp file, so a settings
# file this script cannot read is never a settings file this script destroys.
edit_settings() { # <jq program>
  local f; f=$(settings_path)
  mkdir -p "$(dirname "$f")" 2>/dev/null
  [ -f "$f" ] || printf '{}\n' > "$f"
  jq -e . "$f" >/dev/null 2>&1 || {
    echo "status-line: $f is not valid JSON — refusing to write it." >&2; return 1; }
  # @sh quotes the path, so a kit installed under a directory with a space in it
  # does not write a command that silently resolves to nothing.
  jq --arg self "$SELF" "$1" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

case "${1:---render}" in
  --render)  render ;;
  --print)   compute ;;
  --refresh) shift; compute "$@" >/dev/null
             [ -n "${1:-}" ] && rmdir "$1.lock" 2>/dev/null
             exit 0 ;;
  --install)
    edit_settings '.statusLine = {type: "command", command: ("bash " + ($self|@sh))}' || exit 1
    echo "status-line: $(settings_path) now runs $SELF"
    echo "             re-run --install after a kit update; the path carries its version." ;;
  --uninstall)
    edit_settings 'del(.statusLine)' || exit 1
    echo "status-line: removed from $(settings_path)" ;;
  -h|--help) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *) echo "status-line: no such option '$1'" >&2; exit 2 ;;
esac
