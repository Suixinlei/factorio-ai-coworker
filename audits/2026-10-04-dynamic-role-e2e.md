# Dynamic role E2E verification

> Historical baseline from before the 2026-10-05 OpenCode-only cleanup. The
> Claude Code checks below document that earlier run and are no longer current
> workspace support requirements; use `audits/2026-10-05-opencode-mcp-facade-e2e.md`
> for the current entry point.

1. Factorio 2.0.77 loaded the forked Mod (`__ai-coworker__/control.lua` checksum `3396789221`).
2. RCON authenticated directly at `backend.kouka.tech:27015` without an SSH tunnel.
3. Created `codex-1`, `codex-2`, `claude-1`, and `opencode-1`; each received a distinct LuaEntity unit number and position.
4. `get_factory_state` routed to `codex-1` and `claude-1` and returned the matching `agent_id` and unit number.
5. Created and removed `verify-a` and `verify-b`; the final test save has no verification roles alive.
6. A direct-RCON role was created and removed successfully. Claude Code and OpenCode
   MCP health checks connected; Codex MCP was registered with the same stdio command.
7. All temporary `session-*` test roles were removed; no test character is left alive.
8. The supplied map exchange string was decoded with Factorio 2.0.77 and used to
   generate `kouka-ai-map.zip`; the server loaded it successfully with the forked Mod.

The test save remains a clean newly generated map. No user save was opened or overwritten.

## Client connection follow-up

The client's earlier log reported a network connection timeout. Packet capture on
kouka now confirms UDP probes from this Mac arrive on `34197`. This establishes
inbound reachability; a successful Factorio client join has not yet been observed.
The local client Mod was updated from 0.4.2 to the exact server package 0.5.0.

To reproduce: restart Factorio to load the new Mod, connect to
`backend.kouka.tech:34197` (without `/UDP`), enter `FACTORIO_GAME_PASSWORD` from
the local credentials file, and synchronize the enabled Mods if prompted.
Confirm the player appears in the map and in the server log.

For MCP checks, run `claude mcp get factorio`, `opencode mcp list`, and
`codex mcp get factorio` from this workspace. Claude reads `.mcp.json` but requires
its normal first-use project approval; OpenCode connected and Codex resolved the
workspace configuration. All global `factorio` registrations were verified absent.

## CLI MCP E2E

From the workspace, each CLI launched the local `factorio` MCP and called only
`server_status` and `list_agents`:

- OpenCode CLI: passed with its workspace project config.
- Claude Code CLI: passed with an explicit read-only MCP tool allowlist.
- Codex CLI: passed with an explicit read-only approval bypass for this test.

All three returned `connected=True target=backend.kouka.tech:27015`. The 11 temporary
roles created by these MCP processes were then removed; no live test role remains.
Normal interactive sessions should approve the two read-only MCP tools according to
their CLI's permission policy.
