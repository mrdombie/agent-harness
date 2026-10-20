#!/usr/bin/env bash
# evidence-gaps.sh — the evidence a pull request still owes, as the judge and the repairs read it.
#
#   evidence-gaps.sh coverage <repo> <base> <head> <key> [<body-file>]
#       the changed UI files no evidence route or capture-plan step renders, one gap a
#       line (kind \t file \t routes \t text). The plan is <evidence.dir>/<key>/plan.json,
#       <key> as CI files it (scripts/evidence-plan.sh: a prefixed branch's ticket, else the PR)
#       when the change adds or edits it (it then replaces the routes, as CI reads it),
#       else the body's `## Evidence routes`. Exit 1 on a gap, 0 on none, 2 unreadable.
#   evidence-gaps.sh routes <repo> <base> <head>
#       the routes the changed UI renders on, one a line (at most 8, no dynamic segment)
#   evidence-gaps.sh judge <pr> <head> <key> <body-file>
#       coverage of an open PR from the main clone: its head and the trunk fetched first.
#       Prints nothing when the PR cannot be read — the critic still judges the shots.
#   evidence-gaps.sh tasks <pr> [<repo> <base> <head> <key> <body-file>]
#       every open evidence task: the judge's evidence-class findings on <pr>, then the
#       coverage gaps of the tree (when one is named). One a line, "- " leading.
#
# WHY. Three repairs on one day were told to add shots and pushed without touching the
# capture plan or `## Evidence routes`: nothing red said the evidence was short. These are
# the gaps, named, so the judge fails on them and the repair and fix steps are handed them
# as tasks whose answer is an edit to the plan.
#
# CONFIG: evidence.dir (docs/evidence), evidence.coverage.ignoreRoutes (/dev — route
# prefixes whose pages are a component catalogue, not screens; space-separated).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF_DIR/toolkit-env.sh" >/dev/null 2>&1 || true
opt() { local v=""; v=$(toolkit_cfg "$1" 2>/dev/null) || v=""; printf '%s' "${v:-$2}"; }
PY="$SELF_DIR/evidence-gaps.py"
EV_DIR=$(opt evidence.dir "docs/evidence")
IGNORE=$(opt evidence.coverage.ignoreRoutes "/dev")
SF="${EVIDENCE_GAPS_FINDINGS:-$SELF_DIR/screen-findings.sh}"

die() { echo "evidence-gaps: $*" >&2; exit 2; }

common() { # → the --ignore-route args, one a line
  local r; for r in $IGNORE; do printf -- '--ignore-route\n%s\n' "$r"; done
}

coverage() { # <repo> <base> <head> <key> [<body-file>]
  local repo="$1" base="$2" head="$3" key="$4" body="${5:-}" r
  local -a a=(coverage --repo "$repo" --base "$base" --head "$head")
  [ -n "$key" ] && a+=(--plan "$EV_DIR/$key/plan.json")
  if [ -n "$body" ] && [ -f "$body" ]; then
    while IFS= read -r r; do [ -n "$r" ] && a+=(--route "$r"); done < <(bash "$SELF_DIR/ci-evidence.sh" routes "$body" 2>/dev/null)
  fi
  while IFS= read -r r; do [ -n "$r" ] && a+=("$r"); done < <(common)
  python3 -I "$PY" "${a[@]}"
}

case "${1:-}" in
  coverage)
    [ $# -ge 5 ] || die "usage: coverage <repo> <base> <head> <key> [<body-file>]"
    coverage "$2" "$3" "$4" "$5" "${6:-}" ;;
  routes)
    [ $# -ge 4 ] || die "usage: routes <repo> <base> <head>"
    a=(routes --repo "$2" --base "$3" --head "$4")
    while IFS= read -r r; do [ -n "$r" ] && a+=("$r"); done < <(common)
    python3 -I "$PY" "${a[@]}" ;;
  judge)
    [ $# -ge 5 ] || die "usage: judge <pr> <head> <key> <body-file>"
    repo="${EVIDENCE_GAPS_REPO:-${MAIN_REPO:-}}"; [ -n "$repo" ] && [ -d "$repo" ] || exit 0
    trunk="${INTEGRATION_BRANCH:-develop}"
    git -C "$repo" fetch -q origin "+refs/pull/$2/head:refs/harness/judge/$2" "+refs/heads/$trunk:refs/remotes/origin/$trunk" >/dev/null 2>&1 || exit 0
    git -C "$repo" cat-file -e "$3^{commit}" 2>/dev/null || exit 0
    base=$(git -C "$repo" merge-base "origin/$trunk" "$3" 2>/dev/null) || exit 0
    coverage "$repo" "$base" "$3" "$4" "$5"
    rc=$?; [ "$rc" -le 1 ] || exit 0; exit "$rc" ;;
  tasks)
    [ -n "${2:-}" ] || die "usage: tasks <pr> [<repo> <base> <head> <key> <body-file>]"
    { [ "$2" = - ] || bash "$SF" critic "$2" 2>/dev/null | cut -f3 | python3 -I "$PY" classify
      if [ -n "${3:-}" ]; then coverage "$3" "$4" "$5" "${6:-}" "${7:-}" 2>/dev/null | cut -f4; fi
    } | awk 'NF && !seen[$0]++ { print "- " $0 }' ;;
  *) die "usage: evidence-gaps.sh coverage|routes|judge|tasks …" ;;
esac
