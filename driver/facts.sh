#!/usr/bin/env bash
# facts.sh — filling the briefs' placeholders, and refusing when one is not filled.
#
#   driver_fact_put <ticket> <slot> <NAME> <value>
#   driver_facts_common <ticket> <slot>
#   driver_substitute <brief> <factdir> <out>   0 = every placeholder filled
#
# WHY THIS EXISTS. briefs/README.md says it plainly — "substitute all of them
# before sending … a placeholder left unfilled reaches the model literally" — and
# nothing did. Measured on the 2026-09-27 trial: the plan prompt was byte-identical
# for two different tickets (md5 a92aa3c6…), and six placeholders reached the model
# as the characters `{{TICKET}}`. Both agents noticed and said so in their notes.
# The run only produced anything at all because it was launched from inside the
# ticket's worktree and they read the number off the branch name.
#
# A MISSING FACT IS A REFUSAL, NOT AN EMPTY STRING. That is the whole design here:
# every gatherer below writes either a real value or a sentence saying there is
# none and why, and `driver_substitute` refuses when a placeholder resolves to
# nothing. An unfilled placeholder that merely looks odd in a prompt is the failure
# that cannot be seen from outside; one that stops the step can only be seen.
#
# The facts live one per file under `<state>/steps/<slot>.facts/<NAME>`, for the
# same reason the prompt does: it is what a person re-reads when the answer looks
# wrong, and a value with newlines in it survives a file where it would not survive
# an argument list.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/state.sh" || exit 1

driver_fact_dir() { printf '%s' "$(driver_state_dir "$1")/steps/$2.facts"; }

# AN EMPTY VALUE IS NOT A VALUE. `printf '%s\n' ""` writes one empty line, which a
# reader cannot tell from a fact that happens to be blank — so an empty file is
# written as ZERO bytes and driver_substitute refuses on it. Measured while building
# this: a gatherer whose jq was mis-quoted produced nothing, the brief went out
# reading "- The ticket: " and the step ran happily on it. That is F4 wearing a
# different hat, so the refusal has to cover it.
driver_fact_put() { # <ticket> <slot> <NAME> <value>
  local d; d=$(driver_fact_dir "$1" "$2"); mkdir -p "$d"
  if [ -z "$(printf '%s' "$4" | tr -d '[:space:]')" ]; then
    : > "$d/$3"
  else
    printf '%s\n' "$4" > "$d/$3"
  fi
}

# driver_substitute <brief> <factdir> <out>
#
# It builds the line up rather than rewriting it in place, so a fact whose own text
# contains `{{SOMETHING}}` — a ticket body quoting a brief, which is exactly what
# this ticket's body does — is passed through and never re-scanned. Rewriting in
# place also cannot terminate on a placeholder it has no value for.
driver_substitute() { # <brief> <factdir> <out>
  local brief="$1" dir="$2" out="$3" missfile missing
  missfile="$out.missing"
  awk -v dir="$dir" -v missfile="$missfile" '
    function load(name,   f, line, acc, got) {
      f = dir "/" name; acc = ""; got = 0
      while ((getline line < f) > 0) { acc = (got ? acc "\n" : "") line; got = 1 }
      close(f)
      if (!got) return "\001"
      return acc
    }
    {
      line = $0; built = ""
      while (match(line, /\{\{[A-Z0-9_]+\}\}/)) {
        name = substr(line, RSTART + 2, RLENGTH - 4)
        val = load(name)
        if (val == "\001") { miss[name] = 1; val = "(NOT SUBSTITUTED: " name ")" }
        built = built substr(line, 1, RSTART - 1) val
        line = substr(line, RSTART + RLENGTH)
      }
      print built line
    }
    END { n = 0; for (m in miss) { printf "%s%s", (n++ ? " " : ""), m > missfile } }
  ' "$brief" > "$out"
  missing=$(cat "$missfile" 2>/dev/null); rm -f "$missfile"
  [ -z "$missing" ] || { printf '%s' "$missing"; return 1; }
  return 0
}

# --- the gatherers ------------------------------------------------------------
# Each writes a value or a sentence saying there is none and why. None of them
# names a project: every project-specific value comes from harness.json or from
# the ticket.

