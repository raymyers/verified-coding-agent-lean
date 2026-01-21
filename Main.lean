/-
# ReAct Agent CLI

Command-line interface for running the verified ReAct agent.
Supports multiple modes for testing: prompt, chat, react.
-/

import ReActAgent.ReActExecutable
import ReActAgent.LLM
import ReActAgent.Tools

open ReAct

/-! ## Environment File Loading -/

/-- Parse a single line from .env file. Returns (key, value) if valid. -/
def parseEnvLine (line : String) : Option (String × String) :=
  let line := line.trim
  if line.isEmpty || line.startsWith "#" then
    none
  else
    match line.splitOn "=" with
    | [key, value] =>
        let key := key.trim
        let value := value.trim
        -- Remove surrounding quotes if present
        let value := if value.startsWith "\"" && value.endsWith "\"" then
          value.drop 1 |>.dropRight 1
        else value
        some (key, value)
    | _ => none

/-- Load environment variables from .env file. -/
def loadEnvFile (path : String := ".env") : IO (List (String × String)) := do
  let result ← IO.FS.readFile path |>.toBaseIO
  match result with
  | .ok content =>
      let lines := content.splitOn "\n"
      return lines.filterMap parseEnvLine
  | .error _ =>
      return []

/-- Environment configuration loaded from .env file. -/
structure EnvConfig where
  model : Option String
  apiKey : Option String
  baseUrl : Option String

/-- Load config from .env file. -/
def loadEnvConfig : IO EnvConfig := do
  let vars ← loadEnvFile
  let lookup key := vars.find? (·.1 == key) |>.map (·.2)
  return {
    model := lookup "LLM_MODEL"
    apiKey := lookup "LLM_API_KEY"
    baseUrl := lookup "LLM_BASE_URL"
  }

/-! ## CLI Configuration -/

/-- Agent operation mode. -/
inductive Mode where
  | prompt  -- Single LLM call, print response
  | chat    -- Multi-turn chat, no tools
  | react   -- Full ReAct agent with tools
  deriving Repr, BEq

/-- Parse mode from string. -/
def Mode.parse : String → Option Mode
  | "prompt" => some .prompt
  | "chat" => some .chat
  | "react" => some .react
  | _ => none

/-- Configuration parsed from CLI arguments. -/
structure CLIConfig where
  mode : Mode
  task : String
  endpoint : String
  model : String
  apiKey : String
  maxTurns : Nat   -- A turn = one think+act cycle
  maxCost : Nat
  headless : Bool
  workDir : String
  verbose : Bool
  deriving Repr

/-- Default configuration (without env). -/
def CLIConfig.default : CLIConfig := {
  mode := .react
  task := ""
  endpoint := "http://localhost:8000/v1/chat/completions"
  model := "claude-sonnet-4-20250514"
  apiKey := ""
  maxTurns := 20
  maxCost := 10000
  headless := true
  workDir := "."
  verbose := false
}

/-- Create config with .env overrides. -/
def CLIConfig.withEnv (env : EnvConfig) : CLIConfig :=
  let base := CLIConfig.default
  { base with
    endpoint := env.baseUrl.map (· ++ "/v1/chat/completions") |>.getD base.endpoint
    model := env.model.getD base.model
    apiKey := env.apiKey.getD base.apiKey
  }

/-- Print usage information. -/
def printUsage : IO Unit := do
  IO.println "react-agent v0.1.0 - A verified ReAct agent for coding tasks"
  IO.println ""
  IO.println "USAGE:"
  IO.println "  react-agent [OPTIONS] <TASK>"
  IO.println ""
  IO.println "ARGS:"
  IO.println "  <TASK>  The task/prompt for the agent"
  IO.println ""
  IO.println "OPTIONS:"
  IO.println "  --mode <MODE>          Mode: prompt, chat, react (default: react)"
  IO.println "  -e, --endpoint <URL>   LiteLLM endpoint (default: http://localhost:8000/v1/chat/completions)"
  IO.println "  -m, --model <NAME>     Model name (default: claude-sonnet-4-20250514)"
  IO.println "  -k, --api-key <KEY>    API key (or set LITELLM_API_KEY env var)"
  IO.println "  --max-turns <N>        Maximum turns/think+act cycles (default: 20)"
  IO.println "  --max-cost <N>         Maximum token cost (default: 10000)"
  IO.println "  -i, --interactive      Enable interactive mode (non-headless)"
  IO.println "  -w, --workdir <DIR>    Working directory (default: .)"
  IO.println "  -v, --verbose          Verbose output"
  IO.println "  -h, --help             Show this help message"
  IO.println ""
  IO.println "MODES:"
  IO.println "  prompt  Single LLM call, print response (test connection)"
  IO.println "  chat    Multi-turn chat without tools"
  IO.println "  react   Full ReAct agent with tool execution (default)"

