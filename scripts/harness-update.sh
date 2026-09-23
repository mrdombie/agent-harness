#!/usr/bin/env bash
# harness-update.sh — move every copy of the harness forward together, and say what changed.
#
# WHY THIS EXISTS
#   There was no update chain. Every hop between a source and the place that
#   consumes it was a manual copy, and nothing reported when one fell behind.
#   Measured on the machine this was written for: 14 plugins across 5
#   marketplaces, 6 untouched for six weeks, one plugin installed TWICE from two
#   marketplaces with both enabled at different versions, and 9 of 9 hook copies
#   drifted from their repo in both directions.
#
#   The duplicate and the drift are the same defect: two copies of one thing,
#   both live, silently disagreeing. So this command REFUSES to update an estate
#   that still carries a duplicate — updating an unreconciled estate makes the
#   drift worse, it does not fix it.
#
# WHAT IT WILL NOT DO
#   - replace the pinned fetch with "latest": a build must stay reproducible, so
#     the pin moves deliberately and never floats
#   - move the pin when the kit's own suites fail at the target ref
#   - change anything before it has printed what it is about to change
#
# USAGE
#   harness-update.sh --check     report drift, change nothing, exit non-zero if behind
#   harness-update.sh             report, then update
set -uo pipefail

MODE=report-and-update
case "${1:-}" in
  --check) MODE=check-only ;;
  "") ;;
  *) echo "usage: $(basename "$0") [--check]" >&2; exit 2 ;;
esac

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MARKET_DIR="$CLAUDE_DIR/plugins/marketplaces"
INSTALLED="$CLAUDE_DIR/plugins/installed_plugins.json"
SETTINGS="$CLAUDE_DIR/settings.json"

command -v jq >/dev/null || { echo "harness-update: jq is required" >&2; exit 2; }

BEHIND=0     # anything at all is out of date
BLOCKED=0    # something must be reconciled before updating

hr() { printf '%s\n' "----------------------------------------------------------------"; }

# ---------------------------------------------------------------- marketplaces
hr; echo "MARKETPLACES"
if [ -d "$MARKET_DIR" ]; then
  for d in "$MARKET_DIR"/*; do
    [ -d "$d/.git" ] || continue
    name=$(basename "$d")
    git -C "$d" fetch -q origin 2>/dev/null
    br=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
    n=$(git -C "$d" rev-list --count "HEAD..origin/$br" 2>/dev/null || echo "?")
    if [ "$n" = "0" ]; then
      printf '  %-28s level\n' "$name"
    else
      printf '  %-28s %s commit(s) behind\n' "$name" "$n"
      BEHIND=1
    fi
  done
else
  echo "  (no marketplaces directory)"
fi

# -------------------------------------------------------------------- plugins
hr; echo "PLUGINS"
if [ -f "$INSTALLED" ]; then
  jq -r '
    (.plugins // .) | to_entries
    | map({ name: .key, e: (if (.value|type) == "array" then .value[0] else .value end) })
    | sort_by(.e.lastUpdated // .e.installedAt // "")
    | .[]
    | "  \(.name[0:34] | . + (" " * (34 - length)))\((.e.version // "-")[0:12] | . + (" " * (12 - length)))\((.e.lastUpdated // .e.installedAt // "-")[0:10])"
  ' "$INSTALLED" 2>/dev/null
else
  echo "  (no installed_plugins.json)"
fi

# ------------------------------------------------------------------ duplicates
# Two ENABLED plugins with the same bare name from different marketplaces. This
# is the condition that stops the run: an estate that disagrees with itself
# cannot be moved forward coherently.
hr; echo "DUPLICATES"
dups=""
if [ -f "$SETTINGS" ]; then
  dups=$(jq -r '
    (.enabledPlugins // {}) | to_entries
    | map(select(.value == true) | .key)
    | map({ bare: (. | split("@")[0]), full: . })
    | group_by(.bare) | map(select(length > 1))
    | .[] | .[].full
  ' "$SETTINGS" 2>/dev/null)
fi
if [ -n "$dups" ]; then
  printf '%s\n' "$dups" | while read -r f; do
    [ -n "$f" ] || continue
    v=$(jq -r --arg k "$f" '(.plugins // .)[$k] | (if type=="array" then .[0] else . end) | .version // "-"' "$INSTALLED" 2>/dev/null)
    printf '  ENABLED TWICE  %-36s version %s\n' "$f" "$v"
  done
  echo "  -> reconcile these before updating: two live copies of one plugin"
  BLOCKED=1
else
  echo "  none"
fi

# ----------------------------------------------------------------- the kit pin
hr; echo "THE KIT PIN"
CFG="${HARNESS_CFG_PATH:-}"
[ -n "$CFG" ] || CFG="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/harness.json"
if [ -f "$CFG" ]; then
  read -r KIT_REPO KIT_REF < <(jq -r '"\(.kit.repo // "") \(.kit.ref // "")"' "$CFG")
  if [ -n "$KIT_REPO" ] && [ -n "$KIT_REF" ]; then
    printf '  pinned at %s  (%s)\n' "${KIT_REF:0:12}" "$KIT_REPO"
    KIT_SRC="$MARKET_DIR/$(basename "$KIT_REPO")"
    if [ -d "$KIT_SRC/.git" ]; then
      ahead=$(git -C "$KIT_SRC" rev-list --count "$KIT_REF..origin/HEAD" 2>/dev/null \
           || git -C "$KIT_SRC" rev-list --count "$KIT_REF..origin/main" 2>/dev/null || echo "?")
      if [ "$ahead" = "0" ]; then
        echo "  the pin is current"
      else
        echo "  $ahead commit(s) would be applied:"
        git -C "$KIT_SRC" log --oneline --no-decorate "$KIT_REF..origin/main" 2>/dev/null | sed 's/^/    /' | head -20
        BEHIND=1
      fi
    else
      echo "  (no local clone of the kit to compare against)"
    fi
  else
    echo "  harness.json names no kit.repo / kit.ref"
  fi
else
  echo "  no harness.json found — run this inside a configured checkout"
fi

# ------------------------------------------------------------------- the verdict
hr
if [ "$BLOCKED" -eq 1 ]; then
  echo "STOP — the estate carries a duplicate. Nothing was changed."
  exit 1
fi
if [ "$MODE" = check-only ]; then
  [ "$BEHIND" -eq 1 ] && { echo "BEHIND — run without --check to apply."; exit 1; }
  echo "LEVEL — everything is current."
  exit 0
fi

echo "Everything above is what will change. Applying."
# The apply half is deliberately not written yet: the reporting half is what makes
# the estate legible, and it has to be trusted before anything acts on it.
echo "(apply step not implemented — reporting only for now)"
exit 0
