#!/usr/bin/env bash
# step-push-guard.sh — the push verdict of a driver step's git shim.
#
#   bash step-push-guard.sh <real_git> <worktree> <step-stamp> <git args…>
#
# Exit 0: the push may run. Exit 1: refused, one line on stderr.
# Only a push between two repos under the temp dir, both made by this user after
# the step started, is let through: a harness test's scratch clone and bare repo.
# Everything else is the driver's to push, after the review.
set -uo pipefail

real_git=$1 wt=$2 stamp=$3; shift 3

refuse() { echo "git push refused inside a driver step: $1 (${HARNESS_DRIVER_RUN:-})" >&2; exit 1; }
DEFAULT="the driver alone pushes, after the review"

# HARNESS_STEP_TMP_ROOTS (colon-separated) replaces the temp roots; no looser than TMPDIR.
tmp_roots=()
IFS=: read -ra _roots <<<"${HARNESS_STEP_TMP_ROOTS:-${TMPDIR:-/tmp}:/tmp}"
for t in "${_roots[@]}"; do
  r=$(cd "$t" 2>/dev/null && pwd -P) && [ -n "$r" ] && tmp_roots+=("${r%/}")
done
under_tmp() { local r; for r in "${tmp_roots[@]}"; do case "$1/" in "$r"/?*) return 0 ;; esac; done; return 1; }
made_in_step() { [ -O "$1" ] && [ "$1" -nt "$stamp" ]; }

# Global options before the subcommand; -C is applied to find where git runs.
pre=() base=$PWD
while [ $# -gt 0 ]; do
  case "$1" in
    -C) [ $# -ge 2 ] || refuse "$DEFAULT"
        case "$2" in /*) base=$2 ;; *) base="$base/$2" ;; esac
        pre+=("$1" "$2"); shift 2 ;;
    -c|--git-dir|--work-tree|--namespace) [ $# -ge 2 ] || refuse "$DEFAULT"; pre+=("$1" "$2"); shift 2 ;;
    push) shift; break ;;
    -*) pre+=("$1"); shift ;;
    *) refuse "$DEFAULT" ;;
  esac
done

remote=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--repo=*) refuse "a --repo push" ;;
    --receive-pack|--receive-pack=*|--exec|--exec=*) refuse "a push with its own receive-pack" ;;
    -o|--push-option) shift 2 ;;
    --) shift; remote=${1:-}; break ;;
    -*) shift ;;
    *) remote=$1; break ;;
  esac
done
[ -n "$remote" ] || refuse "no remote named on the command line"

src=$("$real_git" ${pre[@]+"${pre[@]}"} rev-parse --show-toplevel 2>/dev/null)
[ -n "$src" ] || src=$("$real_git" ${pre[@]+"${pre[@]}"} rev-parse --absolute-git-dir 2>/dev/null)
[ -n "$src" ] && src=$(cd "$src" 2>/dev/null && pwd -P) || refuse "pushing from outside a repo"

url=$remote
case "$remote" in
  *://*|/*|./*|../*) ;;
  *:*) case "${remote%%:*}" in */*) ;; *) refuse "remote has a host ($remote)" ;; esac ;;
  *) [ -d "$base/$remote" ] || url=$("$real_git" ${pre[@]+"${pre[@]}"} remote get-url --push "$remote" 2>/dev/null) \
       || refuse "no remote named '$remote'" ;;
esac
case "$url" in
  file://localhost/*) url=${url#file://localhost} ;;
  file:///*) url=${url#file://} ;;
  *://*) refuse "remote has a host ($url)" ;;
  /*|./*|../*) ;;
  *:*) case "${url%%:*}" in */*) ;; *) refuse "remote has a host ($url)" ;; esac ;;
esac
case "$url" in /*) ;; *) url="$base/$url" ;; esac
dest=$(cd "$url" 2>/dev/null && pwd -P) || refuse "remote is not a directory ($url)"

wt_top=$(cd "$wt" 2>/dev/null && pwd -P || true)
wt_common=$("$real_git" -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ -z "$wt_common" ] || wt_common=$(cd "$wt_common" 2>/dev/null && pwd -P || true)
in_wt() { local w; for w in "$wt_top" "$wt_common"; do [ -n "$w" ] && case "$1/" in "$w"/*) return 0 ;; esac; done; return 1; }

under_tmp "$dest" || refuse "remote is not inside the temp dir ($dest)"
made_in_step "$dest" || refuse "remote was not made during this step ($dest)"
in_wt "$dest" && refuse "remote is the build worktree ($dest)"
in_wt "$src" && refuse "pushing from the build worktree ($src)"
under_tmp "$src" || refuse "pushing from outside the temp dir ($src)"
made_in_step "$src" || refuse "pushing from a repo not made during this step ($src)"
exit 0
