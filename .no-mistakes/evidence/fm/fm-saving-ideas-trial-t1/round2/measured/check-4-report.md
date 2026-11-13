# calc.py validation review

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b` (subtraction). E.g. `add(2, 3)` returns `-1` instead of `5`. Fix: `return a + b`. (Not modified; read-only check.)

## Identifiers visible
- Project (CLAUDE.md): PROJECT_CEDAR
- Skill (validation-review): SKILL_WILLOW
- Hook (SessionStart): HOOK_BIRCH
- Auto-memory (MEMORY.md): MEMORY_MAPLE

## MCP tools
Yes, MCP tools are available (listed as deferred tools, none called):
- mcp__validation-server__validation_probe
- mcp__easel__chart
