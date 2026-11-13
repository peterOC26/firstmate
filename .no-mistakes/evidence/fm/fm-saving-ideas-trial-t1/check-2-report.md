# Validation review: calc.py

## Finding
- calc.py:3 — `add(a, b)` returns `a - b` instead of `a + b`. Its docstring says it returns the sum, but it actually subtracts. Example: `add(2, 3)` returns `-1` instead of `5`.

## Identifiers I could see
- Project: PROJECT_CEDAR (from CLAUDE.md)
- Skill: SKILL_WILLOW (from the validation-review skill)
- Hook: HOOK_BIRCH (SessionStart hook output)
- Auto-memory: none visible

## MCP tools
- No MCP tools were available in this session. The project has a `.mcp.json` file, but none of its servers' tools showed up in my tool list.

## Scope
Read-only. I changed no project files, ran no pipeline, published nothing and delegated nothing.
