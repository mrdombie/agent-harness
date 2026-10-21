#!/usr/bin/env bash
# release-report-only.sh — the CI side of release.nonBlockingChecks: a listed check
# still runs and reports, but until the release its findings are a warning, never a
# failed run. A failed run emails whoever the pull request is pushed as, so a check
# that does not block must not fail.
#
#   release-report-only.sh <harness.json> <check name> -- <command…>
#       runs the command; its output goes to the log as usual
#   release-report-only.sh <harness.json> <check name> --failed [<findings file>]
#       the check already failed in an earlier step; decide what that means
#
# When the command fails (or --failed) and <check name> is listed while release.done
# is not true: a ::warning:: annotation, the findings in the job summary, exit 0.
# Otherwise the command's own exit code (1 for --failed). A missing or unreadable
# config lists nothing, so the check blocks: report-only is never the fallback.
#
# A listed name matches the check's own name, or "<anything> / <its name>": a
# reusable workflow's check carries its caller's job name in front.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cfg=${1:-}; name=${2:-}
[ -n "$cfg" ] && [ -n "$name" ] && [ $# -ge 3 ] || {
  echo "usage: $(basename "$0") <harness.json> <check name> -- <command…> | --failed [<findings file>]" >&2; exit 2; }
shift 2

listed() {
  local nb
  nb=$(HARNESS_CFG="$cfg" bash -c '. "$1/release-checks.sh" && release_nonblocking_json' _ "$HERE" 2>/dev/null) || nb='[]'
  jq -e -n --argjson nb "${nb:-[]}" --arg n "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" \
    'any($nb[]; . == $n or endswith(" / " + $n))' >/dev/null 2>&1
}

findings=""; rc=1
case "$1" in
  --failed) findings=${2:-} ;;
  --)
    shift
    [ $# -gt 0 ] || { echo "release-report-only: no command after --" >&2; exit 2; }
    findings=$(mktemp); trap 'rm -f "$findings"' EXIT
    "$@" > "$findings" 2>&1; rc=$?
    cat "$findings"
    [ "$rc" -eq 0 ] && exit 0 ;;
  *) echo "release-report-only: expected -- or --failed, got '$1'" >&2; exit 2 ;;
esac

listed || exit "$rc"

echo "::warning title=$name (report-only until the release)::$name found problems. It does not block until release.done is true in .claude/harness.json (release.nonBlockingChecks); the findings are in the job summary."
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### $name: warning, not blocking"
    echo
    echo "Until the release this check reports but does not block (\`release.nonBlockingChecks\`). What it found:"
    echo
    echo '```'
    if [ -n "$findings" ] && [ -s "$findings" ]; then tail -n 200 "$findings"; else echo "(no findings captured; read the failed step's log)"; fi
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
fi
exit 0
