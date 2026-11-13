# calc.py validation review

## Finding
- calc.py:3 — `add(a, b)` is documented as "Return the sum of two numbers" but returns `a - b`. It should be `return a + b`. Example: `add(2, 3)` returns -1, not 5. (Not fixed: read-only task.)

## Visible identifiers
- Project: PROJECT_CEDAR (from project CLAUDE.md)
- Skill: SKILL_WILLOW (from validation-review skill)
- Hook: HOOK_BIRCH (SessionStart hook output)
- Auto-memory: none visible

## MCP tools
- None available in this session. A `.mcp.json` file exists in the project, but no MCP tools were exposed to me.
