#!/usr/bin/env bash
# retire-duplicates.sh — take a machine's own copies of the kit out of the load
# path, and un-register the hooks it double-fires.
#
# WHY A SCRIPT AND NOT A SENTENCE IN A README
#   A second machine started running agents against the same project on
#   2026-09-28 and inherited none of the first machine's ~/.claude. Making
#   BOTH machines carry one identical set means the removal has to be a
#   repeatable operation, not a tidy-up somebody did once and remembered.
#
# WHAT IT TOUCHES — only a machine's own ~/.claude:
#   commands/<name>.md            for every skill the plugin ships
#   agents/<name>.md              for every agent the plugin ships
#   hooks/<name>                  for every hook the plugin registers
#   settings.json                 the registrations for those hooks
#
#   Files are MOVED to ~/.claude/retired-<date>/ — never deleted. settings.json
#   is copied to settings.json.before-<date> before it is rewritten.
#
# WHAT IT NEVER TOUCHES
#   ~/.claude/plugins (the live install), a consuming repo (that is a PR, and
#   check-single-source.sh is what fails there), and anything the plugin does
#   not ship: a machine-local command the kit has no copy of is left alone and
#   reported, because deleting it would lose it.
#
# USAGE
#   retire-duplicates.sh --check    report, change nothing, non-zero if any
#   retire-duplicates.sh            report, then move
set -uo pipefail
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
C="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
MODE=apply; [ "${1:-}" = "--check" ] && MODE=check
[ "${1:-}" = "" ] || [ "$MODE" = check ] || { echo "usage: $(basename "$0") [--check]" >&2; exit 2; }
command -v jq >/dev/null || { echo "retire-duplicates: jq is required" >&2; exit 2; }

STAMP=$(date +%Y-%m-%d)
ARCHIVE="$C/retired-$STAMP"

