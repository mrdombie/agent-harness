#!/usr/bin/env bash
# worktree-lib.sh — sourced by the worktree sweeper and the cache pass.
#   wt_real <path> · wt_cwds_load · wt_occupant <real-wt> · wt_can_see_processes · wt_cfg <cfg> <jq-path>
# The caller's own shell chain is not an occupant: an agent cleaning up from inside its worktree is done with it.

wt_real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

wt_can_see_processes() { command -v lsof >/dev/null 2>&1; }

WT_CWDS=""
WT_SELF=""
wt_cwds_load() {
  WT_CWDS=$(lsof -a -d cwd -Fpn 2>/dev/null | awk '/^p/{p=substr($0,2)} /^n/{print p "\t" substr($0,2)}')
  local p=$$ n=0
  WT_SELF=" $$ "
  while [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] || break
    WT_SELF="$WT_SELF$p "; n=$((n+1))
  done
  # The pipeline's own children carry this pid as parent and are gone before anyone looks.
  WT_SELF="$WT_SELF${BASHPID:-} "
}

wt_occupant() { # <real-wt>
  printf '%s\n' "$WT_CWDS" | awk -F'\t' -v root="$1/" -v self="$WT_SELF" '
    index(self, " " $1 " ") { next }
    index($2 "/", root) == 1 { print $1; found = 1; exit }
    END { exit !found }'
}

wt_cfg() { # <cfg-file> <jq path>
  [ -f "$1" ] || return 0
  jq -r "$2 // empty | if type == \"array\" then .[] else . end" "$1" 2>/dev/null
}