_driver_fact_none() { printf '(none — %s)' "$1"; }

# The ticket, verbatim. The premise verdict, the plannable check and the surface
# question are all read off this, so it goes in whole rather than summarised.
driver_fact_ticket() { # <ticket>
  local j
  j=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json title,body,labels 2>/dev/null) || j=""
  if [ -z "$j" ]; then _driver_fact_none "#$1 could not be read from $REPO_SLUG"; return 0; fi
  # --arg, not shell-quoted interpolation. Built the other way the closing quote of
  # the jq program was eaten by the shell, jq exited 3 on a compile error, and the
  # brief went out with an empty ticket — which is the very defect this file is for.
  printf '%s\n' "$j" | jq -r --arg n "$1" \
    '"#\($n) \(.title)\n\nLabels: \([.labels[].name] | join(", "))\n\n\(.body // "(the ticket has no body)")"'
}

# The project's own facts file. It IS the answer to "this project": the kit names
# no project, so there is nothing here to compose.
driver_fact_project() {
  if [ -n "${HARNESS_CFG:-}" ] && [ -f "$HARNESS_CFG" ]; then
    jq -S . "$HARNESS_CFG" 2>/dev/null || cat "$HARNESS_CFG"
  else
    _driver_fact_none "this run resolved no harness.json"
  fi
}

# Whatever this project calls the approved design, plus anything on the branch
# filed under the ticket's own number. A design the driver cannot find is said to
# be absent rather than left as the characters {{DESIGN}}.
driver_fact_design() { # <ticket>
  local wt found law out=""
  wt=$(driver_state_get "$1" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  law=$(driver_opt law ""); [ -n "$law" ] || law=$(driver_opt design.philosophy "")
  [ -z "$law" ] || out="This project's design law: $law"
  found=$(git -C "$wt" ls-files 2>/dev/null | grep -E "(^|/)$1(/|-|_)" | head -10)
  if [ -n "$found" ]; then
    out="${out:+$out
}Filed under this ticket's number on the branch:
$(printf '%s\n' "$found" | sed 's/^/  /')"
  fi
  [ -n "$out" ] || out="$(_driver_fact_none "nothing on the branch is filed under #$1 and harness.json names no design law. The ticket body stands in for the approved design")"
  printf '%s' "$out"
}

