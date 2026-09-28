#!/usr/bin/env bash
# check-single-source.sh — refuse a second live copy of anything the plugin ships.
#
# WHY
#   Claude Code loads skills, agents and hooks from three places and does NOT
#   deduplicate across them. Measured 2026-09-27 on the machine this kit was
#   extracted from: /claim existed three times (1,268 / 1,118 / 1,052 lines, 474
#   lines differing between the first two), /finish differed by up to 654 lines
#   across its copies, the two review agents had three and four copies each, and
#   FIVE hooks were registered three times as three different versions. An agent
#   could not tell which one it had run, and neither could a reader.
#
#   The plugin is the single source. This gate is what fails when a copy comes
#   back — because a rule that depends on somebody remembering is not a rule.
#
# WHAT IT CHECKS, given a consuming repo (default: the current one)
#   1. <repo>/.claude/skills/<name>  for a name the plugin ships
#   2. <repo>/.claude/agents/<name>  for an agent the plugin ships
#   3. <repo>/.claude/hooks/<name>   for a hook the plugin registers
#   4. <repo>/.claude/settings.json  registering a hook the plugin registers
#   5. $HOME/.claude/{commands,agents,hooks} carrying any of the above
#
#   5 is reported but does NOT fail by default: a repo's CI cannot fix a
#   developer's home directory, and failing on it would make the gate unrunnable
#   in CI. `--strict` includes it, which is what the migration script uses.
#
# USAGE
#   check-single-source.sh [<repo>] [--strict] [--json]
set -uo pipefail
KIT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
REPO=""; STRICT=0; JSON=0
for a in "$@"; do
  case "$a" in
    --strict) STRICT=1 ;;
    --json)   JSON=1 ;;
    -*) echo "usage: $(basename "$0") [<repo>] [--strict] [--json]" >&2; exit 2 ;;
    *)  REPO="$a" ;;
  esac
done
[ -n "$REPO" ] || REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)

findings=0
report(){ findings=$((findings+1)); printf '  %-8s %-46s %s\n' "$1" "$2" "$3"; }

