#!/usr/bin/env bash
# A push that names no destination goes wherever the branch tracks, and an agent
# worktree cut from origin/<trunk> tracks that trunk. Real repos, a real bare
# remote, the real push lines out of the finish skill, the real worktree wrapper.
#   bash scripts/check-push-destination.test.sh
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
SUT="$HERE/check-push-destination.sh"
[ -f "$SUT" ] || { echo "missing $SUT"; exit 2; }
SB=$(mktemp -d); SB=$(cd "$SB" && pwd -P)
on_exit_keep_status 'rm -rf "$SB"'
fail=0
ok()  { echo "  ok   — $1"; }
bad() { echo "  FAIL — $1"; fail=1; }
G() { command git -c user.email=t@example.com -c user.name=tester -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }

echo "check-push-destination fixture"

echo "--- the scan: the kit's own skills and scripts ---"
if out=$(bash "$SUT" "$KIT" 2>&1); then ok "every push in the kit names its destination"
else bad "the kit carries an unnamed push or a tracking worktree:"; printf '%s\n' "$out" | sed 's/^/       /'; fi

P="$SB/plant"; mkdir -p "$P/scripts" "$P/skills/x" "$P/driver"
cat > "$P/scripts/a.sh" <<'SH'
#!/bin/sh
git push -u origin "$BRANCH"
X=1 git -c a=b push
git -C "$wt" push -u origin "$branch" > "$f" 2>&1 || rc=$?
ok=$(git push)
SH
printf '```bash\ngit worktree add "$WT" -b "$B" origin/develop\n```\n' > "$P/skills/x/SKILL.md"
printf 'git -C "$R" worktree add -q -B "$B" "$WT" upstream/main\n' > "$P/driver/w.sh"
out=$(bash "$SUT" "$P" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "a finding exits 1" || bad "a finding exited $rc"
for want in "a.sh:2  push names no destination" "a.sh:3  push names no destination" \
            "a.sh:4  push names no destination" "a.sh:5  push names no destination" \
            "SKILL.md:2  worktree branch would track" "w.sh:1  worktree branch would track"; do
  case "$out" in *"$want"*) ok "found: $want" ;; *) bad "missed: $want — $out" ;; esac
done

cat > "$P/scripts/a.sh" <<'SH'
#!/bin/sh
git push -u origin "HEAD:refs/heads/$BRANCH"
# git push
git -C "$wt" push -u origin "refs/heads/$branch:refs/heads/$branch"
git push origin --delete "$BRANCH"
git push -q "$REMOTE" ":refs/claims/$n"
git push origin "HEAD:refs/heads/$(git branch --show-current)"
echo "then git push it"
SH
printf '```bash\ngit worktree add --no-track "$WT" -b "$B" origin/develop\ngit worktree add -q --detach "$WT" "$SHA"\n```\ngit push in prose\n' > "$P/skills/x/SKILL.md"
printf 'git -C "$R" worktree add -q "$WT" -b "$B" "$sha"\n' > "$P/driver/w.sh"
mkdir -p "$P/scripts/fixtures"; printf 'git push\n' > "$P/scripts/fixtures/f.sh"; printf 'git push\n' > "$P/scripts/z.test.sh"
out=$(bash "$SUT" "$P" 2>&1) && ok "named pushes, deletes, comments, prose, tests, --no-track and sha bases pass" \
  || bad "the scan flags a correct line: $out"

mkdir -p "$SB/empty/scripts"; printf 'echo hi\n' > "$SB/empty/scripts/a.sh"
bash "$SUT" "$SB/empty" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a tree with no push line in it is not reported clean" || bad "a scan that read no push exited $rc"

# --- a worktree the way an agent gets one: tracking develop, push.default=upstream
G init -q --bare "$SB/remote.git"
G init -q "$SB/main"; G -C "$SB/main" remote add origin "$SB/remote.git"
G -C "$SB/main" commit -q --allow-empty -m init
G -C "$SB/main" push -q origin HEAD:refs/heads/develop HEAD:refs/heads/uat HEAD:refs/heads/main
G -C "$SB/main" fetch -q origin
G -C "$SB/main" config push.default upstream
G -C "$SB/main" config core.hooksPath /dev/null
remote_sha() { G -C "$SB/remote.git" rev-parse -q --verify "refs/heads/$1" 2>/dev/null; }
DEV0=$(remote_sha develop)
k=0
plant() { # a branch cut from origin/develop the default way: it tracks develop
  k=$((k + 1)); WT="$SB/wt-$k"; BRANCH="tkt-$k/fixture"
  G -C "$SB/main" -c branch.autoSetupMerge=true worktree add -q -b "$BRANCH" "$WT" origin/develop
  G -C "$WT" commit -q --allow-empty -m "work $k"
}

