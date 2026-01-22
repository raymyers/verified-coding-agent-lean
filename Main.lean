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
  IO.println "  -e, --endpoint <URL>   LLM API endpoint (default: http://localhost:8000/v1/chat/completions)"
  IO.println "  -m, --model <NAME>     Model name (default: claude-sonnet-4-20250514)"
  IO.println "  -k, --api-key <KEY>    API key (or set LLM_API_KEY env var)"
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
  -- Also check LLM_API_KEY env var as fallback
  let envKey ← IO.getEnv "LLM_API_KEY"
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
  let request : LLM.Request := ⟨[LLM.ChatMessage.text "user" cfg.task], []⟩
  if cfg.verbose then
    IO.println "Calling LLM..."
  let response ← LLM.call llmCfg request
  if cfg.verbose then
    IO.println s!"Raw response: {response}"
    IO.println ""
  match ← LLM.parseResponse response with
  | .content text => IO.println text
  | .toolCalls _ => IO.println "Unexpected tool calls in prompt mode"
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
  let mut messages : List LLM.ChatMessage := [
    LLM.ChatMessage.text "system" "You are a helpful assistant.",
    LLM.ChatMessage.text "user" cfg.task
  ]
  IO.println s!"You: {cfg.task}"
  -- First response
  let response ← LLM.call llmCfg ⟨messages, []⟩
  let content ← match ← LLM.parseResponse response with
    | .content text => pure text
    | .toolCalls _ => pure "(unexpected tool call)"
  IO.println s!"Assistant: {content}"
  messages := messages ++ [LLM.ChatMessage.text "assistant" content]
  -- Chat loop
  let stdin ← IO.getStdin
  repeat do
    IO.print "You: "
    let line ← stdin.getLine
    let input := line.trim
    if input.isEmpty || input == "quit" || input == "exit" then
      break
    messages := messages ++ [LLM.ChatMessage.text "user" input]
    let response ← LLM.call llmCfg ⟨messages, []⟩
    let content ← match ← LLM.parseResponse response with
      | .content text => pure text
      | .toolCalls _ => pure "(unexpected tool call)"
    IO.println s!"Assistant: {content}"
    messages := messages ++ [LLM.ChatMessage.text "assistant" content]
  return 0

/-! ## ReAct Agent Implementation -/

/-- System prompt for ReAct agent. -/
def reactSystemPrompt (task : String) : String :=
  s!"You are a coding agent that solves tasks step by step.

TASK: {task}

Use the provided tools to accomplish the task. When finished, call the submit tool with your result."

/-- Tool definitions for the agent. -/
def agentTools : List LLM.ToolFunction := [
  { name := "bash"
    description := "Execute a shell command"
    parameters := [{ name := "command", type := "string", description := "The command to execute" }]
    required := ["command"] },
  { name := "read_file"
    description := "Read a file's contents"
    parameters := [{ name := "path", type := "string", description := "Path to the file" }]
    required := ["path"] },
  { name := "write_file"
    description := "Write content to a file"
    parameters := [
      { name := "path", type := "string", description := "Path to the file" },
      { name := "content", type := "string", description := "Content to write" }
    ]
    required := ["path", "content"] },
  { name := "submit"
    description := "Submit the final result and complete the task"
    parameters := [{ name := "result", type := "string", description := "The final result or answer" }]
    required := ["result"] }
]

/-- Extract argument from tool call JSON. -/
def getToolArg (args : String) (key : String) : IO String := do
  match Lean.Json.parse args with
  | .error e => throw <| IO.userError s!"Failed to parse tool arguments: {e}"
  | .ok json =>
      match json.getObjValAs? String key with
      | .ok val => return val
      | .error _ => throw <| IO.userError s!"Missing argument '{key}' in tool call"

/-- Convert a tool call to an Action. -/
def toolCallToAction (tc : LLM.ToolCall) : IO Action := do
  match tc.name with
  | "bash" =>
      let cmd ← getToolArg tc.arguments "command"
      return .toolCall "bash" cmd
  | "read_file" =>
      let path ← getToolArg tc.arguments "path"
      return .toolCall "read_file" path
  | "write_file" =>
      let path ← getToolArg tc.arguments "path"
      let content ← getToolArg tc.arguments "content"
      return .toolCall "write_file" s!"{path} {content}"
  | "submit" =>
      let result ← getToolArg tc.arguments "result"
      return .submit result
  | other => throw <| IO.userError s!"Unknown tool: {other}"

/-- A pending tool call with its raw JSON for message history.
    The consistency field ensures the raw JSON ID matches the parsed call ID. -/
structure PendingToolCall where
  call : LLM.ToolCall
  raw : Lean.Json
  action : Action
  consistent : LLM.ToolCall.idFromJson raw = call.id

/-- Convert trace to chat messages for LLM (using tool calling format).
    Always includes a user message with the task to satisfy API requirements. -/
def traceToMessages (systemPrompt : String) (task : String)
    (trace : List (PendingToolCall × String)) : List LLM.ChatMessage :=
  let system := LLM.ChatMessage.text "system" systemPrompt
  let user := LLM.ChatMessage.text "user" task
  let history := trace.flatMap fun (tc, observation) =>
    [ LLM.ChatMessage.withToolCalls #[tc.raw],
      LLM.ChatMessage.toolResult tc.call.id tc.call.name observation ]
  [system, user] ++ history

/-- The history produced by traceToMessages has well-formed tool calls
    (each assistant message with tool calls is immediately followed by matching tool result). -/