/-- Parse command line arguments. -/
def parseArgs (args : List String) : IO (Option CLIConfig) := do
  -- Load .env file first
  let envCfg ← loadEnvConfig
  let baseCfg := CLIConfig.withEnv envCfg
  -- Also check LITELLM_API_KEY env var as fallback
  let envKey ← IO.getEnv "LITELLM_API_KEY"
  let baseCfg := if baseCfg.apiKey.isEmpty then
    { baseCfg with apiKey := envKey.getD "" }
  else baseCfg
  let rec go (cfg : CLIConfig) (args : List String) : IO (Option CLIConfig) := do
    match args with
    | [] =>
        if cfg.task.isEmpty then
          IO.println "Error: Missing required argument <TASK>"
          printUsage
          return none
        else
          return some cfg
    | "-h" :: _ => printUsage; return none
    | "--help" :: _ => printUsage; return none
    | "--mode" :: m :: rest =>
        match Mode.parse m with
        | some mode => go { cfg with mode := mode } rest
        | none => IO.println s!"Error: Invalid mode '{m}'. Use: prompt, chat, react"; return none
    | "-e" :: url :: rest => go { cfg with endpoint := url } rest
    | "--endpoint" :: url :: rest => go { cfg with endpoint := url } rest
    | "-m" :: model :: rest => go { cfg with model := model } rest
    | "--model" :: model :: rest => go { cfg with model := model } rest
    | "-k" :: key :: rest => go { cfg with apiKey := key } rest
    | "--api-key" :: key :: rest => go { cfg with apiKey := key } rest
    | "--max-turns" :: n :: rest =>
        match n.toNat? with
        | some num => go { cfg with maxTurns := num } rest
        | none => IO.println s!"Error: Invalid number for --max-turns: {n}"; return none
    | "--max-cost" :: n :: rest =>
        match n.toNat? with
        | some num => go { cfg with maxCost := num } rest
        | none => IO.println s!"Error: Invalid number for --max-cost: {n}"; return none
    | "-i" :: rest => go { cfg with headless := false } rest
    | "--interactive" :: rest => go { cfg with headless := false } rest
    | "-w" :: dir :: rest => go { cfg with workDir := dir } rest
    | "--workdir" :: dir :: rest => go { cfg with workDir := dir } rest
    | "-v" :: rest => go { cfg with verbose := true } rest
    | "--verbose" :: rest => go { cfg with verbose := true } rest
    | arg :: rest =>
        if arg.startsWith "-" then
          IO.println s!"Error: Unknown option: {arg}"
          printUsage
          return none
        else if cfg.task.isEmpty then
          go { cfg with task := arg } rest
        else
          go { cfg with task := cfg.task ++ " " ++ arg } rest
  go baseCfg args

/-! ## Mode Handlers -/

/-- Prompt mode: single LLM call. -/
def runPromptMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: prompt (single LLM call)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println s!"Prompt: {cfg.task}"
    IO.println ""
  let llmCfg : LLM.Config := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let messages := [{ role := "user", content := cfg.task : LLM.ChatMessage }]
  if cfg.verbose then
    IO.println "Calling LLM..."
  let response ← LLM.call llmCfg messages
  if cfg.verbose then
    IO.println s!"Raw response: {response}"
    IO.println ""
  let content ← LLM.extractContent response
  IO.println content
  return 0

