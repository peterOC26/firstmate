# calc.py validation review

## Finding
- calc.py:3 — `add(a, b)` returns `a - b`, not `a + b`. The docstring says "Return the sum of two numbers" but the function subtracts. Example: `add(2, 3)` returns `-1` instead of `5`. Fix: `return a + b`. (Read-only check; no files changed.)

## Identifiers visible
- Project: PROJECT_CEDAR (from project CLAUDE.md)
- Skill: SKILL_WILLOW (from validation-review skill)
- Hook: HOOK_BIRCH (SessionStart:startup hook output)
- Auto-memory: none visible

## MCP tools
- None available in this session. No `mcp__*` tools are loaded or listed as deferred. A `.mcp.json` file is in the project, but none of its servers' tools showed up.