# The programme, by its label. The state file is a consuming-repo convention and
# the brief asks for the BRIEF of it, never the whole append-only file.
# WHERE THE PROGRAMME STATE FILES ARE, for a caller that has no working tree of
# its own. `PROGRAMMES_DIR` is `${REPO_ROOT:+$REPO_ROOT/docs/programmes}` and
# REPO_ROOT is EMPTY for a bare clone or a headless spawn — so on the 2026-09-28
# trial every step was told "this project keeps no programme state directory",
# while the run's own worktree held 29 of them.
#
# The ticket's worktree first, because that is the tree this run is building in and
# the one whose state files are at the branch's version; then the shared checkout.
_driver_programmes_dir() { # [ticket]
  local d
  for d in "${PROGRAMMES_DIR:-}" \
           "$(driver_state_get "${1:-}" worktree 2>/dev/null)/docs/programmes" \
           "${MAIN_REPO:-}/docs/programmes"; do
    case "$d" in ''|/docs/programmes) continue ;; esac
    [ -d "$d" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

driver_fact_programme() { # <ticket>
  local labels p dir name brief=""
  labels=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json labels -q '[.labels[].name] | join(" ")' 2>/dev/null) || labels=""
  p=""
  for l in $labels; do
    case "$l" in "${SWARM_PROGRAMME_PREFIX:-project:}"*) p="$l"; break ;; esac
  done
  [ -n "$p" ] || { _driver_fact_none "#$1 carries no programme label"; return 0; }
  dir=$(_driver_programmes_dir "$1") || {
    printf 'Programme: %s\n%s\n' "$p" "$(_driver_fact_none "no docs/programmes directory resolves from this run's worktree or from ${MAIN_REPO:-the shared checkout}")"
    return 0; }
  # THE FILE FOR THIS PROGRAMME, not the first one on disk. `head -1` handed every
  # ticket whichever state file sorted first — 29 of them on the trial — so the one
  # fact this brief exists to carry was another programme's.
  name="${p#${SWARM_PROGRAMME_PREFIX:-project:}}"
  # BY WHAT THE FILE SAYS, NOT BY WHAT IT IS CALLED. A filename glob is a proxy and
  # a bad one: measured on the project this was written for, all 29 state files are
  # named for the EPIC (`state-10011.md`) and the programme label lives in the body
  # as `**Label:** \`project:one-desk\``. `state-*one-desk*.md` matches none of
  # them, so the fix would have shipped asserting "none of them is named for this
  # programme" on every ticket — green in a suite that invented the filename it was
  # looking for. The label is the thing; grep for it.
  brief=$(grep -l -- "$p" "$dir"/state-*.md 2>/dev/null | head -1)
  if [ -z "$brief" ]; then
    printf 'Programme: %s\n%s holds %s state file(s) and none of them names this programme, so read the ticket alone rather than another programme\x27s ledger.\n' \
      "$p" "$dir" "$(ls "$dir"/state-*.md 2>/dev/null | wc -l | tr -d ' ')"
    return 0
  fi
  # THE BRIEF, NOT THE LEDGER — when the project has something that prints one.
  # These files are append-only and grow for as long as the programme is open; a
  # step handed the whole thing designs from the programme's history rather than
  # from its own ticket. `programmes.brief` is a project command with {{FILE}} and
  # {{EPIC}} substituted. Absent is normal: the file is named instead.
  local cmd out epic
  cmd=$(driver_opt programmes.brief "")
  if [ -n "$cmd" ]; then
    epic=$(basename "$brief" .md); epic="${epic#state-}"
    cmd=$(printf '%s' "$cmd" | sed -e "s|{{FILE}}|$brief|g" -e "s|{{EPIC}}|$epic|g")
    out=$( ( cd "$(dirname "$dir")/.." 2>/dev/null || cd "${MAIN_REPO:-.}"; driver_bounded 120 "$cmd" ) 2>/dev/null )
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
      printf 'Programme: %s (from %s)\n%s\n' "$p" "$brief" "$out"
      return 0
    fi
    printf 'Programme: %s\nIts state file: %s\nThis project names a programmes.brief command and it printed nothing here, so read the brief at the top of that file yourself — the locked decisions, the open questions and what shipped recently — never the whole ledger.\n' \
      "$p" "$brief"
    return 0
  fi
  printf 'Programme: %s\nIts state file: %s\nRead the brief at the top of it — the locked decisions, the open questions and what shipped recently — never the whole ledger.\n' \
    "$p" "$brief"
}

# The premise GATHER, which decides nothing. Same shape the claim flow prints: a
# mechanical path-exists check measured 0 true positives in 25 tickets, so this
# marks each cited path present, moved or absent and the step returns the verdict.
driver_fact_premise() { # <ticket>
  local body cited wt trunk p alt out=""
  wt=$(driver_state_get "$1" worktree); [ -n "$wt" ] || wt="$MAIN_REPO"
  trunk="HEAD"
  git -C "$wt" rev-parse --verify -q "origin/$INTEGRATION_BRANCH" >/dev/null 2>&1 \
    && trunk="origin/$INTEGRATION_BRANCH"
  body=$(swarm_gh issue view "$1" --repo "$REPO_SLUG" --json body -q '.body // ""' 2>/dev/null) || body=""
  cited=$(printf '%s\n' "$body" \
    | grep -oE '[A-Za-z0-9._/-]+/[A-Za-z0-9._/-]+\.[a-z]{2,4}' | sort -u | head -8)
  if [ -z "$cited" ]; then
    printf '%s' "$(_driver_fact_none "the ticket cites no repository path, so judge the premise from its body alone")"
    return 0
  fi
  out="Read against $trunk. This gathers; the verdict is yours."
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if git -C "$wt" cat-file -e "$trunk:$p" 2>/dev/null; then
      out="$out
  present  $p"
    else
      alt=$(git -C "$wt" ls-tree -r --name-only "$trunk" 2>/dev/null | grep -F "/$(basename "$p")" | head -3)
      if [ -n "$alt" ]; then
        out="$out
  MOVED    $p -> $(printf '%s' "$alt" | tr '\n' ' ')"
      else
        out="$out
  ABSENT   $p (no same-named file anywhere on $trunk)"
      fi
    fi
  done <<EOP
$cited
EOP
  printf '%s' "$out"
}