/-- Chat mode: multi-turn conversation without tools. -/
def runChatMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: chat (multi-turn, no tools)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println ""
  let llmCfg : LLM.Config := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let systemPrompt := "You are a helpful assistant."
  let mut messages : List LLM.ChatMessage := [
    { role := "system", content := systemPrompt },
    { role := "user", content := cfg.task }
  ]
  IO.println s!"You: {cfg.task}"
  -- First response
  let response ← LLM.call llmCfg messages
  let content ← LLM.extractContent response
  IO.println s!"Assistant: {content}"
  messages := messages ++ [{ role := "assistant", content := content }]
  -- Chat loop
  let stdin ← IO.getStdin
  repeat do
    IO.print "You: "
    let line ← stdin.getLine
    let input := line.trim
    if input.isEmpty || input == "quit" || input == "exit" then
      break
    messages := messages ++ [{ role := "user", content := input }]
    let response ← LLM.call llmCfg messages
    let content ← LLM.extractContent response
    IO.println s!"Assistant: {content}"
    messages := messages ++ [{ role := "assistant", content := content }]
  return 0

/-! ## ReAct Agent Implementation -/

/-- System prompt for ReAct agent. -/
def reactSystemPrompt (task : String) : String :=
  s!"You are a coding agent that solves tasks step by step.

TASK: {task}

You must respond in this exact format:

Thought: <your reasoning about what to do next>
Action: <action_name> <arguments>

Available actions:
- bash <command>: Execute a shell command
- read_file <path>: Read a file's contents
- write_file <path> <content>: Write content to a file
- submit <result>: Submit your final answer and complete the task

Rules:
1. Always start with a Thought explaining your reasoning
2. Then provide exactly ONE Action
3. Wait for the observation before your next step
4. Use 'submit' when the task is complete

Example:
Thought: I need to see what files are in the current directory.
Action: bash ls -la"

/-- Parse thought and action from LLM response. -/
def parseThoughtAction (response : String) : Option (String × Action) := do
  -- Find Thought:
  let thoughtStart := response.splitOn "Thought:"
  guard (thoughtStart.length > 1)
  let afterThought := thoughtStart[1]!
  -- Find Action:
  let actionSplit := afterThought.splitOn "Action:"
  guard (actionSplit.length > 1)
  let thought := actionSplit[0]!.trim
  let actionLine := actionSplit[1]!.trim.splitOn "\n" |>.head!.trim
  -- Parse action
  let action ← parseActionLine actionLine
  return (thought, action)
where
  parseActionLine (line : String) : Option Action := do
    let parts := line.splitOn " "
    guard (parts.length ≥ 1)
    let cmd := parts[0]!
    let args := " ".intercalate (parts.drop 1)
    match cmd with
    | "bash" => some (.toolCall "bash" args)
    | "read_file" => some (.toolCall "read_file" args)
    | "write_file" => some (.toolCall "write_file" args)
    | "submit" => some (.submit args)
    | _ => none

/-- Convert trace to chat messages for LLM. -/
def traceToMessages (systemPrompt : String) (trace : Trace) : List LLM.ChatMessage :=
  let system : LLM.ChatMessage := { role := "system", content := systemPrompt }
  let history := trace.flatMap fun step =>
    let assistantMsg : LLM.ChatMessage := {
      role := "assistant"
      content := s!"Thought: {step.thought}\nAction: {formatAction step.action}"
    }
    let userMsg : LLM.ChatMessage := {
      role := "user"
      content := s!"Observation: {step.observation}"
    }
    [assistantMsg, userMsg]
  let continueMsg : LLM.ChatMessage := {
    role := "user"
    content := if trace.isEmpty then
      "Begin working on the task. Start with your first thought and action."
    else
      "Continue with your next thought and action."
  }
  [system] ++ history ++ [continueMsg]
where
  formatAction : Action → String
    | .toolCall name args => s!"{name} {args}"
    | .submit output => s!"submit {output}"
    | .requestInput prompt => s!"request_input {prompt}"

