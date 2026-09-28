#!/usr/bin/env bash
# The kit's acceptance test: nothing it ships names the project it was extracted
# from. README.md is the one file allowed to tell that story, so it is also where
# the names live: the `origin-names:` line. This file carries none of them.
#
# Reported WITH a control. The first run of this grep on the empty skeleton
# returned 0 because there were no files, not because they were clean — a zero
# from a strictness probe means clean, suppressed, or never ran.
#
# TWO PROBES, because "contains the project's name" is a NARROWER question than
# "is specific to that project", and the gap let six identifiers through
# (2026-09-23). A script name like `check:deploy-trigger` belongs to exactly one
# project and contains none of that project's names, so probe 1 passed it and the
# kit shipped instructions that run a command no other project has. A missing
# script is silent: `npm run <missing>` prints nothing and exits 1,
# which reads like a gate failure rather than a missing script — so this lands on
# a new project as a mystery red, not as a clear "not configured".
set -u
cd "$(dirname "$0")/.." || exit 1

# The files the kit SHIPS. README.md tells the origin story and is allowed the
# names; reference/ holds the copies this plugin replaced, kept verbatim for
# history and loaded by nothing — de-projecting an archive would make it a worse
# record and a better-looking gate, which is the wrong trade.
shipped() { git ls-files | grep -vE '^README\.md$|^reference/'; }

RC=0

# --- probe 1: the origin project's names -------------------------------------
NAMES="${HARNESS_ORIGIN_NAMES:-$(sed -n 's/^origin-names: *//p' README.md | head -1)}"
[ -n "$NAMES" ] || { echo "no origin-names: line in README.md and HARNESS_ORIGIN_NAMES unset — nothing to probe for"; exit 2; }
control=$(shipped | xargs grep -lE 'harness' 2>/dev/null | wc -l | tr -d ' ')
hits=$(shipped | xargs grep -niE "$NAMES" 2>/dev/null)
n=$(printf '%s' "$hits" | grep -c . )
printf 'control, probe can see files : %s match "harness"\n' "$control"
printf 'names the origin project     : %s (want 0)\n' "$n"
[ "$control" -gt 0 ] || { echo "probe saw no files — refusing to report clean"; exit 2; }
[ "$n" -eq 0 ] || { printf '%s\n' "$hits"; RC=1; }

# --- probe 2: project-specific build identifiers -----------------------------
# The kit may invoke only the npm scripts every project is assumed to have.
# Anything else is a fact about ONE project and belongs in harness.json, read at
# run time. A ratchet, not a wall: today's leaks are recorded in BASELINE and may
# only shrink, so the kit cannot acquire new ones while these are being removed.
GENERIC='lint|typecheck|test|build|dev'
BASELINE=scripts/project-agnostic-baseline.txt

# A SELF-TEST'S CASE DATA IS NOT AN INSTRUCTION. Probe 2 measures `npm run <id>`
# occurrences as a stand-in for "the kit invokes a script only one project has",
# and the two are not the same thing inside a *.test.sh: the strings there are
# INPUTS a judge is fed, never commands a consuming project runs. Excluding them
# makes the measurement match the claim. Probe 1 above still reads every test
# file, because a test may not name the origin project either — and the
# fixture's own "a new project-specific script fails the guard" case plants its
# leak in a NON-test file, so this narrowing cannot hide a real one.
current=$(shipped | grep -vE '\.test\.sh$' \
  | xargs grep -oE 'npm run (-s )?[-a-z:0-9]+' 2>/dev/null \
  | GENERIC="$GENERIC" perl -ne '
      # split on the FIRST colon only: the identifiers themselves contain colons
      next unless m{^([^:]+):npm run (?:-s )?(.+)$};
      my ($f, $id) = ($1, $2);
      next if $id =~ /^($ENV{GENERIC})$/;
      print "$f -> $id\n";
    ' | sort -u)

[ -f "$BASELINE" ] || : > "$BASELINE"
known=$(grep -vE '^\s*(#|$)' "$BASELINE" | sort -u)

new=$(comm -23 <(printf '%s\n' "$current" | sed '/^$/d') <(printf '%s\n' "$known" | sed '/^$/d'))
gone=$(comm -13 <(printf '%s\n' "$current" | sed '/^$/d') <(printf '%s\n' "$known" | sed '/^$/d'))

cur_n=$(printf '%s' "$current" | grep -c .)
new_n=$(printf '%s' "$new" | grep -c .)
gone_n=$(printf '%s' "$gone" | grep -c .)

printf 'project-specific npm scripts : %s (baseline %s, want 0)\n' "$cur_n" "$(printf '%s' "$known" | grep -c .)"

if [ "$new_n" -gt 0 ]; then
  echo "NEW project-specific identifiers — these must come from harness.json, not the kit:"
  printf '%s\n' "$new" | sed 's/^/  /'
  RC=1
fi
if [ "$gone_n" -gt 0 ]; then
  echo "BASELINE is stale — these no longer appear; delete the lines from $BASELINE:"
  printf '%s\n' "$gone" | sed 's/^/  /'
  RC=1
fi

exit "$RC"