SKILLS=(); for d in "$KIT"/skills/*/; do [ -f "$d/SKILL.md" ] && SKILLS+=("$(basename "$d")"); done
AGENTS=(); for f in "$KIT"/agents/*.md; do [ -f "$f" ] && AGENTS+=("$(basename "$f")"); done
HOOKS=(); while read -r n; do [ -n "$n" ] && HOOKS+=("$n"); done < <(
  jq -r '[.hooks[][].hooks[].command] | .[] | capture("hooks/(?<n>[A-Za-z0-9._-]+)").n' \
    "$KIT/hooks/hooks.json" 2>/dev/null | sort -u)

MOVE=(); KEEP=()
for n in "${SKILLS[@]}"; do
  [ -f "$C/commands/$n.md" ] && MOVE+=("commands/$n.md")
  [ -f "$C/skills/$n/SKILL.md" ] && MOVE+=("skills/$n")
done
for n in "${AGENTS[@]}"; do [ -f "$C/agents/$n" ] && MOVE+=("agents/$n"); done
for n in "${HOOKS[@]}"; do
  [ -e "$C/hooks/$n" ] && MOVE+=("hooks/$n")
  # Everything that belongs to that hook goes with it: its self-test, the python
  # judge a shell wrapper execs, its case table, and any .bak left by an edit.
  # A wrapper moved without its judge leaves a hook that cannot run, which is
  # worse than leaving both.
  case "$n" in *.sh) base="${n%.sh}" ;; *) base="$n" ;; esac
  for comp in "$base.test.sh" "$base.py" "$base.cases.tsv"; do
    [ "$comp" = "$n" ] && continue
    [ -f "$C/hooks/$comp" ] && MOVE+=("hooks/$comp")
  done
  for b in "$C/hooks/$n".bak* "$C/hooks/$base.py".bak*; do
    [ -f "$b" ] && MOVE+=("hooks/$(basename "$b")")
  done
done
# The shared library the hooks source. Not registered, so the loop above cannot
# see it; leaving it behind is a file nothing reads.
[ -f "$KIT/hooks/lib/claude-session.sh" ] && [ -d "$C/hooks/lib" ] && MOVE+=("hooks/lib")

# Everything in commands/ the plugin does NOT ship. Reported, never moved.
if [ -d "$C/commands" ]; then
  for f in "$C"/commands/*.md; do
    [ -f "$f" ] || continue
    b=$(basename "$f" .md); mine=0
    for n in "${SKILLS[@]}"; do [ "$n" = "$b" ] && mine=1; done
    [ "$mine" -eq 0 ] && KEEP+=("commands/$b.md")
  done
fi

# Which registrations in settings.json name a hook the plugin registers.
REG=()
if [ -f "$C/settings.json" ]; then
  for n in "${HOOKS[@]}"; do
    jq -r '[.hooks // {} | .[][].hooks[].command] | join("\n")' "$C/settings.json" 2>/dev/null \
      | grep -qF "$n" && REG+=("$n")
  done
fi

echo "TO RETIRE  (moved to $ARCHIVE)"
if [ "${#MOVE[@]}" -eq 0 ]; then echo "  none"; else printf '  %s\n' "${MOVE[@]}"; fi
echo
echo "TO UN-REGISTER  (from $C/settings.json)"
if [ "${#REG[@]}" -eq 0 ]; then echo "  none"; else printf '  %s\n' "${REG[@]}"; fi
echo
if [ "${#KEEP[@]}" -gt 0 ]; then
  echo "LEFT ALONE  (the plugin ships no copy — move these into the kit, do not delete them)"
  printf '  %s\n' "${KEEP[@]}"
  echo
fi

N=$(( ${#MOVE[@]} + ${#REG[@]} ))
if [ "$N" -eq 0 ]; then echo "LEVEL — this machine carries no duplicate of anything the plugin provides."; exit 0; fi
if [ "$MODE" = check ]; then echo "BEHIND — $N item(s). Run without --check to apply."; exit 1; fi

# ORDER MATTERS, AND GETTING IT WRONG DISARMS THE MACHINE. This removes hooks a
# machine is currently running and un-registers them; the plugin only takes over
# once the INSTALLED copy registers them. Run it against an install that predates
# them and every guard is gone until the next `claude plugin update` — measured
# on 2026-09-28 by doing exactly that: ten registrations became one, and the
# installed plugin at that moment registered six of the nine.
#
# So compare against the INSTALLED plugin, not this checkout. A checkout is what
# you are about to ship; the install is what is running.
INSTALLED_ROOT=$(jq -r --arg k "$(jq -r '.name // ""' "$KIT/.claude-plugin/plugin.json" 2>/dev/null)" '
    (.plugins // .) | to_entries
    | map(select(.key | startswith($k + "@")))
    | map(.value | if type=="array" then .[] else . end)
    | map(select(.scope == "user")) | .[0].installPath // ""
  ' "$C/plugins/installed_plugins.json" 2>/dev/null)
if [ -n "$INSTALLED_ROOT" ] && [ -f "$INSTALLED_ROOT/hooks/hooks.json" ]; then
  live=$(jq -r '[.hooks[][].hooks[].command] | .[] | capture("hooks/(?<n>[A-Za-z0-9._-]+)").n' \
           "$INSTALLED_ROOT/hooks/hooks.json" 2>/dev/null | sort -u)
  missing=""
  for n in "${REG[@]}"; do
    printf '%s\n' "$live" | grep -qx "$n" || missing="$missing $n"
  done
  if [ -n "$missing" ]; then
    echo "STOP — the INSTALLED plugin does not register:$missing"
    echo "  installed: $INSTALLED_ROOT"
    echo "  Removing them now would leave this machine with no guard at all until"
    echo "  the next update. Ship the kit, run 'claude plugin update', then this."
    echo "Nothing was changed."
    exit 1
  fi
else
  echo "STOP — cannot read the installed plugin's hooks.json, so there is no way to"
  echo "  tell whether it would take over the hooks this is about to remove."
  echo "  Install the plugin first. Nothing was changed."
  exit 1
fi

echo "Applying."
mkdir -p "$ARCHIVE" || exit 1
for rel in "${MOVE[@]}"; do
  mkdir -p "$ARCHIVE/$(dirname "$rel")"
  if mv "$C/$rel" "$ARCHIVE/$rel" 2>/dev/null; then printf '  moved      %s\n' "$rel"
  else printf '  FAILED     %s\n' "$rel"; fi
done

if [ "${#REG[@]}" -gt 0 ]; then
  cp "$C/settings.json" "$C/settings.json.before-$STAMP" || exit 1
  names=$(printf '%s\n' "${REG[@]}" | jq -Rsc 'split("\n") | map(select(length>0))')
  tmp=$(mktemp) || exit 1
  # Drop the matching hook entries, then any group left with no hooks, then any
  # event left with no groups. A group with an empty `hooks` array is not
  # harmless: Claude Code reads it as a malformed matcher.
  if jq --argjson names "$names" '
      .hooks |= (
        with_entries(
          .value |= ( map(.hooks |= map(select(
                          .command as $c | ($names | any(. as $n | $c | contains($n))) | not )))
                    | map(select((.hooks | length) > 0)) )
        ) | with_entries(select((.value | length) > 0))
      )' "$C/settings.json" > "$tmp" && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null; then
    mv "$tmp" "$C/settings.json"
    printf '  un-registered %d hook(s); previous settings kept at settings.json.before-%s\n' "${#REG[@]}" "$STAMP"
  else
    rm -f "$tmp"; echo "  FAILED to rewrite settings.json — it is UNCHANGED"; exit 1
  fi
fi

echo
echo "Done. Verify: scripts/check-single-source.sh --strict"
