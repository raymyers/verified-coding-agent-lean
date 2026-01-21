# Agent Instructions

## Project Overview

A verified ReAct agent in Lean 4. See [README.md](README.md) for build instructions and architecture.

## Quick Reference

```bash
lake build                              # Build
.lake/build/bin/react-agent --help      # Run CLI
lake clean && lake build                # Clean rebuild
```

## Key Files

| File | Purpose |
|------|---------|
| `Main.lean` | CLI entry point, agent loop |
| `ReActAgent/ReAct.lean` | State machine spec + proofs |
| `ReActAgent/ReActExecutable.lean` | Verified stepper |
| `ReActAgent/LLM/` | LLM API client (curl-based) |
| `ReActAgent/Tools/` | Tool execution (bash, read, write) |

## Configuration

Via `.env` or CLI flags:
```
LLM_BASE_URL=http://localhost:8000
LLM_MODEL=claude-sonnet-4-20250514
LLM_API_KEY=your-key
```

## External Docs

- [Lean 4 Manual](https://lean-lang.org/lean4/doc/)
- [Mathlib Docs](https://leanprover-community.github.io/mathlib4_docs/)
- [Lake](https://github.com/leanprover/lake)
