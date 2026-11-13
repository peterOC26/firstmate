# Validation review: calc.py

## Finding
- `calc.py:3` — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b`, so it subtracts. Example: `add(2, 3)` returns `-1`, expected `5`. Fix: `return a + b`. (Not applied: this is a read-only check.)

## Visible identifiers
- Project: PROJECT_CEDAR (from project CLAUDE.md)
- Skill: SKILL_WILLOW (from validation-review skill instructions)
- Hook: HOOK_BIRCH (SessionStart hook output)
- Auto-memory: none visible

## MCP tools
- Yes. One MCP tool is available, as a deferred tool: `mcp__easel__chart` (easel server, cc-plugin-easel plugin). I did not use it.
