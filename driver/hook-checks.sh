#!/usr/bin/env bash
# hook-checks.sh — whatever a builder's local hooks enforce, the base-health check enforces
# too, or the base goes red where only builders see it. Sourced after driver-env.sh.
#
#   driver_hook_checks <tree> [rev]   every check the commit and push hooks run, one a line:
#       harness.json gates.hookChecks (a list of package scripts or gates.checkCommand
#       names; false for none), else read from the project itself — the pre-commit and
#       pre-push hooks' `npm|pnpm|yarn run <script>` lines, and for a hook that runs
#       lint-staged, every lint-staged command that is, or runs, a package script. With
#       <rev>, the project's files are read from that commit instead of the tree.
#   driver_hook_base_red <ticket> <tree> <question>   0 when a step's question is about a
#       hook red and the driver read whose it is; sets HOOK_BR_VERDICT base|own,
#       HOOK_BR_CHECKS and HOOK_BR_FILES (comma-joined) and HOOK_BR_WHY. 1: no verdict.
#
# A HOOK RED ON FILES THE TRUNK BROUGHT is the trunk's (base): the question names a hook,
# a check and a file; no file it names is one this ticket changed, committed or not; at
# least one is on the trunk commit the branch merged; and every check it names, run there
# alone, is red. One named file of the ticket's own, or one check green there, is its own
# and blocks. Anything unread (no merge base, a check that could not run) is no verdict.
[ -n "${DRIVER_DIR:-}" ] || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/driver-env.sh" || exit 1
declare -F driver_branch_files >/dev/null || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/format.sh" || exit 1
declare -F driver_base_check >/dev/null || . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/base-red.sh" || exit 1

# _driver_hook_read <tree> <rev> <path> — a file of the tree, or of commit <rev> when given.
_driver_hook_read() {
  if [ -n "$2" ]; then git -C "$1" show "$2:$3" 2>/dev/null; else cat "$1/$3" 2>/dev/null; fi
}

