#!/usr/bin/env bash
# run-current.sh — a swarm job's launcher. install.sh copies it OUTSIDE the plugin
# cache, so the job runs <relpath> from the plugin version installed now, not the
# one it was installed from (2026-10-16: jobs sat on 0.7.49/0.7.50 under 0.7.55).
#
#   run-current.sh <relpath under the kit> [args…]
#
# The installed version is the user-scope installPath in Claude Code's plugin
# registry. With no jq, no registry, or no usable entry (2026-10-20: a Linux cron
# tick sat on 0.7.103 under 0.7.125), it is the newest version directory beside
# the baked KIT_ROOT that has this job, and only then the baked KIT_ROOT itself.
set -u
rel="${1:?run-current.sh needs a path under the kit}"; shift
baked="${KIT_ROOT:-}"
reg="${SWARM_PLUGIN_REGISTRY:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json}"
cur=""
if [ -n "$baked" ] && [ -r "$reg" ] && command -v jq >/dev/null 2>&1; then
  vdir=$(dirname "$baked")
  id="$(basename "$vdir")@$(basename "$(dirname "$vdir")")"
  cur=$(jq -r --arg id "$id" '((.plugins // .)[$id] // []) | map(select(.scope == "user")) | .[0].installPath // empty' "$reg" 2>/dev/null)
fi
if { [ -z "$cur" ] || [ ! -f "$cur/$rel" ]; } && [ -n "$baked" ]; then
  vdir=$(dirname "$baked")
  newest=$(ls "$vdir" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+)*$' | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
    | while read -r v; do [ -f "$vdir/$v/$rel" ] && printf '%s\n' "$v"; done | tail -1)
  cur="${newest:+$vdir/$newest}"
fi
if [ -n "$cur" ] && [ -f "$cur/$rel" ]; then KIT_ROOT="$cur"; else KIT_ROOT="$baked"; fi
[ -f "$KIT_ROOT/$rel" ] || { echo "run-current: no $rel under '$KIT_ROOT' (registry: $reg)" >&2; exit 127; }
export KIT_ROOT
exec /bin/bash "$KIT_ROOT/$rel" "$@"
