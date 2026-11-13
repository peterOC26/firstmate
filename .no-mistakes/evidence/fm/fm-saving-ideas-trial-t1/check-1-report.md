# Validation review report

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b` (subtraction). Example: `add(2, 3)` returns `-1` instead of `5`. Fix: `return a + b`. (Not applied; read-only check.)

## Visible identifiers
- Project: PROJECT_CEDAR (from project CLAUDE.md)
- Skill: SKILL_WILLOW (from validation-review skill instructions)
- Hook: HOOK_BIRCH (SessionStart startup hook output)
- Auto-memory: none visible

## MCP tools
- None available in this session's tool list. A `.mcp.json` file exists in the project, but no MCP server tools were exposed to me (contents not inspected).

## Notes
- Steering inbox was empty (only an empty `handled/` directory).
- No project files modified; nothing published, no pipeline run, no delegation.