# _driver_hook_text <tree> <rev> <hook> — what git runs for <hook>: core.hooksPath's file,
# husky's, then the git dir's own (that last one is never in a commit).
_driver_hook_text() {
  local wt="$1" rev="$2" h="$3" p f
  p=$(git -C "$wt" config core.hooksPath 2>/dev/null)
  for f in ${p:+"${p%/}/$h"} ".husky/$h"; do
    case "$f" in /*) cat "$f" 2>/dev/null ;; *) _driver_hook_read "$wt" "$rev" "$f" ;; esac
  done
  f=$(git -C "$wt" rev-parse --path-format=absolute --git-path "hooks/$h" 2>/dev/null) && cat "$f" 2>/dev/null
  return 0
}

driver_hook_checks() { # <tree> [rev]
  local wt="$1" rev="${2:-}" cfg="${HARNESS_CFG:-}" ty f text cmds pkg
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    ty=$(jq -r '.gates.hookChecks | type' "$cfg" 2>/dev/null)
    case "$ty" in
      boolean) return 0 ;;
      array) jq -r '.gates.hookChecks[] | strings | select(length > 0)' "$cfg" 2>/dev/null | awk '!seen[$0]++'; return 0 ;;
    esac
  fi
  pkg=$(_driver_hook_read "$wt" "$rev" package.json) && [ -n "$pkg" ] || return 0
  text=$({ _driver_hook_text "$wt" "$rev" pre-commit; _driver_hook_text "$wt" "$rev" pre-push; } | grep -v '^[[:space:]]*#')
  cmds="$text"
  # lint-staged's commands: package.json's block, and .lintstagedrc(.json).
  if printf '%s' "$text" | grep -q 'lint-staged'; then
    cmds="$cmds
$(printf '%s' "$pkg" | jq -r '.["lint-staged"] // empty | objects | .[] | if type == "array" then .[] else . end | strings' 2>/dev/null)"
    for f in .lintstagedrc.json .lintstagedrc; do
      cmds="$cmds
$(_driver_hook_read "$wt" "$rev" "$f" | jq -r 'objects | .[] | if type == "array" then .[] else . end | strings' 2>/dev/null)"
    done
  fi
  # A command that names a script runs it; a command that IS a script's body (plus args) is it.
  printf '%s\n' "$cmds" | jq -Rr --argjson p "$pkg" '
    ($p.scripts // {}) as $s
    | (capture("\\b(npm|pnpm|yarn)\\s+(run\\s+)?((-[-A-Za-z]+)\\s+)*(?<n>[A-Za-z0-9][A-Za-z0-9:_.-]*)").n // null) as $n
    | (gsub("^\\s+|\\s+$"; "") | sub("\\s+--$"; "")) as $c
    | if $n != null and ($s | has($n)) then $n
      else ($s | to_entries[] | (.value | strings) as $v | select($v != "" and ($c == $v or ($c | startswith($v + " ")))) | .key)
      end' 2>/dev/null | awk 'NF && !seen[$0]++'
}

# _driver_hook_own_files <tree> — what this ticket changed: its commits since the trunk,
# and whatever is staged, unstaged or new in the tree (a commit the hook refused).
_driver_hook_own_files() {
  { driver_branch_files "$1" 2>/dev/null
    git -C "$1" diff --name-only HEAD 2>/dev/null
    git -C "$1" diff --name-only --cached 2>/dev/null
    git -C "$1" ls-files --others --exclude-standard 2>/dev/null
  } | awk 'NF && !seen[$0]++'
}

# _driver_hook_in <list> <path> — 0 when <path> is a line of <list>, or the end of one.
_driver_hook_in() {
  printf '%s\n' "$1" | awk -v f="$2" '$0 == f || (length($0) > length(f) && substr($0, length($0) - length(f)) == "/" f) { h = 1 } END { exit !h }'
}

driver_hook_base_red() {
  local t="$1" wt="$2" q="$3" scripts known c checks="" files="" f own base sha s7 v red="" onbase=0
  HOOK_BR_VERDICT=""; HOOK_BR_CHECKS=""; HOOK_BR_FILES=""; HOOK_BR_WHY=""
  [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$q" ] || return 1
  printf '%s' "$q" | grep -qiE 'pre-?commit|pre-?push|hook|lint-staged|husky' || return 1
  # A check is a hook's own, or a package script with a namespace (check:x): a bare `test`
  # or `lint` in the words is prose far more often than the check that failed.
  scripts=""; [ -f "$wt/package.json" ] && scripts=$(jq -r '(.scripts // {}) | keys[] | select(contains(":"))' "$wt/package.json" 2>/dev/null)
  known=$(printf '%s\n%s\n' "$(driver_hook_checks "$wt")" "$scripts" | awk 'NF && !seen[$0]++')
  for c in $(printf '%s' "$q" | grep -oE '[A-Za-z0-9][A-Za-z0-9:_.-]*[A-Za-z0-9]' | awk '!seen[$0]++'); do
    printf '%s\n' "$known" | grep -qxF -- "$c" && checks="$checks${checks:+,}$c"
  done
  [ -n "$checks" ] || return 1
  sha=$(driver_base_red_sha "$wt") || return 1
  s7=$(printf '%s' "$sha" | cut -c1-7)
  own=$(_driver_hook_own_files "$wt")
  base=$(git -C "$wt" ls-tree -r --name-only "$sha" 2>/dev/null)
  for f in $(printf '%s' "$q" | grep -oE '[A-Za-z0-9_@+./-]*[A-Za-z0-9_@+-]\.[A-Za-z0-9]{1,8}' | sed 's#^\./##' | awk '!seen[$0]++'); do
    if _driver_hook_in "$own" "$f"; then
      HOOK_BR_VERDICT=own; HOOK_BR_CHECKS="$checks"; HOOK_BR_FILES="$f"
      HOOK_BR_WHY="$f is a file this ticket changed"; return 0
    fi
    _driver_hook_in "$base" "$f" || continue
    onbase=1; files="$files${files:+,}$f"
  done
  [ "$onbase" = 1 ] || return 1
  for c in ${checks//,/ }; do
    v=$(driver_base_check "$wt" "$sha" "$c")
    case "$v" in
      red) red="$red${red:+,}$c" ;;
      green) HOOK_BR_VERDICT=own; HOOK_BR_CHECKS="$checks"; HOOK_BR_FILES="$files"
             HOOK_BR_WHY="$c is green on $INTEGRATION_BRANCH@$s7, so this ticket's own"; return 0 ;;
      *) HOOK_BR_WHY="$c could not be run on $INTEGRATION_BRANCH@$s7"; return 1 ;;
    esac
  done
  HOOK_BR_VERDICT=base; HOOK_BR_CHECKS="$red"; HOOK_BR_FILES="$files"; DRIVER_BASE_RED_SHA="$sha"
  HOOK_BR_WHY="${red//,/, } red on $INTEGRATION_BRANCH@$s7 itself, on ${files//,/, }, none of them this ticket's"
  return 0
}
