/-
# MCP Error Types

Structured error types distinguishing transport, protocol, and tool errors.
-/

namespace MCP

/-- Structured MCP error categories. -/
inductive McpError where
  /-- Transport-level: child process died, pipe broken, invalid JSON -/
  | transport (msg : String)
  /-- Protocol-level: JSON-RPC error response, version mismatch -/
  | protocol (code : Int) (msg : String)
  /-- Tool execution error: server reported isError=true -/
  | toolExecution (msg : String)
  deriving Inhabited

instance : ToString McpError where
  toString
    | .transport msg => s!"MCP transport error: {msg}"
    | .protocol code msg => s!"MCP protocol error ({code}): {msg}"
    | .toolExecution msg => s!"MCP tool error: {msg}"

/-- Convert an McpError to an IO.Error for throwing. -/
def McpError.toIO (e : McpError) : IO.Error :=
  .userError (toString e)

end MCP