/-- React mode: full agent with tools. -/
def runReactMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: react (full agent)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println s!"Task: {cfg.task}"
    IO.println s!"Max turns: {cfg.maxTurns}"
    IO.println s!"Max cost: {cfg.maxCost}"
    IO.println s!"Headless: {cfg.headless}"
    IO.println ""
  let initialState : State := {
    phase := .thinking
    trace := []
    stepCount := 0
    cost := 0
    config := {
      limits := { maxSteps := cfg.maxTurns, maxCost := cfg.maxCost }
      tools := ["bash", "read_file", "write_file"]
      headless := cfg.headless
    }
  }
  if cfg.verbose then
    IO.println s!"Starting agent..."
  -- Real agent loop with LLM calls
  let llmCfg : LLM.Config := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let systemPrompt := reactSystemPrompt cfg.task
  -- Run the agent loop manually (can't use runIO without proper IOOracles setup)
  let mut state := initialState
  let mut iteration := 0
  while !state.isTerminal && iteration < cfg.maxSteps do
    iteration := iteration + 1
    if cfg.verbose then
      IO.println s!"[Step {iteration}] Phase: {repr state.phase}"
    match state.phase with
    | .thinking =>
        -- Call LLM
        let messages := traceToMessages systemPrompt state.trace
        if cfg.verbose then
          IO.println s!"  Calling LLM with {messages.length} messages..."
        let response ← LLM.call llmCfg messages
        let content ← LLM.extractContent response
        if cfg.verbose then
          IO.println s!"  LLM response: {content.take 200}..."
        -- Parse thought/action
        match parseThoughtAction content with
        | some (thought, action) =>
            IO.println s!"Thought: {thought}"
            let actionStr := match action with
              | .toolCall name args => s!"{name} {args}"
              | .submit output => s!"submit {output}"
              | .requestInput p => s!"request_input {p}"
            IO.println s!"Action: {actionStr}"
            state := { state with phase := .acting thought action, cost := state.cost + 1 }
        | none =>
            IO.println s!"Error: Could not parse response:\n{content}"
            state := { state with phase := .done (.error "Failed to parse LLM response") }
    | .acting thought action =>
        match action with
        | .toolCall name args =>
            IO.println s!"Executing: {name} {args}"
            let obs ← Tools.execute cfg.workDir name args
            IO.println s!"Observation: {obs.take 500}"
            let step : Step := ⟨thought, action, obs⟩
            state := { state with
              phase := .thinking
              trace := state.trace ++ [step]
              stepCount := state.stepCount + 1
            }
        | .submit output =>
            IO.println s!"Submitting: {output}"
            state := { state with phase := .done (.submitted output) }
        | .requestInput prompt =>
            if cfg.headless then
              state := { state with phase := .done (.error "Headless agent cannot request input") }
            else
              state := { state with phase := .needsInput prompt }
    | .needsInput prompt =>
        IO.println s!"Agent requests input: {prompt}"
        IO.print "> "
        let input ← (← IO.getStdin).getLine
        let step : Step := ⟨"Received user input", .requestInput prompt, input.trim⟩
        state := { state with
          phase := .thinking
          trace := state.trace ++ [step]
        }
    | .done _ => break
  -- Check if we hit step limit
  if iteration ≥ cfg.maxSteps && !state.isTerminal then
    state := { state with phase := .done .stepLimitReached }
  let finalState := state
  IO.println s!"\nAgent completed."
  IO.println s!"  Final phase: {repr finalState.phase}"
  IO.println s!"  Steps taken: {finalState.stepCount}"
  IO.println s!"  Cost: {finalState.cost}"
  match finalState.phase with
  | .done (.submitted output) =>
      IO.println s!"  Output: {output}"
      return 0
  | .done .stepLimitReached =>
      IO.println "  Error: Step limit reached"
      return 1
  | .done .costLimitReached =>
      IO.println "  Error: Cost limit reached"
      return 1
  | .done (.error msg) =>
      IO.println s!"  Error: {msg}"
      return 1
  | .needsInput prompt =>
      IO.println s!"  Blocked on input: {prompt}"
      return 1
  | _ =>
      IO.println "  Error: Agent did not terminate properly"
      return 1

/-- Run the agent with the given configuration. -/
def runAgent (cfg : CLIConfig) : IO UInt32 := do
  match cfg.mode with
  | .prompt => runPromptMode cfg
  | .chat => runChatMode cfg
  | .react => runReactMode cfg

/-- Entry point. -/
def main (args : List String) : IO UInt32 := do
  match ← parseArgs args with
  | some cfg =>
      let result ← runAgent cfg |>.toBaseIO
      match result with
      | .ok code => return code
      | .error e =>
          IO.println s!"Error: {e}"
          return 1
  | none => return 1
