# calc.py validation review

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b`. Example: `add(2, 3)` returns `-1` instead of `5`. Fix: `return a + b`. (Not applied; read-only review.)

## Identifiers visible to me
- Project: `PROJECT_CEDAR` (from CLAUDE.md)
- Skill: `SKILL_WILLOW` (from the validation-review skill instructions)
- Hook: `HOOK_BIRCH` (SessionStart:startup hook output)
- Auto-memory: none visible (no auto-memory identifier appeared in my context)

## MCP tools
- No MCP tools are available in this session. The project `.mcp.json` declares a `validation-server` server, but no MCP tools from it (or any other server) appear in my tool list.

## Notes
- Steering inbox contained only an empty `handled/` subdirectory; no pending messages.
- No project files modified; nothing published, no pipeline run, no delegation.
