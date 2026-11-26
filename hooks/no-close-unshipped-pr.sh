#!/usr/bin/env bash
# Refuse `gh pr close` on an open pull request unless its close comment names a
# MERGED pull request that carries the same work ("Duplicate of #M", "superseded by #M").
#
# WHY: the owner, 2026-11-09: "get rid of that 60 minute rebuild rule its stupid" — no
# PR is closed or rebuilt for being slow to merge. PM sessions kept closing finished
# PRs to "rebuild fresh" anyway: on 2026-11-23 the finished Campaigns redesign was
# closed over one clashing number in one test, and its ticket requeued for a full
# rebuild. A red or clashing PR is fixed on its own branch (merge the base, resolve,
# push); it is closed only when its work has merged somewhere else.
#
# Owners close PRs on GitHub; this guards agent sessions only.
# NO_CLOSE_GH overrides the gh binary (tests).
set -uo pipefail
payload=$(cat)
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
[ -z "$cmd" ] && exit 0
case "$cmd" in *gh*pr*close*) ;; *) exit 0 ;; esac
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2>/dev/null
GH=${NO_CLOSE_GH:-gh}
. "$(dirname "$0")/lib/command-words.sh"

deny() {
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Words of the close comment come after -c/--comment; a body file is not read.
while IFS= read -r seg; do
  case "$seg" in *gh*pr*close*) ;; *) continue ;; esac
  command_words "$seg" && command_is gh || continue
  w=("${CMD_WORDS[@]}"); n=${#w[@]}; i=1
  [ "${w[1]:-}" = pr ] && [ "${w[2]:-}" = close ] || continue
  pr="" repo=() comment=""
  i=3
  while [ "$i" -lt "$n" ]; do
    case "${w[$i]}" in
      -R | --repo) repo=(--repo "${w[$((i + 1))]:-}"); i=$((i + 2)) ;;
      --repo=*) repo=(--repo "${w[$i]#--repo=}"); i=$((i + 1)) ;;
      -c | --comment) comment=${w[$((i + 1))]:-}; i=$((i + 2)) ;;
      --comment=*) comment=${w[$i]#--comment=}; i=$((i + 1)) ;;
      -*) i=$((i + 1)) ;;
      *) [ -z "$pr" ] && pr=${w[$i]}; i=$((i + 1)) ;;
    esac
  done
  [ -n "$pr" ] || deny "gh pr close with no pull request named — name it, so the guard can check its work shipped elsewhere."
  state=$("$GH" pr view "$pr" ${repo[@]+"${repo[@]}"} --json state,number -q '"\(.state) \(.number)"' 2>/dev/null) \
    || deny "Could not read pull request $pr to check that its work shipped elsewhere; nothing was closed."
  num=${state#* }; state=${state%% *}
  [ "$state" = OPEN ] || continue
  ok=""
  for m in $(printf '%s' "$comment" | grep -oE '#[0-9]+' | tr -d '#' | sort -u); do
    [ "$m" = "$num" ] && continue
    s=$("$GH" pr view "$m" ${repo[@]+"${repo[@]}"} --json state -q .state 2>/dev/null) || continue
    [ "$s" = MERGED ] && { ok=1; break; }
  done
  [ -n "$ok" ] || deny "Pull request #$num is open and its work has not merged anywhere else. A red or clashing PR is fixed on its own branch: merge the base in, resolve, push (owner, 2026-11-09: no PR is closed or rebuilt for being slow to merge). Close it only when its work merged in another PR, and name that PR in the close comment (\"Duplicate of #M\" / \"superseded by #M\")."
done < <(cmd_segments "$cmd")
exit 0
