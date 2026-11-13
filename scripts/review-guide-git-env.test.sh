#!/usr/bin/env bash
# review-guide-git-env.test.sh — review-guide.test.sh run from a git hook, with GIT_DIR
# pointing at a real clone, leaves that clone's identity, branches and commits alone.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "FAIL     $1"; FAILED=$((FAILED + 1)); }

D="$T/clone"; mkdir -p "$D"
git -C "$D" init -q -b main; git -C "$D" config user.email dom@real; git -C "$D" config user.name Dom
echo x > "$D/f"; git -C "$D" add -A; git -C "$D" commit -qm real
before_head=$(git -C "$D" rev-parse HEAD); before_refs=$(git -C "$D" for-each-ref --format='%(refname)')

GIT_DIR="$D/.git" GIT_WORK_TREE="$D" bash "$HERE/review-guide.test.sh" >/dev/null 2>&1

[ "$(git -C "$D" config user.email)" = dom@real ] && ok "the clone keeps its email" \
  || bad "the clone's email became $(git -C "$D" config user.email)"
[ "$(git -C "$D" rev-parse HEAD)" = "$before_head" ] && ok "the clone's HEAD is untouched" \
  || bad "the clone's HEAD moved"
[ "$(git -C "$D" for-each-ref --format='%(refname)')" = "$before_refs" ] && ok "the clone gains no branch" \
  || bad "the clone's refs are now: $(git -C "$D" for-each-ref --format='%(refname)' | tr '\n' ' ')"

suite_end "$FAILED"