theorem traceHistory_wellFormed (trace : List (PendingToolCall × String)) :
    LLM.toolCallsWellFormed (trace.flatMap fun (tc, observation) =>
      [ LLM.ChatMessage.withToolCalls #[tc.raw],
        LLM.ChatMessage.toolResult tc.call.id tc.call.name observation ]) = true := by
  induction trace with
  | nil => simp only [List.flatMap_nil, LLM.toolCallsWellFormed]
  | cons hd tl ih =>
      -- Expand flatMap on the cons
      change LLM.toolCallsWellFormed
        ([ LLM.ChatMessage.withToolCalls #[hd.fst.raw],
           LLM.ChatMessage.toolResult hd.fst.call.id hd.fst.call.name hd.snd ] ++
         tl.flatMap fun (tc, observation) =>
           [ LLM.ChatMessage.withToolCalls #[tc.raw],
             LLM.ChatMessage.toolResult tc.call.id tc.call.name observation ]) = true
      -- Use hd.fst.consistent: idFromJson hd.fst.raw = hd.fst.call.id
      have hcons := hd.fst.consistent
      -- Simplify the message constructors
      simp only [LLM.ChatMessage.withToolCalls, LLM.ChatMessage.toolResult,
                 List.cons_append, List.nil_append]
      -- Unfold toolCallsWellFormed, extractToolCallIds, and toolResultsMatch
      unfold LLM.toolCallsWellFormed LLM.extractToolCallIds LLM.toolResultsMatch
      -- Simplify boolean expressions
      simp only [List.map, beq_self_eq_true, Bool.true_and]
      -- Use hcons to prove ID match, simplify toolResultsMatch [] and List.drop
      simp only [hcons, LLM.toolResultsMatch, List.length_singleton, List.drop_one,
                 List.tail_cons, beq_self_eq_true, Bool.true_and]
      exact ih

/-- Any request built from traceToMessages is valid. -/
theorem traceToMessages_valid (systemPrompt task : String)
    (trace : List (PendingToolCall × String)) (tools : List LLM.ToolFunction) :
    LLM.Request.valid ⟨traceToMessages systemPrompt task trace, tools⟩ := by
  constructor
  · -- Part 1: contains non-system message
    simp only [traceToMessages]
    exact ⟨LLM.ChatMessage.text "user" task, by simp, by simp [LLM.ChatMessage.text]⟩
  · -- Part 2: tool calls well-formed
    simp only [traceToMessages]
    -- [system, user] ++ history where system and user have no tool calls
    have hwf := traceHistory_wellFormed trace
    -- Apply cons lemma twice for system and user messages
    apply LLM.toolCallsWellFormed_cons_noToolCalls
    · simp [LLM.ChatMessage.text]
    apply LLM.toolCallsWellFormed_cons_noToolCalls
    · simp [LLM.ChatMessage.text]
    exact hwf

/-- React mode: full agent with tool calling. -/
def runReactMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: react (full agent with tool calling)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println s!"Task: {cfg.task}"
    IO.println s!"Max turns: {cfg.maxTurns}"
    IO.println ""
  let llmCfg : LLM.Config := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let systemPrompt := reactSystemPrompt cfg.task
  -- Track conversation history for tool calling
  let mut history : List (PendingToolCall × String) := []
  let mut stepCount := 0
  let mut done := false
  let mut finalResult : Option String := none
  let mut errorMsg : Option String := none
  while !done && stepCount < cfg.maxTurns do
    stepCount := stepCount + 1
    if cfg.verbose then
      IO.println s!"[Step {stepCount}]"
    -- Build messages and call LLM (proven valid by traceToMessages_valid)
    let messages := traceToMessages systemPrompt cfg.task history
    let request : LLM.Request := ⟨messages, agentTools⟩
    if cfg.verbose then
      IO.println s!"  Calling LLM with {request.messages.length} messages..."
    let response ← LLM.call llmCfg request
    -- Parse response
    match ← LLM.parseResponse response with
    | .content text =>
        IO.println s!"Assistant: {text}"
        -- Model responded with text instead of tool call - treat as done
        finalResult := some text
        done := true
    | .toolCalls parsedCalls =>
        -- Process first tool call (could extend to handle multiple)
        if h : parsedCalls.size > 0 then
          let ptc := parsedCalls[0]
          if cfg.verbose then
            IO.println s!"  Tool call: {ptc.call.name}({ptc.call.arguments})"
          -- Convert to Action and execute
          let action ← toolCallToAction ptc.call
          match action with
          | .submit result =>
              IO.println s!"Submit: {result}"
              finalResult := some result
              done := true
          | .toolCall name args =>
              IO.println s!"Tool: {name}"
              let observation ← Tools.execute cfg.workDir name args
              IO.println s!"Observation: {observation.take 500}"
              -- Add to history (consistency proof comes from ParsedToolCall)
              let pending : PendingToolCall :=
                { call := ptc.call, raw := ptc.raw, action, consistent := ptc.consistent }
              history := history ++ [(pending, observation)]
          | .requestInput _ =>
              errorMsg := some "requestInput not supported with tool calling"
              done := true
        else
          errorMsg := some "Empty tool calls array"
          done := true
  -- Report results
  IO.println s!"\nAgent completed."
  IO.println s!"  Steps taken: {stepCount}"
  match errorMsg with
  | some e =>
      IO.println s!"  Error: {e}"
      return 1
  | none =>
      match finalResult with
      | some result =>
          IO.println s!"  Result: {result}"
          return 0
      | none =>
          IO.println s!"  Error: Max turns reached"
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
