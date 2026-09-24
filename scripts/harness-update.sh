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

# --------------------------------------------------------------- stale installs
# `claude plugin update` compares the VERSION STRING in the plugin manifest, not
# the commit. A plugin whose repo has moved but whose version has not is reported
# as "already at the latest version" and nothing is installed. Measured
# 2026-09-24: this kit's own plugin sat at the commit it was first installed at
# while its marketplace clone was eight commits ahead, both reading 0.2.0, and
# the running copy was missing a guard that had been merged hours earlier.
#
# So the REF is the truth here, exactly as it is for a claim. Compare the sha the
# install recorded against the clone's HEAD and say when they disagree.
hr; echo "STALE INSTALLS"
stale=""
if [ -f "$INSTALLED" ] && [ -d "$MARKET_DIR" ]; then
  while IFS=$'\t' read -r full sha ver; do
    [ -n "$full" ] || continue
    mkt="${full##*@}"
    clone="$MARKET_DIR/$mkt"
    [ -d "$clone/.git" ] || continue
    head=$(git -C "$clone" rev-parse HEAD 2>/dev/null) || continue
    [ -n "$sha" ] && [ "$sha" != "$head" ] || continue
    printf '  %-36s installed %s  clone %s  both "%s"\n' "$full" "${sha:0:10}" "${head:0:10}" "$ver"
    stale="yes"
  done <<EOF
$(jq -r '(.plugins // .) | to_entries | .[]
         | . as $e | ($e.value | if type=="array" then .[0] else . end) as $v
         | [$e.key, ($v.gitCommitSha // ""), ($v.version // "-")] | @tsv' "$INSTALLED" 2>/dev/null)
EOF
fi
if [ -n "$stale" ]; then
  echo "  -> the manifest version did not change, so the CLI will refuse to update."
  echo "     Bump the version in the plugin's manifest, then run this again."
  BEHIND=1
else
  echo "  none"
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

if [ "$BEHIND" -eq 0 ]; then
  echo "LEVEL — nothing to apply."
  exit 0
fi

echo "Everything above is what will change. Applying."
hr

# 1. Marketplaces, then plugins. Each is independent: one plugin failing to
#    update is reported and the rest still move. A failure here never touches
#    the pin, which is the only change that can break a build.
APPLY_FAILED=0
if command -v claude >/dev/null; then
  echo "refreshing marketplaces"
  claude plugin marketplace update >/dev/null 2>&1 || { echo "  marketplace refresh failed"; APPLY_FAILED=1; }
  if [ -f "$INSTALLED" ]; then
    for p in $(jq -r '(.plugins // .) | keys[]' "$INSTALLED" 2>/dev/null); do
      before=$(jq -r --arg k "$p" '(.plugins // .)[$k] | (if type=="array" then .[0] else . end) | .gitCommitSha // ""' "$INSTALLED" 2>/dev/null)
      if claude plugin update "$p" >/dev/null 2>&1; then
        after=$(jq -r --arg k "$p" '(.plugins // .)[$k] | (if type=="array" then .[0] else . end) | .gitCommitSha // ""' "$INSTALLED" 2>/dev/null)
        if [ -n "$before" ] && [ "$before" = "$after" ] && [ -n "$stale" ]; then
          # The CLI exits 0 saying "already at the latest version" when only the
          # commit moved. Calling that "updated" is how an estate stays behind
          # while a command reports it current.
          printf '  NO-OP    %s  (still %s — bump its manifest version)\n' "$p" "${after:0:10}"
          APPLY_FAILED=1
        else
          printf '  updated  %s\n' "$p"
        fi
      else
        printf '  FAILED   %s\n' "$p"; APPLY_FAILED=1
      fi
    done
  fi
else
  echo "the claude CLI is not on PATH — marketplaces and plugins not refreshed"
  APPLY_FAILED=1
fi

# 2. The pin. This is the one change that decides what a BUILD runs, so it moves
#    only after the kit's own suites pass AT THE TARGET REF — not at the ref
#    currently installed, and not on the strength of them having passed here.
hr
if [ -z "${KIT_REPO:-}" ] || [ -z "${KIT_REF:-}" ] || [ ! -f "$CFG" ]; then
  echo "no kit pin to move"
  exit "$APPLY_FAILED"
fi

KIT_SRC="$MARKET_DIR/$(basename "$KIT_REPO")"
TARGET=$(git -C "$KIT_SRC" rev-parse origin/main 2>/dev/null || true)
if [ -z "$TARGET" ] || [ "$TARGET" = "$KIT_REF" ]; then
  echo "the pin is already current"
  exit "$APPLY_FAILED"
fi

echo "testing the kit at ${TARGET:0:12} before moving the pin"
STAGE=$(mktemp -d) || exit 1
if ! git -C "$KIT_SRC" worktree add -q --detach "$STAGE" "$TARGET" 2>/dev/null; then
  echo "  could not materialise the kit at that ref — pin UNCHANGED"
  rm -rf "$STAGE"; exit 1
fi

SUITES_FAILED=0
for t in "$STAGE"/scripts/*.test.sh "$STAGE"/hooks/*.test.sh; do
  [ -f "$t" ] || continue
  if bash "$t" >/dev/null 2>&1; then
    printf '  pass  %s\n' "$(basename "$t")"
  else
    printf '  FAIL  %s\n' "$(basename "$t")"; SUITES_FAILED=1
  fi
done
git -C "$KIT_SRC" worktree remove --force "$STAGE" 2>/dev/null || rm -rf "$STAGE"

if [ "$SUITES_FAILED" -ne 0 ]; then
  hr
  echo "STOP — the kit's own suites fail at ${TARGET:0:12}. The pin is UNCHANGED."
  echo "A pin that moves past a red kit is the defect this step exists to prevent."
  exit 1
fi

# Rewrite in place, atomically: a half-written harness.json is a repo nobody can
# resolve the kit from.
tmpcfg=$(mktemp) || exit 1
if jq --arg r "$TARGET" '.kit.ref = $r' "$CFG" > "$tmpcfg" && [ -s "$tmpcfg" ]; then
  mv "$tmpcfg" "$CFG"
  echo "pin moved: ${KIT_REF:0:12} -> ${TARGET:0:12}"
  echo "commit .claude/harness.json to apply it to the project."
else
  rm -f "$tmpcfg"
  echo "could not rewrite $CFG — pin UNCHANGED"; exit 1
fi

exit "$APPLY_FAILED"
