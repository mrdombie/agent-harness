#!/usr/bin/env bash
# Plant tests for push-needs-its-hooks.sh. Exit 1 on any mismatch.
#
# The scratch repo is the real failure: core.hooksPath is the relative `.husky/_`,
# present in the main clone and absent from a fresh `git worktree add`. The control
# proves the hole exists (git itself pushes from the worktree with no hook run);
# the cases prove the write-time hook refuses that push by name.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/lib/suite.sh" || exit 1
for v in $(env | sed -n 's/^\(GIT_[A-Z_]*\)=.*/\1/p'); do unset "$v"; done
H="$(cd "$(dirname "$0")" && pwd)/push-needs-its-hooks.sh"; fail=0
S=$(mktemp -d); on_exit_keep_status 'rm -rf "$S"'
export HOME="$S/home"; mkdir -p "$HOME"
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main

git init -q --bare "$S/remote.git"
git init -q "$S/main"
( cd "$S/main" && echo x > f && git add f && git commit -qm init \
  && git remote add origin "$S/remote.git" && git push -q origin main 2>/dev/null \
  && mkdir -p .husky/_ && printf '#!/bin/sh\necho "pre-push ran" >&2\nexit 1\n' > .husky/_/pre-push \
  && chmod +x .husky/_/pre-push && echo '.husky/_' > .git/info/exclude \
  && git config core.hooksPath .husky/_ && git worktree add -q -b wt "$S/wt" main )

# Control: the hole is real. The main clone runs its hook (refused); the worktree runs none.
if git -C "$S/main" push -q origin HEAD:uat 2>/dev/null; then
  echo "MISMATCH control: the main clone's pre-push did not run"; fail=1
else echo "OK       control: the main clone's pre-push runs and refuses"; fi
if git -C "$S/wt" push -q origin HEAD:uat 2>/dev/null; then
  echo "OK       control: the fresh worktree pushes with no hook run (the hole)"
  git -C "$S/main" push -q origin --delete uat --no-verify 2>/dev/null
else echo "MISMATCH control: the fresh worktree's push was refused by git"; fail=1; fi

# <want> <cwd> <command>
t(){ want=$1; dir=$2; shift 2
  out=$(jq -nc --arg c "$1" --arg d "$dir" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}' | (cd "$dir" && bash "$H"))
  r=allow; [ -n "$out" ] && r=deny
  if [ "$r" = deny ] && ! printf '%s' "$out" | grep -q 'core.hooksPath'; then r="deny-unnamed"; fi
  mark=OK; [ "$r" = "$want" ] || { mark=MISMATCH; fail=1; }
  printf '%-8s want=%-5s got=%-5s [%s] %s\n' "$mark" "$want" "$r" "$(basename "$dir")" "$1"; }

t deny  "$S/wt"   'git push origin HEAD:uat'
t deny  "$S/wt"   'git push origin HEAD:refs/heads/develop'
t deny  "$S/wt"   'git push -f origin +HEAD:main'
t deny  "$S/wt"   'git push origin live'
t deny  "$S/wt"   'git push --all origin'
t deny  "$S/main" "git -C $S/wt push origin HEAD:uat"
t deny  "$S/main" "cd $S/wt && git push origin HEAD:uat"
t deny  "$S/main" "git fetch -q; cd $S/wt && git push -u origin HEAD:develop"
t allow "$S/wt"   'git push origin HEAD:feature/x'
t allow "$S/wt"   'git push -u origin wt'
t allow "$S/wt"   'git push --dry-run origin HEAD:uat'
t allow "$S/main" 'git push origin HEAD:uat'
t allow "$S/main" "cd $S/wt && git status && cd $S/main && git push origin HEAD:uat"
t allow "$S/wt"   'git status'

# The command the shell runs, not the first word typed: leading VAR=value settings,
# an `env` wrapper and a path to git are the same push.
t deny  "$S/wt"   'ALLOW_TRUNK_PUSH=uat git push origin HEAD:refs/heads/uat'
t deny  "$S/wt"   'A=1 B="two words" git push origin HEAD:develop'
t deny  "$S/wt"   'env ALLOW_TRUNK_PUSH=uat git push origin HEAD:uat'
t deny  "$S/wt"   'env -u GIT_DIR X=1 git push origin HEAD:main'
t deny  "$S/wt"   'command /usr/bin/git push origin HEAD:uat'
t deny  "$S/main" "cd $S/wt && ALLOW_TRUNK_PUSH=uat git push origin HEAD:uat"
t deny  "$S/main" "ALLOW_TRUNK_PUSH=uat git -C $S/wt push origin HEAD:uat"
t allow "$S/wt"   'ALLOW_TRUNK_PUSH=uat git push origin HEAD:feature/x'
# A long command is judged whole: a pipe into grep -q under pipefail once exited early.
long=$(i=0; while [ "$i" -lt 2000 ]; do echo "echo padding-padding-padding-padding-$i"; i=$((i + 1)); done)
t deny  "$S/wt"   "git push origin HEAD:uat
$long"
t allow "$S/wt"   'env X=1 git push --dry-run origin HEAD:uat'
t allow "$S/wt"   'X=1 echo git push origin HEAD:uat'
t allow "$S/wt"   'echo "X=1 git push origin HEAD:uat"'
t allow "$S/wt"   'echo "git push origin HEAD:uat"'

# A worktree on a protected branch pushing with no refspec pushes that branch.
git -C "$S/main" worktree add -q "$S/wt-develop" -b develop main
t deny  "$S/wt-develop" 'git push'
t deny  "$S/wt-develop" 'git push origin'

# Once the worktree has its hooks, the push is allowed again.
mkdir -p "$S/wt/.husky/_"
t allow "$S/wt"   'git push origin HEAD:uat'

# A repo with no core.hooksPath is not this hook's business.
git init -q "$S/plain"
t allow "$S/plain" 'git push origin HEAD:main'

suite_end "$fail"
