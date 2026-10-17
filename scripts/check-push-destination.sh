#!/usr/bin/env bash
# Every push names where it goes, and no worktree branch tracks a trunk.
#
# A push that names no destination follows the branch's upstream: under
# push.default=upstream even `git push -u origin <branch>` goes there. A worktree
# cut with `-b <branch> origin/<trunk>` tracks that trunk, so a bare push from an
# agent worktree lands on the trunk.
#
#   check-push-destination.sh [<root>]                 scan the commands written in <root>
#   check-push-destination.sh --worktrees <repo>       list live worktree branches tracking a trunk
#
# The scan reads every non-comment line of a shell script, hook or workflow, and
# only the fenced code of a markdown file. A push is explicit when a non-option
# argument carries a `:` (src:dst, or a `:ref` delete) or it says --delete. A
# `worktree add -b` from a remote branch must say --no-track. Tests, fixtures and
# reference/ are skipped: they push scratch repos on purpose.
#
# --worktrees reads the trunk names from the project's .claude/harness.json:
# `trunks` (an array) when set, else `integrationBranch`. HARNESS_CFG_PATH points
# at another file. Exit 1 on a finding, 2 when there is nothing to read.
set -uo pipefail

CFG_REL=.claude/harness.json
trunks_from_cfg() { # <repo>
  local cfg="${HARNESS_CFG_PATH:-$1/$CFG_REL}" json=""
  if [ -f "$cfg" ]; then json=$(cat "$cfg")
  else json=$(git -C "$1" show "HEAD:$CFG_REL" 2>/dev/null); fi
  [ -n "$json" ] || return 1
  printf '%s' "$json" | jq -r '(.trunks // empty | .[]?), (if .trunks then empty else .integrationBranch // empty end)' 2>/dev/null \
    | grep -v '^[[:space:]]*$'
}

if [ "${1:-}" = --worktrees ]; then
  REPO="${2:?check-push-destination: --worktrees needs a repo}"
  git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "[check-push-destination] $REPO is not a git repo" >&2; exit 2; }
  TRUNKS=$(trunks_from_cfg "$REPO") || TRUNKS=""
  [ -n "$TRUNKS" ] || { echo "[check-push-destination] no trunks: harness.json has neither \`trunks\` nor \`integrationBranch\` (looked in ${HARNESS_CFG_PATH:-$REPO/$CFG_REL})" >&2; exit 2; }
  found=0
  while IFS= read -r line; do
    case "$line" in worktree\ *) wt=${line#worktree } ;; branch\ refs/heads/*)
      b=${line#branch refs/heads/}
      up=$(git -C "$REPO" config --get "branch.$b.merge" 2>/dev/null); up=${up#refs/heads/}
      [ -n "$up" ] && [ "$up" != "$b" ] || continue
      if printf '%s\n' "$TRUNKS" | grep -qxF "$up"; then
        echo "  $wt  branch $b tracks the trunk $up — git -C \"$wt\" branch --unset-upstream"
        found=$((found + 1))
      fi ;;
    esac
  done < <(git -C "$REPO" worktree list --porcelain)
  if [ "$found" -gt 0 ]; then
    echo "[check-push-destination] $found worktree branch(es) track a trunk ($(printf '%s' "$TRUNKS" | tr '\n' ' '| sed 's/ $//')): a bare push from them lands on it" >&2
    exit 1
  fi
  echo "[check-push-destination] OK — no worktree branch tracks a trunk ($(printf '%s' "$TRUNKS" | tr '\n' ' ' | sed 's/ $//'))"
  exit 0
fi

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -d "$ROOT" ] || { echo "[check-push-destination] no root to scan" >&2; exit 2; }
cd "$ROOT" || exit 2

# A command start, any VAR=value prefixes, then git and its -C / -c options.
CMD_START='(^|[;&|(!{`]|(^|[[:space:]])(then|do|else)[[:space:]]|\$\()[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(command[[:space:]]+)?'
GIT_OPTS='git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*'
PUSH_RE="${CMD_START}${GIT_OPTS}[[:space:]]+push([[:space:]);&|\`]|$)"
WTADD_RE="${CMD_START}${GIT_OPTS}[[:space:]]+worktree[[:space:]]+add[[:space:]].*-[bB][[:space:]].*[[:space:]]\"?[A-Za-z0-9_.-]+/"

files() {
  { find scripts hooks driver swarm briefs .husky -type f \( -name '*.sh' -o -path '.husky/*' -o -path 'driver/build-ticket' \) 2>/dev/null
    find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find skills shared agents rules .claude/skills .claude/commands -type f -name '*.md' 2>/dev/null
  } | grep -vE '(^|/)(test-[^/]*|[^/]*\.test\.sh)$|/(tests?|fixtures)/|/test-[^/]+/|^reference/|/_/' | sort -u
}

code_lines() {
  case "$1" in
    *.md) awk '/^[[:space:]]*```/{f=!f; next} f{print FNR": "$0}' "$1" ;;
    *)    awk '{print FNR": "$0}' "$1" ;;
  esac | grep -vE '^[0-9]+: [[:space:]]*#' | grep -E 'push|worktree'
}

explicit_push() {
  local rest tok
  rest=$(printf '%s' "$1" | sed -E 's/.*git([[:space:]]+-[Cc][[:space:]]+[^[:space:]]+)*[[:space:]]+push//; s/[;&|#].*//')
  printf '%s' "$rest" | grep -qE '(^|[[:space:]])(--delete|-d)([[:space:]]|$)' && return 0
  for tok in $rest; do
    case "$tok" in -*) continue ;; *:*) return 0 ;; esac
  done
  return 1
}

found=0; seen=0
while IFS= read -r f; do
  while IFS= read -r line; do
    n=${line%%: *}; body=${line#*: }
    if printf '%s' "$body" | grep -qE "$PUSH_RE"; then
      seen=$((seen + 1))
      if ! explicit_push "$body"; then
        echo "  $f:$n  push names no destination: $(printf '%s' "$body" | sed -E 's/^[[:space:]]+//' | cut -c1-120)"
        found=$((found + 1))
      fi
    fi
    if printf '%s' "$body" | grep -qE "$WTADD_RE" && ! printf '%s' "$body" | grep -q -- '--no-track'; then
      echo "  $f:$n  worktree branch would track its base: $(printf '%s' "$body" | sed -E 's/^[[:space:]]+//' | cut -c1-120)"
      found=$((found + 1))
    fi
  done < <(code_lines "$f")
done < <(files)

if [ "$found" -gt 0 ]; then
  echo "[check-push-destination] $found finding(s). Push by name: git push origin HEAD:refs/heads/<branch>;" >&2
  echo "  cut worktrees with --no-track so the branch never tracks a trunk." >&2
  exit 1
fi
# A scan that saw no push at all proves nothing about the pushes it missed.
[ "$seen" -gt 0 ] || { echo "[check-push-destination] read no push line under $ROOT — refusing to report clean" >&2; exit 2; }
echo "[check-push-destination] OK — $seen push line(s), each names its destination; every worktree branch is cut untracked"