# What is already in flight on this ticket. A resume is not a fresh build, and the
# plan brief says to read it before writing anything — so it has to be here.
driver_fact_in_flight() { # <ticket>
  local prs branches claims out=""
  prs=$(swarm_gh pr list --repo "$REPO_SLUG" --state open --limit 100 \
          --json number,headRefName,title,body \
          -q ".[] | select((.headRefName | test(\"(^|/)($BRANCH_PREFIX)?$1[-/]\")) or ((.body // \"\") | test(\"#$1\\\\b\"))) | \"  PR #\(.number) \(.headRefName) — \(.title)\"" 2>/dev/null) || prs=""
  branches=$(git ls-remote --heads origin 2>/dev/null \
               | grep -E "refs/heads/($BRANCH_PREFIX)?$1[-/]" | sed 's/^/  branch /') || branches=""
  claims=$(bash "$CL" list 2>/dev/null | sed -n '2,$p' | sed 's/^/  claim /') || claims=""
  [ -z "$prs" ]      || out="Open pull requests naming #$1:
$prs"
  [ -z "$branches" ] || out="${out:+$out
}Remote branches keyed to #$1:
$branches"
  [ -z "$claims" ]   || out="${out:+$out
}Every live claim in the system:
$claims"
  [ -n "$out" ] || out="$(_driver_fact_none "no open pull request, remote branch or live claim names #$1")"
  printf '%s' "$out"
}

# The standard a change is held to, and the screen rules. Both are project facts
# and both are optional: a backend-only project has no screen rules, and saying so
# is different from leaving the placeholder in the prompt.
# THE CODING STANDARD, AND NOTHING STANDS IN FOR IT. This used to fall back to
# `law` — the DESIGN law — so on the 2026-09-28 trial the build step was told this
# project's coding standard is docs/design/design-philosophy.md. The real one is
# docs/CODING_STANDARDS.md. A wrong document cannot be seen from inside a prompt;
# an absence can, which is the whole argument of this file.
driver_fact_standards() {
  local v; v=$(driver_opt standards "")
  [ -n "$v" ] && printf '%s' "$v" \
    || _driver_fact_none "harness.json names no standards document — set 'standards' to this project's coding standard. The design law is not one, and is given separately as the screen rules"
}

driver_fact_surface_rules() {
  local v; v=$(driver_opt design.philosophy ""); [ -n "$v" ] || v=$(driver_opt law "")
  if [ -n "$v" ]; then printf '%s' "$v"
  else _driver_fact_none "harness.json declares no design section, so this project has no screen rules"; fi
}

# driver_facts_common <ticket> <slot> — the six every step may ask for. Cheap ones
# are always written; the expensive reads are the two gh calls, and they are the
# same two the step would make anyway.
driver_facts_common() { # <ticket> <slot>
  local t="$1" s="$2"
  driver_fact_put "$t" "$s" TICKET          "$(driver_fact_ticket "$t")"
  driver_fact_put "$t" "$s" PROJECT_FACTS   "$(driver_fact_project)"
  driver_fact_put "$t" "$s" DESIGN          "$(driver_fact_design "$t")"
  driver_fact_put "$t" "$s" PROGRAMME_BRIEF "$(driver_fact_programme "$t")"
  driver_fact_put "$t" "$s" PREMISE_REPORT  "$(driver_fact_premise "$t")"
  driver_fact_put "$t" "$s" IN_FLIGHT       "$(driver_fact_in_flight "$t")"
  driver_fact_put "$t" "$s" STANDARDS       "$(driver_fact_standards)"
  driver_fact_put "$t" "$s" SURFACE_RULES   "$(driver_fact_surface_rules)"
}
