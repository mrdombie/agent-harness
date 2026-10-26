#!/bin/sh
# hook-skip.sh — a commit hook's one check, skipped only where the harness proved it red on
# the trunk itself, for this exact commit. Copy it into the project and wrap the check:
#
#   hook-skip.sh <check> <command> [args…]        e.g. in lint-staged:
#     "ui/*.tsx": ["sh scripts/hook-skip.sh check:catalog-drift tsx scripts/check-catalog-drift/index.ts"]
#
# The driver commits past a base-red check with three variables, and only then:
#   HARNESS_HOOK_SKIP_CHECKS  the checks proven red on the merge base, comma-joined
#   HARNESS_HOOK_SKIP_TREE    the tree being committed (git write-tree of the index)
#   HARNESS_HOOK_SKIP_HEAD    the commit it goes on top of
# <check> is skipped when it is in the list AND the index and HEAD are exactly those; any
# other check, tree or parent runs <command> as always, so a proof never reaches a later
# commit. Lint-staged passes the staged files after the arguments; they are handed on.
check="${1:?hook-skip.sh: need a check name}"; shift
[ "$#" -gt 0 ] || { echo "hook-skip.sh: need a command for $check" >&2; exit 2; }
if [ -n "${HARNESS_HOOK_SKIP_CHECKS:-}" ] && [ -n "${HARNESS_HOOK_SKIP_TREE:-}" ] && [ -n "${HARNESS_HOOK_SKIP_HEAD:-}" ]; then
  case ",$HARNESS_HOOK_SKIP_CHECKS," in
    *",$check,"*)
      tree=$(git write-tree 2>/dev/null); head=$(git rev-parse -q --verify HEAD 2>/dev/null)
      if [ -n "$tree" ] && [ "$tree" = "$HARNESS_HOOK_SKIP_TREE" ] && [ "$head" = "$HARNESS_HOOK_SKIP_HEAD" ]; then
        echo "↷ $check skipped for this commit only: proven red on the trunk itself, on no file of this change"
        exit 0
      fi ;;
  esac
fi
exec "$@"
