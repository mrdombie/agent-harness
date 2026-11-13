#!/usr/bin/env bash
# review-guide.test.sh — each changed file gets the nearest REVIEW.md above it, the root
# one is the fallback, a guide prints once with its files, paths outside the repo are
# skipped, no guide prints nothing, and the byte and area caps print their lines.
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
count() { printf '%s\n' "$2" | grep -cxF -- "$1"; }

R="$T/repo"; mkdir -p "$R/apps/feed/deep" "$R/apps/api"
echo "ROOT-GUIDE" > "$R/REVIEW.md"
echo "FEED-GUIDE" > "$R/apps/feed/REVIEW.md"

out=$(printf 'apps/feed/a.ts\napps/feed/b.ts\ntop.sh\n' | bash "$G" "$R")
has   "the area guide names both its files" "apps/feed/REVIEW.md — for apps/feed/a.ts, apps/feed/b.ts" "$out"
[ "$(count FEED-GUIDE "$out")" = 1 ] && ok "the area guide prints once" || bad "FEED-GUIDE printed $(count FEED-GUIDE "$out") times"
has   "the root guide covers the top-level file" "REVIEW.md — for top.sh" "$out"
[ "$(count ROOT-GUIDE "$out")" = 1 ] && ok "the root guide prints once" || bad "ROOT-GUIDE printed $(count ROOT-GUIDE "$out") times"

out=$(printf 'apps/feed/deep/x.ts\n' | bash "$G" "$R")
has   "the nearest guide wins" "FEED-GUIDE" "$out"
hasnt "the root guide does not shadow the area's" "ROOT-GUIDE" "$out"

out=$(printf 'apps/api/a.ts\napps/api/b.ts\n' | bash "$G" "$R")
has   "the root guide is the fallback" "REVIEW.md — for apps/api/a.ts, apps/api/b.ts" "$out"
[ "$(count ROOT-GUIDE "$out")" = 1 ] && ok "the fallback prints once for two files" || bad "ROOT-GUIDE printed $(count ROOT-GUIDE "$out") times"

out=$(printf '../etc/passwd\n/abs/x\napps/../REVIEW.md\n' | bash "$G" "$R")
[ -z "$out" ] && ok "'..' and absolute paths are skipped" || bad "printed: $out"

rm "$R/REVIEW.md"
out=$(printf 'apps/api/x.ts\n' | bash "$G" "$R")
[ -z "$out" ] && ok "no guide above the change prints nothing" || bad "printed: $out"
out=$(printf '' | bash "$G" "$R")
[ -z "$out" ] && ok "an empty change prints nothing" || bad "printed: $out"

head -c 5000 /dev/zero | tr '\0' 'z' > "$R/apps/api/REVIEW.md"
out=$(printf 'apps/api/x.ts\n' | REVIEW_GUIDE_BYTES=4000 bash "$G" "$R")
has "a long guide is cut" "(cut at 4000 bytes)" "$out"
[ "$(printf '%s' "$out" | tr -cd z | wc -c | tr -d ' ')" = 4000 ] && ok "the cut keeps 4000 bytes" \
  || bad "kept $(printf '%s' "$out" | tr -cd z | wc -c | tr -d ' ') bytes"

M="$T/many"; i=1; in=""
while [ "$i" -le 9 ]; do
  mkdir -p "$M/a$i"; echo "GUIDE-$i" > "$M/a$i/REVIEW.md"; in="${in}a$i/f.ts
"; i=$((i + 1)); done
out=$(printf '%s' "$in" | REVIEW_GUIDE_MAX=8 bash "$G" "$M")
has   "the area count is bounded" "(1 more guide(s) not shown" "$out"
has   "the eighth guide is shown" "GUIDE-8" "$out"
hasnt "the ninth guide is not" "GUIDE-9" "$out"

suite_end "$FAILED"
