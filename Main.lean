/-
# ReAct Agent CLI

Command-line interface for running the verified ReAct agent.
Uses simple argument parsing (no external CLI package needed).
-/

import Myproject.ReActExecutable

open ReAct

/-- Configuration parsed from CLI arguments. -/
structure CLIConfig where
  task : String
  endpoint : String
  model : String
  maxSteps : Nat
  maxCost : Nat
  headless : Bool
  workDir : String
  verbose : Bool
  deriving Repr

/-- Default configuration. -/
def CLIConfig.default : CLIConfig := {
  task := ""
  endpoint := "http://localhost:8000/v1/chat/completions"
  model := "claude-sonnet-4-20250514"
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
  IO.println "  <TASK>  The task description for the agent"
  IO.println ""
  IO.println "OPTIONS:"
  IO.println "  -e, --endpoint <URL>   LiteLLM proxy endpoint (default: http://localhost:8000/v1/chat/completions)"
  IO.println "  -m, --model <NAME>     Model name (default: claude-sonnet-4-20250514)"
  IO.println "  --max-steps <N>        Maximum steps (default: 20)"
  IO.println "  --max-cost <N>         Maximum token cost (default: 10000)"
  IO.println "  -i, --interactive      Enable interactive mode (non-headless)"
  IO.println "  -w, --workdir <DIR>    Working directory (default: .)"
  IO.println "  -v, --verbose          Verbose output"
  IO.println "  -h, --help             Show this help message"

/-- Parse command line arguments. -/
def parseArgs (args : List String) : IO (Option CLIConfig) := do
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
    | "-e" :: url :: rest => go { cfg with endpoint := url } rest
    | "--endpoint" :: url :: rest => go { cfg with endpoint := url } rest
    | "-m" :: model :: rest => go { cfg with model := model } rest
    | "--model" :: model :: rest => go { cfg with model := model } rest
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
  go CLIConfig.default args

/-- Run the agent with the given configuration. -/
def runAgent (cfg : CLIConfig) : IO UInt32 := do
  if cfg.verbose then
    IO.println s!"Configuration:"
    IO.println s!"  Task: {cfg.task}"
    IO.println s!"  Endpoint: {cfg.endpoint}"
    IO.println s!"  Model: {cfg.model}"
    IO.println s!"  Max steps: {cfg.maxSteps}"
    IO.println s!"  Max cost: {cfg.maxCost}"
    IO.println s!"  Headless: {cfg.headless}"
    IO.println s!"  Work dir: {cfg.workDir}"
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
    IO.println s!"Initial phase: {repr initialState.phase}"
  -- For now, use mock oracles until we implement HTTP
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

/-- Entry point. -/
def main (args : List String) : IO UInt32 := do
  match ← parseArgs args with
  | some cfg => runAgent cfg
  | none => return 1
