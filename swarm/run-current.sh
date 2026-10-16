#!/usr/bin/env bash
# run-current.sh — a swarm job's launcher. install.sh copies it OUTSIDE the plugin
# cache, so the job runs <relpath> from the plugin version installed now, not the
# one it was installed from (2026-10-16: jobs sat on 0.7.49/0.7.50 under 0.7.55).
#
#   run-current.sh <relpath under the kit> [args…]
#
# The installed version is the user-scope installPath in Claude Code's plugin
# registry. Unreadable, or naming a path without this job, it falls back to the
# baked KIT_ROOT, so a broken registry never stops a job.
set -u
rel="${1:?run-current.sh needs a path under the kit}"; shift
baked="${KIT_ROOT:-}"
reg="${SWARM_PLUGIN_REGISTRY:-$HOME/.claude/plugins/installed_plugins.json}"
cur=""
if [ -n "$baked" ] && [ -r "$reg" ] && command -v jq >/dev/null 2>&1; then
  vdir=$(dirname "$baked")
  id="$(basename "$vdir")@$(basename "$(dirname "$vdir")")"
  cur=$(jq -r --arg id "$id" '((.plugins // .)[$id] // []) | map(select(.scope == "user")) | .[0].installPath // empty' "$reg" 2>/dev/null)
fi
if [ -n "$cur" ] && [ -f "$cur/$rel" ]; then KIT_ROOT="$cur"; else KIT_ROOT="$baked"; fi
export KIT_ROOT
exec /bin/bash "$KIT_ROOT/$rel" "$@"
