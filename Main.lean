/-
# ReAct Agent CLI

Command-line interface for running the verified ReAct agent.
Supports multiple modes for testing: prompt, chat, react.
-/

import Myproject.ReActExecutable

open ReAct

/-! ## HTTP Client via curl -/

/-- Make an HTTP POST request using curl subprocess. -/
def httpPost (url : String) (body : String) (headers : List (String × String)) : IO String := do
  let headerArgs := headers.flatMap fun (k, v) => ["-H", s!"{k}: {v}"]
  let args : Array String := #["-s", "-X", "POST", url, "-d", body] ++ headerArgs.toArray
  let output ← IO.Process.output { cmd := "curl", args := args }
  if output.exitCode != 0 then
    throw <| IO.userError s!"curl failed (exit {output.exitCode}): {output.stderr}"
  return output.stdout

/-! ## JSON Helpers -/

/-- Escape a string for JSON. -/
def jsonEscape (s : String) : String :=
  s.replace "\\" "\\\\"
   |>.replace "\"" "\\\""
   |>.replace "\n" "\\n"
   |>.replace "\r" "\\r"
   |>.replace "\t" "\\t"

/-- Build a JSON string value. -/
def jsonString (s : String) : String := s!"\"{jsonEscape s}\""

/-- Build a JSON object from key-value pairs. -/
def jsonObject (pairs : List (String × String)) : String :=
  let inner := pairs.map (fun (k, v) => s!"\"{k}\": {v}") |> String.intercalate ", "
  s!"\{{inner}}"

/-- Build a JSON array. -/
def jsonArray (items : List String) : String :=
  s!"[{String.intercalate ", " items}]"

/-! ## LiteLLM Integration -/

/-- A chat message for the OpenAI API. -/
structure ChatMessage where
  role : String
  content : String

/-- Convert ChatMessage to JSON. -/
def ChatMessage.toJson (m : ChatMessage) : String :=
  jsonObject [("role", jsonString m.role), ("content", jsonString m.content)]

/-- Configuration for LiteLLM. -/
structure LiteLLMConfig where
  endpoint : String
  model : String
  apiKey : String := ""

/-- Call LiteLLM with a list of messages. -/
def callLiteLLM (cfg : LiteLLMConfig) (messages : List ChatMessage) : IO String := do
  let messagesJson := jsonArray (messages.map ChatMessage.toJson)
  let body := jsonObject [
    ("model", jsonString cfg.model),
    ("messages", messagesJson)
  ]
  let headers := [
    ("Content-Type", "application/json")
  ] ++ (if cfg.apiKey.isEmpty then [] else [("Authorization", s!"Bearer {cfg.apiKey}")])
  let response ← httpPost cfg.endpoint body headers
  return response

/-- Extract content from OpenAI-style JSON response (simple parsing). -/
def extractContent (response : String) : IO String := do
  -- Simple extraction: find "content": "..." pattern
  -- This is fragile but avoids needing a full JSON parser
  let contentKey := "\"content\":"
  match response.splitOn contentKey with
  | _ :: rest :: _ =>
      let afterKey := rest.trimLeft
      if afterKey.startsWith "\"" then
        let inner := afterKey.drop 1
        -- Find closing quote (not escaped)
        let mut result := ""
        let mut escaped := false
        for c in inner.toList do
          if escaped then
            match c with
            | 'n' => result := result.push '\n'
            | 'r' => result := result.push '\r'
            | 't' => result := result.push '\t'
            | _ => result := result.push c
            escaped := false
          else if c == '\\' then
            escaped := true
          else if c == '"' then
            return result
          else
            result := result.push c
        return result
      else
        throw <| IO.userError s!"Expected string after content key, got: {afterKey.take 50}"
  | _ => throw <| IO.userError s!"Could not find content in response: {response.take 200}"

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
  maxSteps : Nat
  maxCost : Nat
  headless : Bool
  workDir : String
  verbose : Bool
  deriving Repr

/-- Default configuration. -/
def CLIConfig.default : CLIConfig := {
  mode := .react
  task := ""
  endpoint := "http://localhost:8000/v1/chat/completions"
  model := "claude-sonnet-4-20250514"
  apiKey := ""
  maxSteps := 20
  maxCost := 10000
  headless := true
  workDir := "."
  verbose := false
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
  IO.println "  --max-steps <N>        Maximum steps (default: 20)"
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
  -- Get API key from environment if not provided
  let envKey ← IO.getEnv "LITELLM_API_KEY"
  let defaultKey := envKey.getD ""
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
    | "--max-steps" :: n :: rest =>
        match n.toNat? with
        | some num => go { cfg with maxSteps := num } rest
        | none => IO.println s!"Error: Invalid number for --max-steps: {n}"; return none
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
  go { CLIConfig.default with apiKey := defaultKey } args

/-! ## Mode Handlers -/

/-- Prompt mode: single LLM call. -/
def runPromptMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: prompt (single LLM call)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println s!"Prompt: {cfg.task}"
    IO.println ""
  let llmCfg : LiteLLMConfig := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let messages := [{ role := "user", content := cfg.task : ChatMessage }]
  if cfg.verbose then
    IO.println "Calling LLM..."
  let response ← callLiteLLM llmCfg messages
  if cfg.verbose then
    IO.println s!"Raw response: {response}"
    IO.println ""
  let content ← extractContent response
  IO.println content
  return 0

/-- Chat mode: multi-turn conversation without tools. -/
def runChatMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: chat (multi-turn, no tools)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println ""
  let llmCfg : LiteLLMConfig := {
    endpoint := cfg.endpoint
    model := cfg.model
    apiKey := cfg.apiKey
  }
  let systemPrompt := "You are a helpful assistant."
  let mut messages : List ChatMessage := [
    { role := "system", content := systemPrompt },
    { role := "user", content := cfg.task }
  ]
  IO.println s!"You: {cfg.task}"
  -- First response
  let response ← callLiteLLM llmCfg messages
  let content ← extractContent response
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
    let response ← callLiteLLM llmCfg messages
    let content ← extractContent response
    IO.println s!"Assistant: {content}"
    messages := messages ++ [{ role := "assistant", content := content }]
  return 0

/-- React mode: full agent with tools. -/
def runReactMode (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Mode: react (full agent)"
    IO.println s!"Endpoint: {cfg.endpoint}"
    IO.println s!"Model: {cfg.model}"
    IO.println s!"Task: {cfg.task}"
    IO.println s!"Max steps: {cfg.maxSteps}"
    IO.println s!"Max cost: {cfg.maxCost}"
    IO.println s!"Headless: {cfg.headless}"
    IO.println ""
  let initialState : State := {
    phase := .thinking
    trace := []
    stepCount := 0
    cost := 0
    config := {
      limits := { maxSteps := cfg.maxSteps, maxCost := cfg.maxCost }
      tools := ["bash", "read_file", "write_file"]
      headless := cfg.headless
    }
  }
  if cfg.verbose then
    IO.println s!"Starting agent..."
  -- TODO: Replace with real HTTP-backed oracles
  -- For now, still using mock oracles
  let finalState := runWith mockOracles initialState
  IO.println s!"Agent completed."
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
