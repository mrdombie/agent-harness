#!/usr/bin/env bash
# check-gh-read.test.sh — a gh api read with its errors discarded that feeds a count,
# a loop or a test unchecked is flagged; gh_read, a checked exit, a write and a marked
# harmless read are not; the reads this lesson fixed are flagged as they were; the kit
# carries none.
# Run: bash "$0"
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "$0")" && pwd)"
C="$HERE/check-gh-read.sh"
T=$(mktemp -d); on_exit_keep_status 'rm -rf "$T"'
FAILED=0
ok()  { echo "OK       $1"; }
bad() { echo "MISMATCH $1"; FAILED=1; }

# The shapes that shipped: each read a refused call as no rows.
cat > "$T/bad.sh" <<'X'
n=$(gh api "repos/$R/issues?labels=$l&state=open&per_page=100" -q 'length' 2>/dev/null)
n=$(gh_call api "repos/$REPO_SLUG/issues?labels=$label_q&state=open&per_page=10" \
      --jq '.[0].number // empty' 2>/dev/null)
PRS=$(swarm_gh api "repos/$REPO_SLUG/pulls?state=open" --paginate 2>/dev/null | jq -cs 'add // []' 2>/dev/null)
swarm_gh api "repos/$REPO_SLUG/check-runs/$2/annotations" --jq '.[].message' 2>/dev/null | grep -iE -- "$FLAKE_RE" >/dev/null
swarm_gh api "repos/$REPO_SLUG/pulls/$pr/files?per_page=100" --paginate 2>/dev/null | jq -s 'add // []' > f.json 2>/dev/null || echo '[]' > f.json
[ -z "$t" ] || swarm_gh api "repos/$REPO_SLUG/issues/$t/comments?per_page=100" --paginate > c.json 2>/dev/null || true
n=$("$GH" api -X GET search/issues -f q="repo:$REPO_SLUG \"x\"" -q '.items[0].number // empty' 2>/dev/null)
raw=$(gh_call api "repos/$REPO_SLUG/issues/$n" 2>/dev/null) || raw=""
for c in $(ghr_api "repos/{repo}/pulls/$pr/commits?per_page=100" --paginate 2>/dev/null | jq -r '.[].sha'); do :; done
v=$(swarm_gh api "repos/$REPO_SLUG/pulls/$n" &>/dev/null)
X
cat > "$T/good.sh" <<'X'
n=$(gh_read "the open tickets" api "repos/$R/issues?labels=$l" -q 'length') || return "$GH_READ_UNKNOWN"
if ! n=$(swarm_gh api "repos/$REPO_SLUG/pulls/$n" 2>/dev/null); then echo unknown; fi
since=$(gh_call api "repos/$REPO/compare/$a...$b" 2>/dev/null) || { echo "could not compare ${a:0:7} with ${b:0:7}"; return 2; }
resp=$(gh_call api "repos/$REPO_SLUG/issues/$n/comments?per_page=100" 2>/dev/null) \
  && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$resp" \
  || { printf 'heartbeat: the comments on #%s could not be read' "$n"; return 1; }
n=$(swarm_gh api "repos/$REPO_SLUG/issues" -f title="t" --jq .number 2>/dev/null)
gh_call api -X PATCH "repos/$REPO_SLUG/issues/$n" --input - >/dev/null 2>&1 || true
swarm_gh api "repos/$SWARM_STATUS_REPO/dispatches" -f event_type=claim-changed >/dev/null 2>&1
out=$(gh_call api "repos/$REPO_SLUG/issues/$n" 2>"$err")
v=$(swarm_gh api "repos/$REPO_SLUG/pulls/$n")
# gh-read-ok: unreadable reads mergeable unknown below
v=$(swarm_gh api "repos/$REPO_SLUG/pulls/$n" 2>/dev/null)
x=$(gh api user --jq .login 2>/dev/null || whoami)   # gh-read-ok: a login for a label
# n=$(gh api "repos/x/issues" 2>/dev/null | jq length)   (a comment)
X
out=$(bash "$C" "$T/bad.sh"); rc=$?
[ "$rc" = 1 ] && ok "a failed read taken as empty fails the check" || bad "the bad file passed (rc=$rc)"
want=$(grep -cE '^[a-zA-Z[]' "$T/bad.sh")
[ "$(printf '%s\n' "$out" | grep -c .)" = "$want" ] && ok "all $want are named" || bad "named $(printf '%s\n' "$out" | grep -c .) of $want: $out"
out=$(bash "$C" "$T/good.sh"); rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && ok "gh_read, checked exits, writes, kept stderr and marked reads pass" || bad "flagged correct code: $out"

# A marker covers only its own line or the one right below it, and needs a reason.
printf '# gh-read-ok: x\n\nn=$(gh api "repos/x/issues" 2>/dev/null)\n' > "$T/far.sh"
bash "$C" "$T/far.sh" >/dev/null; [ "$?" = 1 ] && ok "a marker two lines up excuses nothing" || bad "a distant marker excused a read"
printf '# gh-read-ok:\nn=$(gh api "repos/x/issues" 2>/dev/null)\n' > "$T/bare.sh"
bash "$C" "$T/bare.sh" >/dev/null; [ "$?" = 1 ] && ok "a marker with no reason excuses nothing" || bad "a bare marker excused a read"

# The reads this lesson moved, as they stood before it: each is flagged.
ROOT="$(cd "$HERE/.." && pwd)"
if git -C "$ROOT" cat-file -e 78f6d22 2>/dev/null; then
  for f in scripts/coordinator-sheet.sh scripts/keep-fresh.sh scripts/merge-lane.sh scripts/critic-judge.sh scripts/follow-up.sh scripts/ci-evidence.sh; do
    git -C "$ROOT" show "78f6d22:$f" > "$T/before-$(basename "$f")"
  done
  out=$(bash "$C" "$T"/before-*.sh)
  for hit in 'before-coordinator-sheet.sh:99:' 'before-keep-fresh.sh:119:' 'before-merge-lane.sh:348:' 'before-critic-judge.sh:362:' \
             'before-critic-judge.sh:374:' 'before-critic-judge.sh:281:' 'before-follow-up.sh:59:' 'before-ci-evidence.sh:231:'; do
    printf '%s\n' "$out" | grep -qF "$hit" && ok "the read it fixed is flagged as it was: ${hit#before-}" || bad "not flagged before the fix: $hit"
  done
else
  echo "SKIP     the pre-fix tree is not in this clone (a shallow checkout); the fixtures above stand for it"
fi

# The kit itself.
out=$(bash "$C"); rc=$?
[ "$rc" = 0 ] && ok "the kit reads nothing from GitHub that a failure would empty" || bad "the kit: $out"

suite_end "$FAILED"
