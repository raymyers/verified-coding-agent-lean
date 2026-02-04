# ReActAgent - Verified Coding Agent in Lean 4

A formalized ReAct (Reasoning + Acting) agent implementation in Lean 4, with mathematical proofs of agent properties.

## Building

Requires [Lean 4](https://lean-lang.org/) and [Lake](https://github.com/leanprover/lake) (included with Lean).

```bash
# Build the project
lake build react-agent 

export PATH=`pwd`/.lake/build/bin:"$PATH"

# Run the agent (requires an OpenAI-compatible API)
react-agent --help
```

## Usage

The agent supports three modes:

```bash
# Test LLM connection with a single prompt
react-agent --mode prompt "What is 2+2?"

# Multi-turn chat (no tools)
react-agent --mode chat "Help me debug this code"

# Full ReAct agent with tools (default)
react-agent "Create a hello world script"
```

Configure the LLM endpoint via `.env` file or command-line flags:

```bash
# .env file
LLM_BASE_URL=http://localhost:8000
LLM_MODEL=claude-sonnet-4-20250514
LLM_API_KEY=your-key-here
```

## Project Structure

```
ReActAgent/
├── Basic.lean           # Basic definitions
├── ReAct.lean           # Formalized state machine and proofs
├── ReActExecutable.lean # Executable stepper with correctness proof
├── LLM/
│   ├── Json.lean        # JSON serialization helpers
│   ├── Http.lean        # HTTP client via curl
│   └── Client.lean      # OpenAI-compatible API client
├── LLM.lean             # LLM module re-exports
├── Tools/
│   └── Executor.lean    # Tool implementations (bash, read_file, write_file)
└── Tools.lean           # Tools module re-exports
Main.lean                # CLI entry point
```

## Architecture Notes

### HTTP via curl

The LLM client uses `curl` as a subprocess rather than a native HTTP library. This is a pragmatic choice:

- Lean 4's ecosystem doesn't yet have a mature, well-maintained HTTP client library
- `curl` is universally available on development machines
- Subprocess spawning is well-supported in Lean's IO monad
- Avoids FFI complexity and C library dependencies

The implementation is in `ReActAgent/LLM/Http.lean`.

### Verified Agent Loop

The core agent logic in `ReAct.lean` defines a state machine with:
- A `Transition` inductive type specifying valid state transitions
- Proofs that the executable stepper respects the transition relation
- Termination guarantees via step/cost limits

## Related

This was implemented with help from [numina-lean-agent](https://github.com/project-numina/numina-lean-agent) and Claude Opus 4.5.

[mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent) is a great starting point as a "minimum viable agent".

## GitHub configuration

To set up your new GitHub repository, follow these steps:

* Under your repository name, click **Settings**.
* In the **Actions** section of the sidebar, click "General".
* Check the box **Allow GitHub Actions to create and approve pull requests**.
* Click the **Pages** section of the settings sidebar.
* In the **Source** dropdown menu, select "GitHub Actions".

After following the steps above, you can remove this section from the README file.
