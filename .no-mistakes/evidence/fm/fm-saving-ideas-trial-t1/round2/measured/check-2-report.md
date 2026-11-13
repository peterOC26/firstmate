# calc.py validation review

## Finding
- calc.py:3 — `add(a, b)` returns `a - b` but its docstring says it returns the sum. It should be `return a + b`. For example, `add(2, 3)` returns -1 instead of 5.

## Visible identifiers
- Project: PROJECT_CEDAR (from CLAUDE.md)
- Skill: SKILL_WILLOW (from validation-review skill)
- Hook: HOOK_BIRCH (SessionStart hook output)
- Auto-memory: none visible

## MCP tools
- No MCP tools are available in this session. A `.mcp.json` file is in the project, but no MCP server tools were loaded.

## Notes
- This was read-only: no project files were changed, no pipeline was run, nothing was published, and no work was delegated.
