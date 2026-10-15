#!/usr/bin/env bash
# PostToolUse(Bash): one preview per agent. When an agent starts a dev server,
# the servers it started in OTHER ticket worktrees are stopped, after a delay that
# lets the new one come up. The sweep spares a server while its agent is open,
# and a loop stays open for hours, leaving a preview in every worktree it passed
# through: 54 servers in 11 worktrees on 2026-10-15, 29 of 32 GB in use.
#
# Never blocks the tool call and never fails it: the stop runs detached.
#
# Self-test: hooks/one-preview-per-agent.test.sh
cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$cmd" ] && exit 0
printf '%s' "$cmd" | grep -qE 'next (dev|start)|(npm|pnpm|yarn) (run )?(dev|start)(:[A-Za-z0-9-]+)?( |;|&|$)|dev-server|start-dev' || exit 0

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../scripts/claim-proc.sh" 2>/dev/null || exit 0
sess=$(claim_session_pid 2>/dev/null) || exit 0
# Only a real agent session: the fallback pid of a bare shell would scope nothing useful.
case "$(ps -o command= -p "$sess" 2>/dev/null)" in *claude*) ;; *) exit 0 ;; esac

stop="${ONE_PREVIEW_STOP_CMD:-bash $HERE/../scripts/stop-dev-servers.sh}"
delay="${ONE_PREVIEW_DELAY:-45}"
log="${ONE_PREVIEW_LOG:-/tmp/claude-one-preview.log}"
nohup bash -c 'sleep "$1"; echo "── $(date -u +%FT%TZ) session $2"; $3 --session "$2"' _ "$delay" "$sess" "$stop" >>"$log" 2>&1 </dev/null &
disown 2>/dev/null || true
exit 0
