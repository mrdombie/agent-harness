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

tmp_roots=()
for t in "${TMPDIR:-/tmp}" /tmp; do
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
[ -n "$remote" ] || refuse "$DEFAULT"

src=$("$real_git" ${pre[@]+"${pre[@]}"} rev-parse --show-toplevel 2>/dev/null)
[ -n "$src" ] || src=$("$real_git" ${pre[@]+"${pre[@]}"} rev-parse --absolute-git-dir 2>/dev/null)
[ -n "$src" ] && src=$(cd "$src" 2>/dev/null && pwd -P) || refuse "$DEFAULT"

url=$remote
case "$remote" in
  file://*|/*|./*|../*) ;;
  *) [ -d "$base/$remote" ] || url=$("$real_git" ${pre[@]+"${pre[@]}"} remote get-url --push "$remote" 2>/dev/null) || refuse "$DEFAULT" ;;
esac
case "$url" in
  file://localhost/*) url=${url#file://localhost} ;;
  file://*) url=${url#file://} ;;
  *://*) refuse "$DEFAULT" ;;
esac
case "$url" in /*) ;; *) url="$base/$url" ;; esac
dest=$(cd "$url" 2>/dev/null && pwd -P) || refuse "$DEFAULT"

wt_top=$(cd "$wt" 2>/dev/null && pwd -P || true)
wt_common=$("$real_git" -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
[ -z "$wt_common" ] || wt_common=$(cd "$wt_common" 2>/dev/null && pwd -P || true)
for p in "$src" "$dest"; do
  under_tmp "$p" && made_in_step "$p" || refuse "$DEFAULT"
  for w in "$wt_top" "$wt_common"; do
    [ -n "$w" ] || continue
    case "$p/" in "$w"/*) refuse "$DEFAULT" ;; esac
  done
done
exit 0
