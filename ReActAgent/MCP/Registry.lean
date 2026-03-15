/-
# MCP Tool Registry

Manages multiple MCP server connections and provides a unified
interface for tool discovery and invocation.

Tool names are namespaced as `mcp__<serverName>__<toolName>` to
avoid collisions with built-in tools and between servers.
-/

import ReActAgent.MCP.Client

namespace MCP

open Lean (Json toJson)

/-- Configuration for an MCP server connection. -/
structure McpServerConfig where
  name : String
  command : String
  args : Array String := #[]
  env : Array (String × Option String) := #[]
  deriving Inhabited

/-- A connected server entry in the registry. -/
structure ServerEntry where
  config : McpServerConfig
  client : McpClient
  tools : List McpTool

/-- Prefix for all MCP tool names. -/
def mcpPrefix : String := "mcp__"

/-- Build a qualified tool name: mcp__<server>__<tool>. -/
def qualifiedName (serverName toolName : String) : String :=
  s!"{mcpPrefix}{serverName}__{toolName}"

/-- Parse a qualified name back to (serverName, toolName). Returns none if not an MCP name. -/
def parseQualifiedName (name : String) : Option (String × String) :=
  if !name.startsWith mcpPrefix then none
  else
    let rest := (name.drop mcpPrefix.length).toString
    match rest.splitOn "__" with
    | [server, tool] => some (server, tool)
    | _ => none

/-- Check if a tool name is an MCP-qualified name. -/
def isMcpTool (name : String) : Bool := name.startsWith mcpPrefix

/-- The MCP tool registry. -/
structure McpToolRegistry where
  servers : IO.Ref (List ServerEntry)

/-- Create a new empty registry. -/
def McpToolRegistry.create : IO McpToolRegistry := do
  let servers ← IO.mkRef []
  return { servers }

/-- Add and connect to an MCP server. -/
def McpToolRegistry.addServer (reg : McpToolRegistry) (config : McpServerConfig) : IO Unit := do
  let client ← McpClient.connect config.command config.args
    (env := config.env)
  let tools ← client.listTools
  let entry : ServerEntry := { config, client, tools }
  reg.servers.modify (· ++ [entry])

/-- Disconnect and remove a server. -/
def McpToolRegistry.removeServer (reg : McpToolRegistry) (name : String) : IO Unit := do
  let entries ← reg.servers.get
  for entry in entries do
    if entry.config.name == name then
      entry.client.disconnect
  reg.servers.modify (·.filter (·.config.name != name))

/-- Get all tools across all servers as (qualifiedName, tool) pairs. -/
def McpToolRegistry.allTools (reg : McpToolRegistry) : IO (List (String × McpTool)) := do
  let entries ← reg.servers.get
  let mut result := []
  for entry in entries do
    for tool in entry.tools do
      result := result ++ [(qualifiedName entry.config.name tool.name, tool)]
  return result

/-- Execute a tool by qualified name. -/
def McpToolRegistry.execute (reg : McpToolRegistry)
    (qualName : String) (argsJson : String) : IO String := do
  match parseQualifiedName qualName with
  | none => throw <| IO.userError s!"Not an MCP tool name: {qualName}"
  | some (serverName, toolName) =>
    let entries ← reg.servers.get
    match entries.find? (·.config.name == serverName) with
    | none => throw <| IO.userError s!"MCP server not found: {serverName}"
    | some entry =>
      let args ← match Json.parse argsJson with
        | .ok j => pure j
        | .error e => throw <| IO.userError s!"Invalid tool arguments JSON: {e}"
      let result ← entry.client.callTool toolName args
      return result.toObservation

/-- Disconnect all servers. -/
def McpToolRegistry.disconnectAll (reg : McpToolRegistry) : IO Unit := do
  let entries ← reg.servers.get
  for entry in entries do
    try entry.client.disconnect catch _ => pure ()
  reg.servers.set []

end MCP
