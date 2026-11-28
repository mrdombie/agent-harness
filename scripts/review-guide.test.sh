#!/usr/bin/env bash
# review-guide.test.sh — each changed file gets the nearest REVIEW.md above it; the root
# one is the fallback; a guide shows once however many files it covers; a change with no
# guide prints nothing; the guide count and size are bounded. Each rule has a plant.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/review-guide.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "FAIL     $1"; FAILED=$((FAILED + 1)); }
has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1 — [$2] not in: $(printf '%s' "$3" | head -c 300)"; fi; }
hasnt() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1 — [$2] should be absent"; else ok "$1"; fi; }

R="$T/repo"; mkdir -p "$R/apps/web/feed/deep" "$R/apps/api" "$R/pkg"
echo "ROOT-GUIDE" > "$R/REVIEW.md"
echo "WEB-GUIDE" > "$R/apps/web/REVIEW.md"
echo "FEED-GUIDE" > "$R/apps/web/feed/REVIEW.md"

out=$(printf 'apps/web/feed/deep/x.ts\n' | bash "$G" "$R")
has   "the nearest guide wins" "FEED-GUIDE" "$out"
hasnt "a farther guide is not shown" "WEB-GUIDE" "$out"
has   "the guide names the files it covers" "apps/web/feed/REVIEW.md — for apps/web/feed/deep/x.ts" "$out"

out=$(printf 'apps/api/route.ts\nREADME.md\n' | bash "$G" "$R")
has   "the root guide is the fallback" "ROOT-GUIDE" "$out"
n=$(printf '%s\n' "$out" | grep -c '^ROOT-GUIDE$')
[ "$n" = 1 ] && ok "a guide shows once for many files" || bad "root guide shown $n times"
has   "both files are listed under it" "for apps/api/route.ts, README.md" "$out"

out=$(printf 'apps/web/a.ts\napps/web/feed/b.ts\n' | bash "$G" "$R")
has "two areas give two guides (web)" "WEB-GUIDE" "$out"
has "two areas give two guides (feed)" "FEED-GUIDE" "$out"

rm "$R/REVIEW.md"
out=$(printf 'pkg/x.ts\n' | bash "$G" "$R")
[ -z "$out" ] && ok "no guide above the change prints nothing" || bad "printed: $out"
out=$(printf '' | bash "$G" "$R")
[ -z "$out" ] && ok "an empty change prints nothing" || bad "printed: $out"
out=$(printf '../../etc/passwd\n/abs/x\n' | bash "$G" "$R")
[ -z "$out" ] && ok "paths outside the repo are ignored" || bad "printed: $out"

head -c 9000 /dev/zero | tr '\0' 'z' > "$R/pkg/REVIEW.md"
out=$(printf 'pkg/x.ts\n' | REVIEW_GUIDE_BYTES=100 bash "$G" "$R")
has "a long guide is cut" "(cut at 100 bytes)" "$out"
[ "$(printf '%s' "$out" | wc -c)" -lt 400 ] && ok "the cut bounds the size" || bad "output $(printf '%s' "$out" | wc -c) bytes"

out=$(printf 'apps/web/a.ts\napps/web/feed/b.ts\npkg/c.ts\n' | REVIEW_GUIDE_MAX=2 bash "$G" "$R")
has   "the guide count is bounded" "(1 more guide(s) not shown" "$out"
hasnt "the guide past the bound is not shown" "zzzz" "$out"

# Plants: the rule deleted must turn its case red.
P="$T/plant.sh"
sed 's/\[ -f "\$root\/\$d\/REVIEW.md" \] && { printf .*$/:/' "$G" > "$P"
grep -q 'printf .%s/REVIEW.md' "$P" && bad "plant (nearest) did not land" || {
  out=$(printf 'apps/web/feed/deep/x.ts\n' | bash "$P" "$R")
  printf '%s' "$out" | grep -q FEED-GUIDE && bad "plant (nearest) still passes" || ok "plant: without the walk, no area guide"; }
sed "s/awk '!seen\[\$0\]++'/cat/" "$G" > "$P"
grep -q "seen\[" "$P" && bad "plant (dedupe) did not land" || {
  echo "ROOT-GUIDE" > "$R/REVIEW.md"
  n=$(printf 'apps/api/a.ts\nREADME.md\n' | bash "$P" "$R" | grep -c '^ROOT-GUIDE$')
  [ "$n" -gt 1 ] && ok "plant: without dedupe, a guide repeats" || bad "plant (dedupe) still passes"; }

suite_end "$FAILED"
