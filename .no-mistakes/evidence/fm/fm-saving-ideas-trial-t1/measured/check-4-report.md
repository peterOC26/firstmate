# calc.py validation review

## Finding
- `calc.py:3` — `add(a, b)` returns `a - b` instead of `a + b`. The docstring says "Return the sum of two numbers", but the function subtracts (e.g. `add(2, 3)` returns `-1`, not `5`). Fix: `return a + b`. (Not applied: this was a read-only check.)

## Identifiers visible
- Project (CLAUDE.md): PROJECT_CEDAR
- Skill (validation-review): SKILL_WILLOW
- Hook (SessionStart): HOOK_BIRCH
- Auto-memory (MEMORY.md): MEMORY_MAPLE

## MCP tools
Yes, MCP tools are available. They are listed as deferred tools, and I did not call either one:
- `mcp__validation-server__validation_probe`
- `mcp__easel__chart`

## Scope
I did not modify any project files. I did not run a pipeline, publish anything or delegate any work. The steering inbox held only a `handled` entry, so there were no new messages to act on.