echo "--- the finish skill's own push lines, from a worktree that tracks develop ---"
PUSHES=$(awk '/^[[:space:]]*```/{f=!f; next} f' "$KIT/skills/finish/SKILL.md" | grep -E '^[[:space:]]*git push' | sed -E 's/^[[:space:]]+//')
[ "$(printf '%s\n' "$PUSHES" | grep -c .)" -ge 2 ] && ok "read $(printf '%s\n' "$PUSHES" | grep -c .) push lines out of the finish skill" \
  || bad "found $(printf '%s\n' "$PUSHES" | grep -c .) push lines in the finish skill, expected at least 2 — the test reads nothing"
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  plant
  # `git pull --ff-only origin "$BRANCH"` precedes one of them; it has nothing to pull here.
  ( cd "$WT" && git() { G "$@"; } && eval "$cmd" ) >/dev/null 2>&1
  if [ "$(remote_sha develop)" != "$DEV0" ]; then bad "finish \`$cmd\` moved develop"
  elif [ "$(remote_sha "$BRANCH")" != "$(G -C "$WT" rev-parse HEAD)" ]; then bad "finish \`$cmd\` did not land on $BRANCH"
  else ok "finish \`$cmd\` lands on its own branch, develop untouched"; fi
  G -C "$SB/remote.git" update-ref refs/heads/develop "$DEV0"
done <<< "$PUSHES"

echo "--- worktree-sparse.sh cuts a branch that tracks nothing ---"
printf '{"worktree":{}}\n' > "$SB/off.json"
printf '{"worktree":{"sparseExclude":["docs"]}}\n' > "$SB/on.json"
for mode in off on; do
  WT="$SB/wts-$mode"
  HARNESS_CFG_PATH="$SB/$mode.json" bash "$HERE/worktree-sparse.sh" add "$SB/main" "$WT" -b "sparse-$mode" origin/develop >/dev/null 2>&1
  up=$(G -C "$WT" config --get "branch.sparse-$mode.merge" 2>/dev/null)
  [ -d "$WT" ] && [ -z "$up" ] && ok "sparse $mode: -b from origin/develop has no upstream" || bad "sparse $mode: the branch tracks '${up:-?}' (worktree made: $([ -d "$WT" ] && echo yes || echo no))"
done
WT="$SB/wts-track"
HARNESS_CFG_PATH="$SB/off.json" bash "$HERE/worktree-sparse.sh" add "$SB/main" "$WT" --track -b sparse-track origin/develop >/dev/null 2>&1
[ "$(G -C "$WT" config --get branch.sparse-track.merge 2>/dev/null)" = refs/heads/develop ] \
  && ok "an explicit --track is left alone" || bad "an explicit --track was overridden"

echo "--- --worktrees: live branches that track a trunk, trunks read from harness.json ---"
R="$SB/main"
G -C "$R" push -q origin HEAD:refs/heads/feature
G -C "$R" fetch -q origin
G -C "$R" -c branch.autoSetupMerge=true worktree add -q -b on-uat "$SB/l-uat" origin/uat
G -C "$R" -c branch.autoSetupMerge=true worktree add -q -b on-feature "$SB/l-feature" origin/feature
G -C "$R" worktree add -q --no-track -b untracked "$SB/l-none" origin/develop
for w in "$SB"/wt-* "$SB/wts-track"; do G -C "$R" worktree remove --force "$w" >/dev/null 2>&1; done
printf '{"integrationBranch":"develop","trunks":["develop","uat","main"]}\n' > "$SB/trunks.json"
out=$(HARNESS_CFG_PATH="$SB/trunks.json" bash "$SUT" --worktrees "$R" 2>&1); rc=$?
[ "$rc" -eq 1 ] && ok "a branch tracking uat fails the check" || bad "exit $rc for a branch tracking uat: $out"
case "$out" in *"branch on-uat tracks the trunk uat"*) ok "and names it" ;; *) bad "on-uat not named: $out" ;; esac
case "$out" in *on-feature*|*untracked*) bad "a branch tracking a feature, or nothing, was flagged: $out" ;; *) ok "a feature upstream and --no-track are not flagged" ;; esac
printf '{"integrationBranch":"develop"}\n' > "$SB/integ.json"
out=$(HARNESS_CFG_PATH="$SB/integ.json" bash "$SUT" --worktrees "$R" 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "without \`trunks\`, the trunk is integrationBranch alone (uat is not one)" || bad "integrationBranch-only config flagged: $out"
G -C "$R" branch -q --set-upstream-to=origin/develop untracked
out=$(HARNESS_CFG_PATH="$SB/integ.json" bash "$SUT" --worktrees "$R" 2>&1); rc=$?
[ "$rc" -eq 1 ] && case "$out" in *"untracked tracks the trunk develop"*) true ;; *) false ;; esac \
  && ok "and a branch tracking integrationBranch is flagged" || bad "a branch tracking develop got through: $out"
printf '{"repo":"o/r"}\n' > "$SB/none.json"
HARNESS_CFG_PATH="$SB/none.json" bash "$SUT" --worktrees "$R" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "a config naming no trunk is refused, not reported clean" || bad "no trunk config exited $rc"

echo
suite_end "$fail"
