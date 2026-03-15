/-
# Stdio Transport

Spawns an MCP server as a child process and communicates via
newline-delimited JSON-RPC over stdin/stdout.
-/

import ReActAgent.MCP.JsonRpc

namespace MCP

open Lean (Json toJson fromJson? ToJson)
open Lean.JsonRpc (Message)

/-- A stdio transport wrapping a child process. -/
structure StdioTransport where
  proc : IO.Process.Child ⟨.piped, .piped, .piped⟩
  nextId : IO.Ref Nat

/-- Spawn a child process and create a transport. -/
def StdioTransport.create (cmd : String) (args : Array String)
    (env : Array (String × Option String) := #[]) : IO StdioTransport := do
  let proc ← IO.Process.spawn {
    cmd := cmd
    args := args
    stdin := .piped
    stdout := .piped
    stderr := .piped
    env := env
  }
  let nextId ← IO.mkRef 1
  return { proc, nextId }

/-- Send a JSON-RPC message (newline-delimited). -/
def StdioTransport.send (t : StdioTransport) (msg : Message) : IO Unit := do
  let json := toJson msg
  let line := json.compress ++ "\n"
  t.proc.stdin.putStr line
  t.proc.stdin.flush

/-- Read one newline-delimited JSON-RPC message from stdout. -/
def StdioTransport.recv (t : StdioTransport) : IO Message := do
  let line ← t.proc.stdout.getLine
  let line := line.trimRight
  if line.isEmpty then
    throw <| IO.userError "MCP server closed stdout (empty read)"
  match Json.parse line with
  | .error e => throw <| IO.userError s!"MCP: invalid JSON from server: {e}\nRaw: {line}"
  | .ok j =>
    match fromJson? j with
    | .ok (msg : Message) => return msg
    | .error e => throw <| IO.userError s!"MCP: invalid JSON-RPC message: {e}\nRaw: {line}"

/-- Allocate a fresh request ID. -/
def StdioTransport.freshId (t : StdioTransport) : IO Nat := do
  let id ← t.nextId.get
  t.nextId.set (id + 1)
  return id

/-- Send a JSON-RPC request and receive the matching response.
    Skips any interleaved notifications from the server. -/
def StdioTransport.request (t : StdioTransport) (method : String)
    (params : Option Json := none) : IO Message := do
  let id ← t.freshId
  let req := JsonRpc.mkRequest id method params
  t.send req
  -- Read messages until we get a response matching our id (max 1000 messages)
  for _ in List.range 1000 do
    let msg ← t.recv
    if JsonRpc.isResponse msg then
      match JsonRpc.getResponseId msg with
      | some rid => if rid == id then return msg
      | none => pure ()
    -- else: notification or unmatched response — skip
  throw <| IO.userError s!"MCP: timeout waiting for response to request {id}"

/-- Send a JSON-RPC notification (no response expected). -/
def StdioTransport.notify (t : StdioTransport) (method : String)
    (params : Option Json := none) : IO Unit :=
  t.send (JsonRpc.mkNotification method params)

/-- Close the transport: close stdin, wait for process. -/
def StdioTransport.close (t : StdioTransport) : IO UInt32 := do
  let (_, child) ← t.proc.takeStdin
  child.wait

end MCP
