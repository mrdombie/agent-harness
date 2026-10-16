#!/usr/bin/env bash
# stale-build.test.sh — a session on an older build than the newest installed is
# told to restart; the newest, or a lone install, says nothing.
# Run: bash "$0"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
H="$HERE/stale-build.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FAILED=0
ok()  { printf 'OK       %s\n' "$1"; }
bad() { printf 'MISMATCH %s\n' "$1"; FAILED=1; }
ver() { mkdir -p "$T/cache/$1/.claude-plugin"; printf '{"name":"agent-harness","version":"%s"}\n' "$1" > "$T/cache/$1/.claude-plugin/plugin.json"; }
run() { CLAUDE_PLUGIN_ROOT="$T/cache/$1" bash "$H" </dev/null; }

ver 0.7.40
out=$(run 0.7.40)
[ -z "$out" ] && ok "a lone install says nothing" || bad "a lone install says nothing: $out"
ver 0.7.9; ver 0.7.46
out=$(run 0.7.40)
printf '%s' "$out" | jq -e . >/dev/null 2>&1 && ok "it answers as hook JSON" || bad "it answers as hook JSON: $out"
case "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" in
  *"runs the kit at 0.7.40, but 0.7.46 is installed"*restart*) ok "an older session is told to restart, naming both builds" ;;
  *) bad "an older session is told to restart, naming both builds: $out" ;;
esac
[ "$(printf '%s' "$out" | jq -r .systemMessage)" != null ] && ok "and the operator sees it" || bad "and the operator sees it"
out=$(run 0.7.46)
[ -z "$out" ] && ok "the newest says nothing (0.7.9 sorts below 0.7.46, not above)" || bad "the newest says nothing: $out"
exit $FAILED
