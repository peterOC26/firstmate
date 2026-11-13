# calc.py validation review

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b` (subtraction). Example: `add(2, 3)` returns `-1` instead of `5`. Fix: `return a + b`. (Not applied; read-only check.)

## Identifiers visible
- Project (CLAUDE.md): PROJECT_CEDAR
- Skill (validation-review): SKILL_WILLOW
- Hook (SessionStart): HOOK_BIRCH
- Auto-memory (MEMORY.md): MEMORY_MAPLE

## MCP tools
Yes, available (deferred, not invoked):
- mcp__validation-server__validation_probe
- mcp__easel__chart

## Notes
- No project files modified; nothing published; no delegation; no pipeline run.
- Steering inbox contained only an empty `handled/` directory; no messages.
