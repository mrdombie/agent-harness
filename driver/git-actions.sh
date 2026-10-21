#!/usr/bin/env bash
# git-actions.sh — the git steps a model's permission mode refuses, run by the driver.
#
#   driver_git_actions <ticket> <tree> <answer.json> <where>
#
# A step runs in auto permission mode, and its classifier refuses some routine git:
# `git commit --no-edit` to finish a merge, `git reset --hard`, rewriting unpushed
# commits. Each refusal parked a ticket on the owner for a mechanical step. So the
# model lists the step in its answer's `gitActions` and the driver runs it, after
# checking it is one of these, in this tree, on this branch:
#
#   commitMerge       stages the conflicted paths that carry no marker, then
#                     `git commit --no-edit` — only with a merge in progress and
#                     nothing left unmerged
#   resetTo <sha>     `git reset --keep <sha>` — only to the branch's own head on
#                     origin, or a commit on HEAD's first-parent line that is not on
#                     the trunk and still contains what origin's branch has
#   dropLocalCommits  `git reset --keep origin/<branch>` — only when every commit it
#                     drops is already on origin (same patch, `git cherry`)
#
# Each is checked just before it runs, in the order listed; the first refused stops
# the rest (1, with park_note set). The model's own permissions are never widened.

_driver_ga_refuse() { # <ticket> <where> <why>
  driver_say "✋ $2: gitActions — $3"
  driver_state_set "$1" park_note "the $2 answer asked the driver for a git step it refuses: $3"
  return 1
}

_driver_ga_merging() { git -C "$1" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; }

_driver_ga_commit_merge() { # <ticket> <tree> <where>
  local t="$1" wt="$2" w="$3" p left="" marked=""
  if ! _driver_ga_merging "$wt"; then
    driver_say "   $w: commitMerge — no merge in progress, nothing to commit"; return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ ! -f "$wt/$p" ]; then left="$left$p "; continue; fi
    if grep -q -E '^(<<<<<<<|>>>>>>>)( |$)' "$wt/$p" 2>/dev/null; then marked="$marked$p "; continue; fi
    git -C "$wt" add -- "$p" >/dev/null 2>&1 || left="$left$p "
  done <<<"$(git -C "$wt" diff --name-only --diff-filter=U 2>/dev/null)"
  [ -z "$marked" ] || { _driver_ga_refuse "$t" "$w" "commitMerge: conflict markers are still in ${marked% }"; return 1; }
  [ -z "$left" ] || { _driver_ga_refuse "$t" "$w" "commitMerge: still unmerged: ${left% }"; return 1; }
  git -C "$wt" commit -q --no-edit >/dev/null 2>&1 \
    || { _driver_ga_refuse "$t" "$w" "commitMerge: git commit --no-edit failed in $wt"; return 1; }
  driver_say "   $w: commitMerge — the driver finished the merge at $(git -C "$wt" rev-parse --short HEAD)"
}

_driver_ga_reset_to() { # <ticket> <tree> <where> <sha> <branch> <trunk>
  local t="$1" wt="$2" w="$3" want="$4" b="$5" trunk="$6" sha ob=""
  _driver_ga_merging "$wt" && { _driver_ga_refuse "$t" "$w" "resetTo: a merge is in progress"; return 1; }
  case "$want" in *[!0-9a-f]*|'') want="'$want'" ;; esac
  [ "${#want}" -ge 7 ] && [ "${#want}" -le 40 ] && sha=$(git -C "$wt" rev-parse -q --verify "$want^{commit}" 2>/dev/null) \
    || { _driver_ga_refuse "$t" "$w" "resetTo: ${want} is not a commit sha"; return 1; }
  [ -n "$b" ] && ob=$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null)
  if [ "$sha" != "$ob" ]; then
    git -C "$wt" rev-list --first-parent HEAD --not "$trunk" 2>/dev/null | grep -qx "$sha" \
      || { _driver_ga_refuse "$t" "$w" "resetTo: ${want} is not one of this branch's own commits (first-parent, not on $trunk)"; return 1; }
    [ -z "$ob" ] || git -C "$wt" merge-base --is-ancestor "$ob" "$sha" 2>/dev/null \
      || { _driver_ga_refuse "$t" "$w" "resetTo: ${want} is behind origin/$b, so it would drop pushed work"; return 1; }
  fi
  git -C "$wt" reset -q --keep "$sha" >/dev/null 2>&1 \
    || { _driver_ga_refuse "$t" "$w" "resetTo: git reset --keep $want failed (uncommitted changes in the way?)"; return 1; }
  driver_say "   $w: resetTo — the driver reset $b to $(git -C "$wt" rev-parse --short HEAD)"
}

_driver_ga_drop_local() { # <ticket> <tree> <where> <branch>
  local t="$1" wt="$2" w="$3" b="$4" ob c new=""
  _driver_ga_merging "$wt" && { _driver_ga_refuse "$t" "$w" "dropLocalCommits: a merge is in progress"; return 1; }
  ob=$(git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$b" 2>/dev/null) \
    || { _driver_ga_refuse "$t" "$w" "dropLocalCommits: origin has no $b"; return 1; }
  for c in $(git -C "$wt" rev-list --merges "$ob..HEAD" 2>/dev/null); do new="$new$(git -C "$wt" rev-parse --short "$c") "; done
  new="$new$(git -C "$wt" cherry "$ob" HEAD 2>/dev/null | sed -n 's/^+ \(.\{10\}\).*/\1/p' | tr '\n' ' ')"
  [ -z "${new// /}" ] || { _driver_ga_refuse "$t" "$w" "dropLocalCommits: not on origin, so not dropped: ${new% }"; return 1; }
  git -C "$wt" reset -q --keep "$ob" >/dev/null 2>&1 \
    || { _driver_ga_refuse "$t" "$w" "dropLocalCommits: git reset --keep origin/$b failed (uncommitted changes in the way?)"; return 1; }
  driver_say "   $w: dropLocalCommits — the driver reset $b to origin's $(git -C "$wt" rev-parse --short HEAD)"
}

driver_git_actions() { # <ticket> <tree> <answer.json> <where>
  local t="$1" wt="$2" ans="$3" w="${4:-step}" n i a sha b trunk
  n=$(jq -r '(.gitActions // []) | length' "$ans" 2>/dev/null)
  case "$n" in ''|0) return 0 ;; esac
  b=$(driver_state_get "$t" branch)
  [ -n "$b" ] || b=$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)
  trunk="origin/${INTEGRATION_BRANCH:-develop}"
  git -C "$wt" fetch -q origin "+refs/heads/${INTEGRATION_BRANCH:-develop}:refs/remotes/$trunk" 2>/dev/null || true
  [ -z "$b" ] || git -C "$wt" fetch -q origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
  i=0
  while [ "$i" -lt "$n" ]; do
    a=$(jq -r --argjson i "$i" '.gitActions[$i].action // ""' "$ans")
    sha=$(jq -r --argjson i "$i" '.gitActions[$i].sha // ""' "$ans")
    i=$((i+1))
    case "$a" in
      commitMerge)      _driver_ga_commit_merge "$t" "$wt" "$w" || return 1 ;;
      resetTo)          _driver_ga_reset_to "$t" "$wt" "$w" "$sha" "$b" "$trunk" || return 1 ;;
      dropLocalCommits) _driver_ga_drop_local "$t" "$wt" "$w" "$b" || return 1 ;;
      *)                _driver_ga_refuse "$t" "$w" "'$a' is not one of commitMerge, resetTo, dropLocalCommits"; return 1 ;;
    esac
  done
  return 0
}
