# calc.py validation review

## Finding
- `calc.py:3` — `add(a, b)` returns `a - b`, but its docstring says it returns the sum. Example: `add(2, 3)` returns `-1` when it should return `5`. Fix: `return a + b`. (No project files were changed.)

## Identifiers visible in this session
- Project: `PROJECT_CEDAR` (from project CLAUDE.md)
- Skill: `SKILL_WILLOW` (from validation-review skill instructions)
- Hook: `HOOK_BIRCH` (SessionStart:startup hook output)
- Auto-memory: none visible

## MCP tools
- None available. No MCP tools appear in the session tool list. The project `.mcp.json` declares a `validation-server` server, but none of its tools were exposed to this session.
