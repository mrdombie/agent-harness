#!/usr/bin/env bash
# Refuse a `git push` to a protected branch when the repo's hooks directory is missing.
#
# WHY: a fresh `git worktree add` inherits the shared core.hooksPath (husky's relative
# `.husky/_`), but not the gitignored directory it names. Git then runs NO pre-push
# hook and says nothing, so "the checks passed" and "there were no checks" look the
# same. A guard that is skipped when its file is missing fails open; this one checks,
# before the push, that the guard git is about to run actually exists.
#
# Refused: a push whose destination is develop, uat, main, master or live, or
# --all/--mirror, from a repo where core.hooksPath is set and git's resolved hooks dir does not exist.
# The repo is the one the push runs in: `git -C <dir>`, else the last `cd <dir>`
# earlier in the same command, else the tool call's cwd.
#
# The push is found the way the shell runs it (hooks/lib/command-words.sh): leading
# VAR=value settings and an env/command wrapper do not hide it.
#
# NOT refused: a feature-branch push, --dry-run, and any repo with no core.hooksPath.
set -uo pipefail
. "$(dirname "$0")/lib/command-words.sh"
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$cmd" ] && exit 0
# A here-string, not a pipe: under pipefail `printf | grep -q` fails on a long command.
grep -qE '(^|[[:space:]])push([[:space:]]|$)' <<<"$cmd" || exit 0
base=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$base" ] && [ -d "$base" ] || base=$PWD

PROTECTED='develop uat main master live'

deny() { # <repo dir> <branch> <hooks dir>
  jq -nc --arg d "$1" --arg b "$2" --arg h "$3" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("This push to " + $b + " would run no pre-push checks: core.hooksPath in " + $d + " resolves to " + $h + ", which does not exist, so git skips every hook without saying so. A fresh `git worktree add` does not get the gitignored hooks dir. Set the worktree up first (the harness scripts/ensure-hooks.sh <main-repo> <worktree>, or the project install that creates it), then push again.")
    }
  }'
  exit 0
}

dir=$base
while IFS= read -r seg; do
  case "$seg" in *git* | *cd*) ;; *) continue ;; esac
  command_words "$seg" || continue
  w=("${CMD_WORDS[@]}")
  if [ "${w[0]}" = cd ] && [ -n "${w[1]:-}" ]; then
    case "${w[1]}" in /*) dir=${w[1]} ;; "~"*) dir="$HOME${w[1]#\~}" ;; *) dir="$dir/${w[1]}" ;; esac
    continue
  fi
  command_is git || continue
  # git's own options before the subcommand; -C moves the repo.
  repo=$dir; i=1
  while [ "$i" -lt "${#w[@]}" ]; do
    case "${w[$i]}" in
      -C) repo=${w[$((i + 1))]:-}; case "$repo" in /*) ;; *) repo="$dir/$repo" ;; esac; i=$((i + 2)) ;;
      -c) i=$((i + 2)) ;;
      -*) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "${w[$i]:-}" = push ] || continue
  i=$((i + 1))
  args=(); all=0
  while [ "$i" -lt "${#w[@]}" ]; do
    a=${w[$i]}; i=$((i + 1))
    case "$a" in
      -n | --dry-run) continue 2 ;;
      --all | --mirror | --branches) all=1 ;;
      -o | --push-option | --repo | --receive-pack | --exec) i=$((i + 1)) ;;
      -*) ;;
      *) args+=("$a") ;;
    esac
  done

  hp=$(git -C "$repo" config core.hooksPath 2>/dev/null) || continue
  [ -n "$hp" ] || continue
  hooks=$(git -C "$repo" rev-parse --path-format=absolute --git-path hooks 2>/dev/null) || continue
  [ -d "$hooks" ] && continue

  dests=()
  if [ "${#args[@]}" -gt 1 ]; then
    for r in "${args[@]:1}"; do
      d=${r#+}; d=${d##*:}; d=${d#refs/heads/}
      [ "$d" = HEAD ] && d=$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)
      dests+=("$d")
    done
  else
    dests+=("$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null)")
  fi
  [ "$all" = 1 ] && deny "$repo" "every branch (--all/--mirror)" "$hooks"
  for d in "${dests[@]}"; do
    case " $PROTECTED " in *" $d "*) [ -n "$d" ] && deny "$repo" "$d" "$hooks" ;; esac
  done
done < <(cmd_segments "$cmd")
exit 0
