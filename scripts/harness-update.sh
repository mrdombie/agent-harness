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
#   - install a kit whose own suites fail at the ref it is about to install
#   - change anything before it has printed what it is about to change
#
# WHAT IT NO LONGER DOES (2026-09-28)
#   It used to keep a SECOND pin — kit.repo / kit.ref in every consuming repo's
#   harness.json — and rewrite it here. The marketplace catalog already pins the
#   plugin and `claude plugin update` already applies that pin, so the second one
#   was a hand-maintained copy of a fact the CLI owns. Nothing else read it, and
#   the project it was written for carried no kit block at all. The test gate it
#   guarded is kept, moved onto the install it actually protects.
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
stale_version=""   # an install the CLI will refuse to move
stale_scope=""     # an install the update never reached

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
#
# EVERY RECORD, not the first. One plugin can be installed at more than one
# scope, and `claude plugin update` moves the user-scope record only. Measured
# 2026-09-24: this kit was current at user scope and ten commits behind at
# project scope, and reading .[0] reported neither — the stale one was invisible
# behind the healthy one. The scope is printed, because that is what makes the
# row actionable.
hr; echo "STALE INSTALLS"
stale=""
if [ -f "$INSTALLED" ] && [ -d "$MARKET_DIR" ]; then
  while IFS=$'\t' read -r full scope sha ver; do
    [ -n "$full" ] || continue
    mkt="${full##*@}"
    clone="$MARKET_DIR/$mkt"
    [ -d "$clone/.git" ] || continue

    # ONLY WHEN THE PLUGIN LIVES IN THE MARKETPLACE REPO. A marketplace can be a
    # catalogue whose entries point at other repositories ("source": {"source":
    # "url", ...}); its own HEAD then says nothing about any of them, and
    # comparing the two produces a confident false positive. Measured 2026-09-24:
    # superpowers-marketplace holds ten such entries and two files, and this
    # probe reported the superpowers plugin as stale against a clone that has
    # never contained it.
    #
    # A path source ("./", "plugins/x") IS the repo, so the comparison holds.
    bare="${full%%@*}"
    src=$(jq -r --arg n "$bare" '
            (.plugins // []) | map(select(.name == $n)) | .[0].source
            | if type == "string" then . else "" end' \
          "$clone/.claude-plugin/marketplace.json" 2>/dev/null)
    [ -n "$src" ] || continue

    head=$(git -C "$clone" rev-parse HEAD 2>/dev/null) || continue
    [ -n "$sha" ] && [ "$sha" != "$head" ] || continue
    # Same version at a different commit is the CLI refusing to move. A DIFFERENT
    # version means the update simply never reached this record — one plugin can
    # be installed at more than one scope and only the user one is updated. The
    # two need different advice, so read the clone's own manifest rather than
    # guessing from the installed side alone.
    cver=$(jq -r '.version // "-"' "$clone/${src#./}/.claude-plugin/plugin.json" 2>/dev/null \
           || echo "-")
    [ "$cver" != "-" ] || cver=$(jq -r '.version // "-"' "$clone/.claude-plugin/plugin.json" 2>/dev/null || echo "-")
    if [ "$cver" = "$ver" ]; then
      printf '  %-36s %-8s installed %s  clone %s  both "%s"  version did not move\n' \
        "$full" "$scope" "${sha:0:10}" "${head:0:10}" "$ver"
      stale_version="yes"
    else
      printf '  %-36s %-8s installed %s (%s)  clone %s (%s)  update did not reach this scope\n' \
        "$full" "$scope" "${sha:0:10}" "$ver" "${head:0:10}" "$cver"
      stale_scope="yes"
    fi
    stale="yes"
  done <<EOF
$(jq -r '(.plugins // .) | to_entries | .[]
         | . as $e
         | ($e.value | if type=="array" then . else [.] end)
         | .[]
         | [$e.key, (.scope // "-"), (.gitCommitSha // ""), (.version // "-")] | @tsv' "$INSTALLED" 2>/dev/null)
EOF
fi
if [ -n "$stale" ]; then
  [ -n "${stale_version:-}" ] && {
    echo "  -> version did not move: the CLI compares the manifest version, so it will"
    echo "     refuse to update. Bump it in the plugin's manifest, then run this again."
  }
  [ -n "${stale_scope:-}" ] && {
    echo "  -> update did not reach that scope: 'claude plugin update' moves the USER"
    echo "     record. Re-install at that scope, or drop the extra record."
  }
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

# ------------------------------------------------------------------- the kit
# WHICH KIT, AND WHERE ITS VERSION COMES FROM.
#
# This used to read kit.repo / kit.ref out of every consuming repo's
# harness.json and rewrite the ref there. That was a second pin beside the one
# the marketplace already keeps, hand-maintained, per project — and nothing but
# this script ever read it. Measured 2026-09-28: one reader, and the project it
# was written for carried no kit block at all, so the whole branch was dead.
#
# The marketplace IS the pin. `claude plugin marketplace update` moves the
# catalog, `claude plugin update` moves the install to what the catalog says,
# and installed_plugins.json records the sha that landed. What this script keeps
# is the part the CLI has no opinion about: REFUSING TO MOVE ONTO A RED KIT.
hr; echo "THE KIT"
# The plugin's NAME, from its own manifest — not the directory it happens to sit
# in. A worktree or a renamed clone must not change which install this is about.
_kitdir="$(cd "$(dirname "$0")/.." && pwd)"
KIT_PLUGIN=$(jq -r '.name // ""' "$_kitdir/.claude-plugin/plugin.json" 2>/dev/null)
[ -n "$KIT_PLUGIN" ] || KIT_PLUGIN="$(basename "$_kitdir")"
# WHICH INSTALL RECORD, AND WHICH CLONE. Never by assuming the marketplace is
# named after the plugin: installed_plugins.json keys are `<plugin>@<marketplace>`
# and every other plugin on a normal machine is `name@claude-plugins-official`.
# Assuming they match meant the whole test gate was skipped on any other
# naming — measured 2026-09-28 with a marketplace directory called `acme-tools`:
# "(no local clone of the kit's marketplace to compare against)", then the red
# kit installed with no suite ever run. It was not firing only by coincidence.
KIT_KEY=$(jq -r --arg n "$KIT_PLUGIN" '
    (.plugins // .) | keys[] | select(startswith($n + "@"))' \
  "$INSTALLED" 2>/dev/null | head -1)
[ -n "$KIT_KEY" ] || KIT_KEY="$KIT_PLUGIN@$KIT_PLUGIN"
KIT_MKT="${KIT_KEY##*@}"
KIT_SRC="$MARKET_DIR/$KIT_MKT"
KIT_TARGET=""
if [ -d "$KIT_SRC/.git" ]; then
  git -C "$KIT_SRC" fetch -q origin 2>/dev/null
  KIT_BR=$(git -C "$KIT_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null)
  KIT_TARGET=$(git -C "$KIT_SRC" rev-parse "origin/$KIT_BR" 2>/dev/null || true)
  KIT_HAVE=$(jq -r --arg k "$KIT_KEY" \
      '(.plugins // .)[$k] | (if type=="array" then .[0] else . end) | .gitCommitSha // ""' \
      "$INSTALLED" 2>/dev/null)
  printf '  installed %s   catalog %s\n' "${KIT_HAVE:0:12}" "${KIT_TARGET:0:12}"
  if [ -n "$KIT_TARGET" ] && [ "$KIT_HAVE" != "$KIT_TARGET" ]; then
    git -C "$KIT_SRC" log --oneline --no-decorate "${KIT_HAVE:-$KIT_TARGET}..$KIT_TARGET" 2>/dev/null \
      | sed 's/^/    /' | head -20
    BEHIND=1
  else
    echo "  the kit is current"
  fi
else
  echo "  (no local clone of the kit's marketplace to compare against)"
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

# THE TEST GATE, KEPT — and moved onto the thing it actually protects. The kit's
# own suites run AT THE TARGET REF before the kit is updated; a red kit is not
# installed, and nothing else in the estate is held up by it. This is the one
# check the CLI does not make: `claude plugin update` will happily move you onto
# a broken commit.
KIT_RED=0
if [ -n "$KIT_TARGET" ] && [ "${KIT_HAVE:-}" != "$KIT_TARGET" ]; then
  echo "testing the kit at ${KIT_TARGET:0:12} before installing it"
  STAGE=$(mktemp -d) || exit 1
  if git -C "$KIT_SRC" worktree add -q --detach "$STAGE" "$KIT_TARGET" 2>/dev/null; then
    for t in "$STAGE"/scripts/*.test.sh "$STAGE"/hooks/*.test.sh "$STAGE"/hooks/lib/*.test.sh; do
      [ -f "$t" ] || continue
      if bash "$t" >/dev/null 2>&1; then printf '  pass  %s\n' "$(basename "$t")"
      else printf '  FAIL  %s\n' "$(basename "$t")"; KIT_RED=1; fi
    done
    git -C "$KIT_SRC" worktree remove --force "$STAGE" 2>/dev/null || rm -rf "$STAGE"
  else
    echo "  could not materialise the kit at that ref — NOT installing it"
    KIT_RED=1; rm -rf "$STAGE"
  fi
  [ "$KIT_RED" -eq 1 ] && {
    hr
    echo "The kit's own suites fail at ${KIT_TARGET:0:12}. It is NOT being updated."
    echo "Moving onto a red kit is the defect this step exists to prevent."
  }
fi
hr

# Marketplaces, then plugins. Each is independent: one plugin failing to update
# is reported and the rest still move. The kit is skipped when its suites went
# red above.
APPLY_FAILED=0
[ "$KIT_RED" -eq 1 ] && APPLY_FAILED=1
if command -v claude >/dev/null; then
  echo "refreshing marketplaces"
  claude plugin marketplace update >/dev/null 2>&1 || { echo "  marketplace refresh failed"; APPLY_FAILED=1; }
  if [ -f "$INSTALLED" ]; then
    for p in $(jq -r '(.plugins // .) | keys[]' "$INSTALLED" 2>/dev/null); do
      if [ "$KIT_RED" -eq 1 ] && [ "${p%%@*}" = "$KIT_PLUGIN" ]; then
        printf '  HELD     %s  (suites red at the target ref)\n' "$p"; continue
      fi
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

exit "$APPLY_FAILED"
