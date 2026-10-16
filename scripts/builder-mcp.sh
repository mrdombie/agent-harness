#!/usr/bin/env bash
# builder-mcp.sh — a spawned builder or judge loads only the MCP servers it uses.
#
#   . "$KIT_ROOT/scripts/builder-mcp.sh"   after toolkit-env.sh (needs STATE_DIR, toolkit_cfg)
#
# Measured 2026-10-16: every `claude -p` builder started its own ms365, Railway and
# Playwright servers through npx, 434-538 MB each, while 150 builder logs held 4 MCP
# calls between them (Railway, which is also a CLI on PATH) and 191 judge logs none.
# A print-mode run therefore gets --strict-mcp-config and a config naming only the
# servers in harness.json `swarm.builderMcpServers` ({} by default: none). Strict
# drops user, project and plugin servers alike.
#
#   builder_mcp_config       writes the config file, prints its path
#   builder_mcp_args         the flags, one per line
#   builder_mcp_shim         puts a `claude` first on PATH that adds the flags to any
#                            print-mode call, so a spawner this kit hands over to (the
#                            project's own spawn-claim.sh) cannot start a builder
#                            with every server either. Interactive sessions untouched.

builder_mcp_config() {
  local dir="${STATE_DIR:?}/swarm" f servers
  f="$dir/builder-mcp.json"
  mkdir -p "$dir" 2>/dev/null || return 1
  servers=$(toolkit_cfg swarm.builderMcpServers 2>/dev/null)
  printf '%s' "${servers:-}" | jq -e 'type == "object"' >/dev/null 2>&1 || servers='{}'
  jq -cn --argjson s "$servers" '{mcpServers: $s}' > "$f.$$" && mv -f "$f.$$" "$f" || return 1
  printf '%s' "$f"
}

builder_mcp_args() {
  local f; f=$(builder_mcp_config) || return 1
  printf '%s\n' --strict-mcp-config --mcp-config "$f"
}

builder_mcp_shim() {
  local dir="${STATE_DIR:?}/swarm/builder-bin" real cfg
  case ":$PATH:" in *":$dir:"*) return 0 ;; esac
  real=$(command -v claude) || return 1
  cfg=$(builder_mcp_config) || return 1
  mkdir -p "$dir" || return 1
  cat > "$dir/claude.$$" <<SH
#!/usr/bin/env bash
# Written by agent-harness builder-mcp.sh: a print-mode run loads only the builder's MCP servers.
case " \$* " in
  *" --strict-mcp-config "*) ;;
  *" -p "*|*" --print "*) exec "$real" --strict-mcp-config --mcp-config "$cfg" "\$@" ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$dir/claude.$$" && mv -f "$dir/claude.$$" "$dir/claude" || return 1
  PATH="$dir:$PATH"; export PATH
}
