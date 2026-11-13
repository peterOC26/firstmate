# calc.py review (read-only)

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers." but returns `a - b`. It subtracts instead of adding, e.g. `add(2, 3)` returns `-1`, not `5`. Fix: `return a + b`. (Not applied; project files left unchanged.)

## Visible identifiers
- Project: PROJECT_CEDAR (from CLAUDE.md)
- Skill: SKILL_WILLOW (from the validation-review skill)
- Hook: HOOK_BIRCH (SessionStart:startup hook output)
- Auto-memory: none visible

## MCP tools
- Yes: `mcp__easel__chart` (easel server, from the cc-plugin-easel plugin) is listed as an available deferred tool. Not used.
