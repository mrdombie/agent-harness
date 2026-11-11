#!/usr/bin/env bash
# pr-proof.sh — a pull request carries its proof: the commands run, what they printed,
# how it was tested and how to undo it.
#
# WHY
#   A reviewer should read the evidence, not take the builder's word (the Claude Code
#   team's review system). The driver already proves every task
#   red then green and runs every gate by its exit code; those runs are kept on the
#   ticket's record (build-task-N.proved, self-check.gates.jsonl) and written into the
#   body here. ship refuses to open or rewrite a pull request whose body fails `check`.
#
# USAGE
#   pr-proof.sh compose --steps <run's steps dir> [--tier <tier>] [--repo <dir> --base <ref>] [--after-merge]
#       prints `## Proof` (each command, its exit and its output's tail), then the two
#       lines `How it was tested:` and `How to undo it:`. --repo/--base name a database
#       migration the branch adds in the undo line; --after-merge says the PR's
#       `## After merge` settings are undone by hand.
#   pr-proof.sh check [--tier screen] --body-file <file>|-
#       0 when the body has a `## Proof` section naming at least one command with its
#       exit, a `Screens:` line in it for a screen change, and both lines with text.
#       1 with each missing part on stdout. Lines in a fenced code block never count.
#   2 is a usage error.
set -uo pipefail

usage() { sed -n '/^# USAGE/,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }

# A line in the output that would open or close a fence is pushed past the 3-space limit.
_unfence() { sed -E 's/^([[:space:]]{0,3})([`~]{3,})/    \1\2/'; }

compose() {
  local steps="" tier="" repo="" base="" after=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --steps) steps="${2:-}"; shift 2 ;;
      --tier) tier="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      --base) base="${2:-}"; shift 2 ;;
      --after-merge) after=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$steps" ] || usage
  local f ntests=0 tfiles="" ngates=0 gnames="" nfix=0 row
  echo "## Proof"
  echo "The commands this run ran, and what they printed. The driver ran each one itself and read its exit code; none of this is the builder's own report."
  for f in "$steps"/build-task-*.proved; do
    [ -s "$f" ] || continue
    # A task that changed no code has no command: the run the driver read is its record.
    if jq -e '.answer.noCode | type == "object"' "$f" >/dev/null 2>&1; then
      echo
      echo "**$(jq -r '.title // "a task"' "$f" | tr '\n' ' ')** — no code changed ($(jq -r '.answer.noCode.reason | gsub("\\s+"; " ")' "$f")): CI run $(jq -r '.answer.noCode.run' "$f") concluded success on $(jq -r '.commits[0] // "?"' "$f" | cut -c1-8), read by the driver"
      continue
    fi
    jq -e '.proof | type == "object"' "$f" >/dev/null 2>&1 || continue
    ntests=$((ntests + 1))
    tfiles="$tfiles${tfiles:+, }$(jq -r '.proof.testFile // "?"' "$f")"
    echo
    echo "**$(jq -r '.title // "a task"' "$f" | tr '\n' ' ')** — \`$(jq -r '.proof.command' "$f")\`: exit $(jq -r '.proof.red.exit' "$f") without the change, exit $(jq -r '.proof.green.exit' "$f") with it"
    echo "- without the change, at $(jq -r '.proof.red.at // "?"' "$f"): exit $(jq -r '.proof.red.exit' "$f")"
    echo '```text'; jq -r '.proof.red.output // ""' "$f" | _unfence; echo '```'
    echo "- with the change, at $(jq -r '.proof.green.at // "?"' "$f"): exit $(jq -r '.proof.green.exit' "$f")"
    echo '```text'; jq -r '.proof.green.output // ""' "$f" | _unfence; echo '```'
  done
  if [ -s "$steps/fix.proofs.jsonl" ]; then
    nfix=$(jq -s '[.[] | select(.proof == "red-green")] | length' "$steps/fix.proofs.jsonl" 2>/dev/null || echo 0)
    if [ "${nfix:-0}" -gt 0 ]; then
      echo
      echo "**Review findings fixed**, each proved red then green:"
      jq -r 'select(.proof == "red-green") | "- \(.blockerId): \(.why)"' "$steps/fix.proofs.jsonl" 2>/dev/null
    fi
  fi
  if [ -s "$steps/self-check.gates.jsonl" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      ngates=$((ngates + 1))
      gnames="$gnames${gnames:+, }$(jq -r '.gate' <<<"$row")"
      echo
      echo "**Gate $(jq -r '.gate' <<<"$row")** — \`$(jq -r '.command' <<<"$row")\`: exit $(jq -r '.exit' <<<"$row")"
      echo '```text'; jq -r '.output // ""' <<<"$row" | _unfence; echo '```'
    done < "$steps/self-check.gates.jsonl"
  fi
  [ "$ntests$ngates" != 00 ] || { echo; echo "(none — this run kept no command it ran)"; }
  local screens=""
  if [ "$tier" = screen ]; then
    screens="screens: CI's shots of this head"
    echo
    echo "Screens: CI's shots of this head are the screen evidence: the evidence job takes them and the design check pins each one to this commit. The routes are under Evidence routes."
  fi

  local tested=""
  [ "$ntests" -eq 0 ] || tested="$ntests test$([ "$ntests" -eq 1 ] || echo s) the driver ran red without the change and green with it ($tfiles)"
  [ "${nfix:-0}" -eq 0 ] || tested="$tested${tested:+; }$nfix review finding fix$([ "$nfix" -eq 1 ] || echo es) proved the same way"
  [ "$ngates" -eq 0 ] || tested="$tested${tested:+; }$ngates gate$([ "$ngates" -eq 1 ] || echo s) green on this branch ($gnames)"
  [ -z "$screens" ] || tested="$tested${tested:+; }$screens"
  echo
  echo "How it was tested: ${tested:-nothing this run kept}."

  local undo="revert this pull request's squash commit (\`git revert <sha>\`)." mig=""
  if [ -n "$repo" ] && [ -n "$base" ]; then
    mig=$(git -C "$repo" diff --name-only --diff-filter=A "$base"...HEAD 2>/dev/null \
          | grep -E '(^|/)migrations?/|\.sql$' | head -5 | tr '\n' ' ' | sed 's/ $//; s/ /, /g')
  fi
  [ -z "$mig" ] || undo="$undo It adds a database migration ($mig): a revert leaves it applied, so undoing it also needs a migration that reverses it."
  [ "$after" -eq 0 ] || undo="$undo Undo the repository settings under After merge by hand."
  echo "How to undo it: $undo"
}