# What the plugin ships.
SKILLS=(); for d in "$KIT"/skills/*/; do [ -f "$d/SKILL.md" ] && SKILLS+=("$(basename "$d")"); done
AGENTS=(); for f in "$KIT"/agents/*.md; do [ -f "$f" ] && AGENTS+=("$(basename "$f")"); done
HOOKS=()
if [ -f "$KIT/hooks/hooks.json" ] && command -v jq >/dev/null; then
  while read -r n; do [ -n "$n" ] && HOOKS+=("$n"); done < <(
    jq -r '[.hooks[][].hooks[].command] | .[] | capture("hooks/(?<n>[A-Za-z0-9._-]+)").n' \
      "$KIT/hooks/hooks.json" 2>/dev/null | sort -u)
fi

echo "the plugin ships ${#SKILLS[@]} skills, ${#AGENTS[@]} agents, ${#HOOKS[@]} registered hooks"
echo

if [ -n "$REPO" ] && [ -d "$REPO/.claude" ]; then
  echo "IN THE REPO  $REPO"
  # A DECLARED OVERRIDE IS NOT A DUPLICATE. A project may legitimately shadow a
  # kit skill or agent — most often because the kit has not extracted that layer
  # yet, and its copy carries wiring the kit's does not. It says so in
  # harness.json under `owns`, and precedence.sh prints the shadow at session
  # start, so the exception is visible rather than silent.
  #
  # ONE list, read by this gate AND by the project's own. Two gates with two
  # hardcoded lists is the defect this whole ticket is about, one level up.
  OWN_SKILLS=""; OWN_AGENTS=""
  if [ -f "$REPO/.claude/harness.json" ] && command -v jq >/dev/null; then
    OWN_SKILLS=$(jq -r '(.owns.skills // [])[]' "$REPO/.claude/harness.json" 2>/dev/null)
    OWN_AGENTS=$(jq -r '(.owns.agents // [])[]' "$REPO/.claude/harness.json" 2>/dev/null)
  fi
  owned(){ printf '%s\n' "$2" | grep -qx "$1"; }
  declared=0
  for n in "${SKILLS[@]}"; do
    [ -f "$REPO/.claude/skills/$n/SKILL.md" ] || continue
    if owned "$n" "$OWN_SKILLS"; then
      printf '  %-8s %-46s %s\n' "declared" ".claude/skills/$n" "an override this project declares in harness.json"
      declared=$((declared+1)); continue
    fi
    report DUPLICATE ".claude/skills/$n/SKILL.md" "the plugin ships /$n — delete this copy"
  done
  for n in "${AGENTS[@]}"; do
    [ -f "$REPO/.claude/agents/$n" ] || continue
    if owned "$n" "$OWN_AGENTS"; then
      printf '  %-8s %-46s %s\n' "declared" ".claude/agents/$n" "an override this project declares in harness.json"
      declared=$((declared+1)); continue
    fi
    report DUPLICATE ".claude/agents/$n" "the plugin ships this agent — delete this copy"
  done
  for n in "${HOOKS[@]}"; do
    [ -f "$REPO/.claude/hooks/$n" ] && \
      report DUPLICATE ".claude/hooks/$n" "the plugin registers this hook — delete this copy"
  done
  if [ -f "$REPO/.claude/settings.json" ] && command -v jq >/dev/null; then
    for n in "${HOOKS[@]}"; do
      jq -r '[.hooks // {} | .[][].hooks[].command] | join("\n")' "$REPO/.claude/settings.json" 2>/dev/null \
        | grep -qF "$n" && report REGISTERED ".claude/settings.json -> $n" "fires twice; the plugin already registers it"
    done
  fi
  [ "$findings" -eq 0 ] && echo "  none"
  echo
fi

repo_findings=$findings
echo "ON THIS MACHINE  $HOME/.claude"
home_findings=0
hreport(){ home_findings=$((home_findings+1)); printf '  %-8s %-46s %s\n' "$1" "$2" "$3"; }
for n in "${SKILLS[@]}"; do
  [ -f "$HOME/.claude/commands/$n.md" ] && hreport DUPLICATE "commands/$n.md" "the plugin ships /$n"
  [ -f "$HOME/.claude/skills/$n/SKILL.md" ] && hreport DUPLICATE "skills/$n/SKILL.md" "the plugin ships /$n"
done
for n in "${AGENTS[@]}"; do
  [ -f "$HOME/.claude/agents/$n" ] && hreport DUPLICATE "agents/$n" "the plugin ships this agent"
done
for n in "${HOOKS[@]}"; do
  [ -f "$HOME/.claude/hooks/$n" ] && hreport DUPLICATE "hooks/$n" "the plugin registers this hook"
done
if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null; then
  for n in "${HOOKS[@]}"; do
    jq -r '[.hooks // {} | .[][].hooks[].command] | join("\n")' "$HOME/.claude/settings.json" 2>/dev/null \
      | grep -qF "$n" && hreport REGISTERED "settings.json -> $n" "fires twice; the plugin already registers it"
  done
fi
[ "$home_findings" -eq 0 ] && echo "  none"
echo

if [ "$JSON" -eq 1 ]; then
  printf '{"repo":%d,"home":%d,"strict":%d}\n' "$repo_findings" "$home_findings" "$STRICT"
fi

TOTAL=$repo_findings
[ "$STRICT" -eq 1 ] && TOTAL=$((repo_findings + home_findings))
if [ "$TOTAL" -gt 0 ]; then
  echo "FAIL — $TOTAL second cop$([ "$TOTAL" -eq 1 ] && echo y || echo ies) of something the plugin already provides."
  echo "Delete them (keep history in the kit's reference/), or run scripts/retire-duplicates.sh."
  exit 1
fi
if [ "$STRICT" -eq 0 ] && [ "$home_findings" -gt 0 ]; then
  echo "PASS for the repo — but this machine carries $home_findings duplicate(s) above."
  echo "Run scripts/retire-duplicates.sh to clear them. --strict fails on them too."
  exit 0
fi
echo "PASS — one copy of everything, and it is the plugin's."
