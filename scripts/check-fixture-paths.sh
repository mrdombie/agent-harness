#!/usr/bin/env bash
# check-fixture-paths.sh — a suite that runs git on a path it read back holds that path to its fixture first.
# Usage: check-fixture-paths.sh [suite ...]   (default: every suite .github/ci/shard.sh --all lists)
# `git -C ""` is the directory the suite was started from. A worktree path read back
# from state came back empty and a suite committed into, and rewired the hooks of,
# the operator's own clone. Every `VAR=$(…)` whose VAR a suite hands to `git -C`
# carries, on that line or the next, `fixture_path VAR <root>` (tests/lib/suite.sh)
# or `[ -n "$VAR" ] || suite_skip …`. A fresh `mktemp` or `cd … && pwd` is a root,
# not a read-back path, and is not judged here.
cd "$(dirname "$0")/.." || exit 2
if [ $# -gt 0 ]; then suites=("$@"); else
  suites=(); while IFS= read -r s; do suites+=("$s"); done < <(bash .github/ci/shard.sh --all)
fi
[ "${#suites[@]}" -gt 0 ] || { echo "check-fixture-paths: no suites to check"; exit 2; }
bad=0; held=0
for f in "${suites[@]}"; do
  [ -f "$f" ] || { echo "  $f: not a file"; bad=1; continue; }
  vars=$(grep -v '^[[:space:]]*#' "$f" | grep -oE 'git -C "\$\{?[A-Za-z_][A-Za-z_0-9]*' | sed -E 's/.*\$\{?//' | sort -u)
  for v in $vars; do
    while IFS=: read -r n line; do
      [ -n "$n" ] || continue
      case "$line" in *"$v=\$(mktemp"* | *"$v=\"\$(mktemp"* | *"$v=\$(cd "* | *"$v=\"\$(cd "*) continue ;; esac
      next=$(sed -n "$((n + 1))p" "$f")
      if printf '%s\n%s\n' "$line" "$next" \
        | grep -qE "fixture_path[[:space:]]+${v}[[:space:]]|\[ -n \"\\\$$v\" \] \|\| suite_skip"; then
        held=$((held + 1))
      else
        echo "  $f:$n: \$$v is read back from a command and handed to git -C, with no fixture_path $v"
        bad=1
      fi
    done < <(grep -nE "(^|[^A-Za-z_0-9])(local[[:space:]]+)?$v=\"?\\\$\\(" "$f" | grep -vE '^[0-9]+:[[:space:]]*#')
  done
done
if [ "$bad" -ne 0 ]; then
  echo "check-fixture-paths: an empty path above makes git act on the clone the suite runs from — hold it with fixture_path (tests/lib/suite.sh)"
  exit 1
fi
echo "check-fixture-paths: ${#suites[@]} suites, $held read-back paths held to their fixture before git sees them"