check() {
  local tier="" bf=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tier) tier="${2:-}"; shift 2 ;;
      --body-file) bf="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$bf" ] || usage
  local body
  if [ "$bf" = - ]; then body=$(cat); else body=$(cat "$bf" 2>/dev/null) || { echo "cannot read $bf"; return 2; }; fi
  printf '%s\n' "$body" | awk -v screen="$([ "$tier" = screen ] && echo 1 || echo 0)" '
    # Fenced blocks are output, never a section or a line of the body.
    /^ ? ? ?(```|~~~)/ { fence = !fence; next }
    fence { next }
    { l = $0; gsub(/\*/, "", l) }
    l ~ /^##[ \t]+/ { inproof = (l ~ /^##[ \t]+Proof[ \t]*$/); if (inproof) proof = 1; next }
    inproof && l ~ /`[^`]+`.*exit [0-9]+/ { cmd = 1 }
    inproof && l ~ /^Screens:[ \t]*[^ \t]/ { shots = 1 }
    l ~ /^How it was tested:[ \t]*[^ \t]/ { tested = 1 }
    l ~ /^How to undo it:[ \t]*[^ \t]/ { undo = 1 }
    END {
      bad = 0
      if (!proof) { print "missing: a ## Proof section"; bad = 1 }
      else if (!cmd) { print "missing: the Proof section names no command run with its exit (`<command>` … exit N)"; bad = 1 }
      if (screen && !shots) { print "missing: a Screens: line in the Proof section saying where CI'"'"'s shots are"; bad = 1 }
      if (!tested) { print "missing: a How it was tested: line with text"; bad = 1 }
      if (!undo) { print "missing: a How to undo it: line with text"; bad = 1 }
      exit bad
    }'
}

case "${1:-}" in
  compose) shift; compose "$@" ;;
  check) shift; check "$@" ;;
  *) usage ;;
esac
