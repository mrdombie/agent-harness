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
# snapshot can be twenty minutes old, and this cache can itself go stale — and in
# every one of those cases a count would be a lie in the most expensive
# direction, because an operator who reads "no agents working" off an idle-looking
# line starts more work on a machine that is already full. So each of them prints
# "swarm view not answering" instead. swarm_snapshot() already discards an answer
# older than swarm.staleSec; this adds the same rule one layer up, to the cache.
#
# WHY IT IS CACHED. Claude Code runs this on every render. Measured: 170 ms to
# source swarm-env.sh, 95 ms for the live view, 581 ms for the GitHub call — 846 ms
# of work per keystroke-ish. The render path therefore reads one file and exits,
# and the recompute happens in a detached process behind it. No render waits on
# GitHub, which is the whole point of the split.
#
# A plugin cannot ship a statusLine: the CLI's plugin content list is
# .claude-plugin/, commands/, skills/, agents/, hooks/, themes/, output-styles/,
# monitors/, workflows/, SKILL.md, .mcp.json and .lsp.json, and nothing else. So
# the kit ships this script and --install writes the settings entry.
set -uo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
WARNING='swarm view not answering'

# How long a cached line is current, and how long before it is a stale answer
# rather than a slightly old one. The second number is the honesty limit.
TTL="${SWARM_STATUS_TTL:-10}"
MAX_AGE="${SWARM_STATUS_MAX_AGE:-120}"
GH_TTL="${SWARM_STATUS_GH_TTL:-120}"

now() { if [ -n "${SWARM_NOW:-}" ]; then printf '%s' "$SWARM_NOW"; else date +%s; fi; }

# mtime, on either stat. BSD and GNU disagree about the flag, and a script that
# knows one of them reads every file as epoch 0 on the other — which would make
# every cache look an eternity stale and print the warning forever.
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf 0; }

# ---- the render path ---------------------------------------------------------
# Resolved WITHOUT sourcing anything: that is the 170 ms this path exists to not
# spend. toolkit-env.sh already records the state directory here for the global
# hooks, which run in sessions started outside any checkout — the same problem.
cheap_state_dir() {
  if [ -n "${HARNESS_STATE_DIR:-}" ]; then printf '%s' "$HARNESS_STATE_DIR"; return; fi
  local f="$HOME/.claude/.harness-last-state-dir"
  [ -s "$f" ] && head -1 "$f"
}

refresh_detached() {
  [ -n "${SWARM_STATUS_NO_REFRESH:-}" ] && return 0
  local d; d="$(dirname "$SELF")/detach.sh"
  [ -x "$d" ] || return 0
  "$d" bash "$SELF" --refresh >/dev/null 2>&1 &
  return 0
}

render() {
  local state cache age
  state=$(cheap_state_dir)
  cache="${state:+$state/swarm/status-line.txt}"
  # No cache at all is a COLD START, not a stale answer — so it computes, and the
  # very first render is correct rather than a warning about nothing.
  if [ -z "$cache" ] || [ ! -s "$cache" ]; then compute; return; fi
  age=$(( $(now) - $(mtime "$cache") ))
  # A negative age is a cache written "in the future" — a pinned clock or a skewed
  # one. That is not staleness, so it reads as current.
  if [ "$age" -gt "$MAX_AGE" ]; then
    printf '%s\n' "$WARNING"
  else
    cat "$cache"
  fi
  [ "$age" -gt "$TTL" ] && refresh_detached
  return 0
}

# ---- computing the line ------------------------------------------------------
# How many things are waiting on the operator: open pull requests carrying the
# hold label. Cached in a file of its own, because this is the 581 ms.
#
# Three outcomes, and the third is the one that matters: a number, a cached
# number, or UNKNOWN. Never zero-because-we-could-not-ask.
hold_count() {
  local f="$SWARM_DIR/hold-prs.count" n age
  if [ -s "$f" ]; then
    age=$(( $(now) - $(mtime "$f") ))
    # ONE staleness rule for both caches: over the limit is stale, everything else
    # is current. A negative age — a pinned or skewed clock — is not staleness, and
    # the version that refetched on it made the GitHub call fire again whenever the
    # clock disagreed with the filesystem.
    [ "$age" -le "$GH_TTL" ] && { cat "$f"; return; }
  fi
  n=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --label "$HOLD_LABEL" \
        --limit 100 --json number -q 'length' 2>/dev/null)
  case "$n" in
    ''|*[!0-9]*)
      # It did not answer. A number we had earlier is still better than a guess;
      # with nothing at all, say so rather than imply none.
      if [ -s "$f" ]; then cat "$f"; else printf 'UNKNOWN'; fi ;;
    *)
      printf '%s\n' "$n" > "$f.$$" && mv "$f.$$" "$f"
      printf '%s' "$n" ;;
  esac
}

compose() { # <agents-or-UNKNOWN> <holds-or-UNKNOWN>
  local a="$1" h="$2" line
  case "$a" in
    UNKNOWN) line="$WARNING" ;;
    0)       line='no agents working' ;;
    1)       line='1 agent working' ;;
    *)       line="$a agents working" ;;
  esac
  case "$h" in
    UNKNOWN) line="$line · approvals unknown" ;;
    0)       : ;;
    1)       line="$line · 1 needs you" ;;
    *)       line="$line · $h need you" ;;
  esac
  printf '%s\n' "$line"
}

compute() {
  . "$(dirname "$SELF")/swarm-env.sh" || { printf '%s\n' "$WARNING"; return 0; }
  local snap agents holds line cache
  snap=$(swarm_snapshot)
  if [ -n "$snap" ]; then
    agents=$(printf '%s' "$snap" | jq '.live | length' 2>/dev/null)
    case "$agents" in ''|*[!0-9]*) agents=UNKNOWN ;; esac
  else
    agents=UNKNOWN
  fi
  holds=$(hold_count)
  line=$(compose "$agents" "$holds")
  cache="$SWARM_DIR/status-line.txt"
  mkdir -p "$SWARM_DIR" 2>/dev/null
  printf '%s\n' "$line" > "$cache.$$" && mv "$cache.$$" "$cache"
  printf '%s\n' "$line"
}

# ---- wiring it into the CLI --------------------------------------------------
settings_path() { printf '%s' "${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"; }

# Refuses on unparseable settings and writes through a temp file, so a settings
# file this script cannot read is never a settings file this script destroys.
edit_settings() { # <jq program>
  local f; f=$(settings_path)
  [ -f "$f" ] || printf '{}\n' > "$f"
  jq -e . "$f" >/dev/null 2>&1 || {
    echo "status-line: $f is not valid JSON — refusing to write it." >&2; return 1; }
  jq --arg cmd "bash $SELF" "$1" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

case "${1:---render}" in
  --render)  render ;;
  --print)   compute ;;
  --refresh) compute >/dev/null ;;
  --install)
    edit_settings '.statusLine = {type: "command", command: $cmd}' || exit 1
    echo "status-line: $(settings_path) now runs $SELF"
    echo "             re-run --install after a kit update; the path carries its version." ;;
  --uninstall)
    edit_settings 'del(.statusLine)' || exit 1
    echo "status-line: removed from $(settings_path)" ;;
  -h|--help) sed -n '2,10p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *) echo "status-line: no such option '$1'" >&2; exit 2 ;;
esac
