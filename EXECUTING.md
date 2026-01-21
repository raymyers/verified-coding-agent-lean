# Executing the ReAct Agent with a Real LLM

This document describes how to run our verified ReAct agent against a real LLM
via a LiteLLM proxy endpoint.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Lean 4 Runtime                           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐ │
│  │   runIO     │───►│   stepIO    │───►│   IOOracles         │ │
│  │  (loop)     │    │  (verified) │    │  ┌───────────────┐  │ │
│  └─────────────┘    └─────────────┘    │  │ llm: HTTP POST│──┼─┼──► LiteLLM Proxy
│                                         │  │ env: Process  │  │ │         │
│                                         │  │ user: stdin   │  │ │         ▼
│                                         │  └───────────────┘  │ │    Claude/GPT/etc
│                                         └─────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- LiteLLM proxy running locally or remotely
- Lean 4 toolchain installed
- This project built with `lake build`

Example LiteLLM setup:
```bash
pip install litellm
litellm --model claude-sonnet-4-20250514 --port 8000
```

## Implementation Plan

### Phase 1: HTTP Client via curl subprocess

The simplest approach - shell out to `curl` for HTTP requests.

```lean
/-- Make an HTTP POST request using curl subprocess. -/
def httpPost (url : String) (body : String) (headers : List (String × String)) : IO String := do
  let headerArgs := headers.bind fun (k, v) => ["-H", s!"{k}: {v}"]
  let args := ["-s", "-X", "POST", url, "-d", body] ++ headerArgs
  let output ← IO.Process.output { cmd := "curl", args := args.toArray }
  if output.exitCode != 0 then
    throw <| IO.userError s!"curl failed: {output.stderr}"
  return output.stdout
```

### Phase 2: LLM Oracle Implementation

Convert trace to OpenAI-compatible messages and parse response.

```lean
structure LiteLLMConfig where
  endpoint : String := "http://localhost:8000/v1/chat/completions"
  model : String := "claude-sonnet-4-20250514"
  apiKey : String := ""  -- optional, depends on proxy config

/-- Convert our trace to OpenAI message format. -/
def traceToMessages (systemPrompt : String) (trace : Trace) : Json :=
  let msgs := [{ "role" := "system", "content" := systemPrompt }] ++
    trace.bind fun step => [
      { "role" := "assistant", "content" := formatThoughtAction step.thought step.action },
      { "role" := "user", "content" := step.observation }
    ]
  Json.arr msgs

/-- Parse LLM response to extract thought and action. -/
def parseResponse (response : String) : IO LLMResponse := do
  let json ← IO.ofExcept <| Json.parse response
  let content := json.getObjValD "choices" |>.getArrValD 0 |>.getObjValD "message" |>.getObjValD "content"
  -- Parse content for thought/action pattern (e.g., ReAct format)
  let (thought, action) ← parseThoughtAction content.getStr!
  let usage := json.getObjValD "usage" |>.getObjValD "total_tokens" |>.getNatD 0
  return { thought, action, cost := usage }

/-- The LLM oracle backed by LiteLLM. -/
def liteLLMOracle (config : LiteLLMConfig) (systemPrompt : String) : Trace → IO LLMResponse :=
  fun trace => do
    let body := Json.obj [
      ("model", Json.str config.model),
      ("messages", traceToMessages systemPrompt trace)
    ]
    let headers := [
      ("Content-Type", "application/json"),
      ("Authorization", s!"Bearer {config.apiKey}")
    ]
    let response ← httpPost config.endpoint body.toString headers
    parseResponse response
```

### Phase 3: Environment Oracle (Shell Execution)

```lean
/-- Execute a shell command and return output. -/
def shellOracle (workDir : String) : String → String → IO Observation :=
  fun name args => do
    let cmd := match name with
      | "bash" => args
      | "read_file" => s!"cat {args}"
      | "write_file" =>
          let parts := args.splitOn " "
          s!"echo {String.quote parts[1]!} > {parts[0]!}"
      | _ => s!"{name} {args}"
    let output ← IO.Process.output {
      cmd := "bash",
      args := #["-c", cmd],
      cwd := some workDir
    }
    return if output.exitCode == 0
      then output.stdout
      else s!"Error (exit {output.exitCode}): {output.stderr}"
```

### Phase 4: User Oracle (stdin for non-headless)

```lean
/-- Read user input from stdin. -/
def stdinOracle : String → IO String :=
  fun prompt => do
    IO.println s!"Agent requests input: {prompt}"
    IO.print "> "
    (← IO.getStdin).getLine
```

### Phase 5: Putting It Together

```lean
def realIOOracles (config : LiteLLMConfig) (systemPrompt : String) (workDir : String) : IOOracles :=
  { llm := liteLLMOracle config systemPrompt
    env := shellOracle workDir
    user := stdinOracle }

def main : IO Unit := do
  let config : LiteLLMConfig := {
    endpoint := "http://localhost:8000/v1/chat/completions"
    model := "claude-sonnet-4-20250514"
  }
  let systemPrompt := "You are a coding agent. Think step by step, then take an action..."
  let initialState : State := {
    phase := .thinking
    trace := []
    stepCount := 0
    cost := 0
    config := {
      limits := { maxSteps := 20, maxCost := 10000 }
      tools := ["bash", "read_file", "write_file"]
      headless := true
    }
  }
  let oracles := realIOOracles config systemPrompt "."
  let finalState ← runIO oracles initialState
  IO.println s!"Final state: {repr finalState.phase}"
```

## Action Format

The LLM needs to output in a parseable format. We'll use the ReAct pattern:

```
Thought: I need to read the file to understand the bug.
Action: read_file src/main.py
```

Or for submission:
```
Thought: The task is complete.
Action: submit
Output: Fixed the authentication bug by adding token expiry check.
```

## Guarantees That Transfer

Because `stepIO` has the same structure as `stepWith`, and we proved `stepWith_sound`,
the following properties hold at runtime:

1. **Headless agents never block on input** - if `config.headless = true`, the agent
   will never call `user` oracle (proven: `stepWith_headless`)

2. **Trace only grows** - the conversation history is append-only (proven: `stepWith_trace_monotonic`)

3. **Config is immutable** - limits can't be changed mid-run (proven: `stepWith_config_preserved`)

4. **Termination under limits** - if `maxSteps > 0`, the agent will eventually terminate
   (relies on step count incrementing, which we can verify)

## Future Improvements

1. **Native HTTP** - Replace curl subprocess with Lean HTTP library for better performance
2. **Streaming** - Support streaming responses for better UX
3. **Tool schemas** - Generate OpenAI function calling schemas from our `Action` type
4. **Verified parsing** - Prove the action parser is correct w.r.t. the format spec
5. **Cost tracking** - More accurate token counting from the API response

## Testing

```bash
# Start LiteLLM proxy
litellm --model claude-sonnet-4-20250514 --port 8000

# Build and run
lake build
lake exe react-agent "Fix the bug in src/auth.py"
```
