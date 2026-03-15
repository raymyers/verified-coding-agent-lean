/-
# MCP Client

Implements the MCP client lifecycle (initialize/shutdown) and
tool operations (tools/list, tools/call).
-/

import ReActAgent.MCP.Transport

namespace MCP

open Lean (Json ToJson FromJson toJson fromJson?)
open Lean.JsonRpc (Message)

/-! ## Capability & Info Types -/

/-- Server tool capability. -/
structure ToolsCap where
  listChanged : Bool := false
  deriving Inhabited

instance : FromJson ToolsCap where
  fromJson? j := do
    let listChanged := j.getObjValAs? Bool "listChanged" |>.toOption |>.getD false
    return { listChanged }

/-- Negotiated server capabilities. -/
structure ServerCapabilities where
  tools : Option ToolsCap := none
  deriving Inhabited

instance : FromJson ServerCapabilities where
  fromJson? j := do
    let tools := match j.getObjVal? "tools" with
      | .ok tj => fromJson? tj |>.toOption
      | .error _ => none
    return { tools }

/-- Server implementation info. -/
structure ServerInfo where
  name : String
  version : String
  deriving Inhabited

instance : FromJson ServerInfo where
  fromJson? j := do
    let name ← j.getObjValAs? String "name"
    let version ← j.getObjValAs? String "version"
    return { name, version }

/-! ## Tool Types -/

/-- An MCP tool definition from tools/list. -/
structure McpTool where
  name : String
  description : String := ""
  inputSchema : Json := Json.mkObj []
  deriving Inhabited

instance : FromJson McpTool where
  fromJson? j := do
    let name ← j.getObjValAs? String "name"
    let description := j.getObjValAs? String "description" |>.toOption |>.getD ""
    let inputSchema := j.getObjVal? "inputSchema" |>.toOption |>.getD (Json.mkObj [])
    return { name, description, inputSchema }

/-- Content item in a tool result. -/
inductive ToolContent where
  | text (t : String)
  | image (data : String) (mimeType : String)
  | audio (data : String) (mimeType : String)
  | resource (uri : String) (text : String)
  deriving Inhabited

/-- Parse a content item from JSON. -/
def ToolContent.fromJson? (j : Json) : Except String ToolContent := do
  let type ← j.getObjValAs? String "type"
  match type with
  | "text" =>
    let t ← j.getObjValAs? String "text"
    return .text t
  | "image" =>
    let data ← j.getObjValAs? String "data"
    let mime ← j.getObjValAs? String "mimeType"
    return .image data mime
  | "audio" =>
    let data ← j.getObjValAs? String "data"
    let mime ← j.getObjValAs? String "mimeType"
    return .audio data mime
  | "resource" =>
    let res ← j.getObjVal? "resource"
    let uri ← res.getObjValAs? String "uri"
    let text := res.getObjValAs? String "text" |>.toOption |>.getD ""
    return .resource uri text
  | other => throw s!"Unknown content type: {other}"

/-- Result of a tools/call invocation. -/
structure ToolResult where
  content : List ToolContent
  isError : Bool := false
  deriving Inhabited

/-- Render a tool result to a plain string observation. -/
def ToolResult.toObservation (r : ToolResult) : String :=
  let texts := r.content.filterMap fun
    | .text t => some t
    | .resource _ t => some s!"[resource] {t}"
    | .image _ mime => some s!"[image: {mime}]"
    | .audio _ mime => some s!"[audio: {mime}]"
  let body := "\n".intercalate texts
  if r.isError then s!"Error: {body}" else body

/-! ## MCP Client -/

/-- A connected MCP client. -/
structure McpClient where
  transport : StdioTransport
  protocolVersion : String
  serverInfo : ServerInfo
  capabilities : ServerCapabilities

/-- Connect to an MCP server: spawn process, run initialize handshake. -/
def McpClient.connect (cmd : String) (args : Array String)
    (clientName : String := "react-agent") (clientVersion : String := "0.1.0")
    (env : Array (String × Option String) := #[]) : IO McpClient := do
  let transport ← StdioTransport.create cmd args env
  -- Send initialize request
  let initParams := Json.mkObj [
    ("protocolVersion", "2025-03-26"),
    ("capabilities", Json.mkObj []),
    ("clientInfo", Json.mkObj [
      ("name", toJson clientName),
      ("version", toJson clientVersion)
    ])
  ]
  let resp ← transport.request "initialize" (some initParams)
  let result ← match JsonRpc.getResult resp with
    | .ok r => pure r
    | .error e => throw <| IO.userError s!"MCP initialize failed: {e}"
  -- Parse response
  let protocolVersion ← match result.getObjValAs? String "protocolVersion" with
    | .ok v => pure v
    | .error _ => throw <| IO.userError "MCP: missing protocolVersion in initialize response"
  let serverInfo ← match result.getObjVal? "serverInfo" >>= fromJson? with
    | .ok (si : ServerInfo) => pure si
    | .error e => throw <| IO.userError s!"MCP: invalid serverInfo: {e}"
  let capabilities ← match result.getObjVal? "capabilities" >>= fromJson? with
    | .ok (caps : ServerCapabilities) => pure caps
    | .error _ => pure ({} : ServerCapabilities)
  -- Send initialized notification
  transport.notify "notifications/initialized"
  return { transport, protocolVersion, serverInfo, capabilities }

/-- List tools available on this server. -/
def McpClient.listTools (c : McpClient) : IO (List McpTool) := do
  let resp ← c.transport.request "tools/list"
  let result ← match JsonRpc.getResult resp with
    | .ok r => pure r
    | .error e => throw <| IO.userError s!"MCP tools/list failed: {e}"
  let toolsJson ← match result.getObjVal? "tools" with
    | .ok j => pure j
    | .error _ => return []
  match toolsJson with
  | .arr items =>
    let mut tools := []
    for item in items do
      match fromJson? item with
      | .ok (t : McpTool) => tools := tools ++ [t]
      | .error e => throw <| IO.userError s!"MCP: invalid tool: {e}"
    return tools
  | _ => throw <| IO.userError "MCP: tools field is not an array"

/-- Call a tool on this server. -/
def McpClient.callTool (c : McpClient) (name : String) (arguments : Json) : IO ToolResult := do
  let params := Json.mkObj [
    ("name", toJson name),
    ("arguments", arguments)
  ]
  let resp ← c.transport.request "tools/call" (some params)
  let result ← match JsonRpc.getResult resp with
    | .ok r => pure r
    | .error e => throw <| IO.userError s!"MCP tools/call failed: {e}"
  let isError := result.getObjValAs? Bool "isError" |>.toOption |>.getD false
  let contentJson ← match result.getObjVal? "content" with
    | .ok j => pure j
    | .error _ => return { content := [], isError }
  match contentJson with
  | .arr items =>
    let mut content := []
    for item in items do
      match ToolContent.fromJson? item with
      | .ok c => content := content ++ [c]
      | .error e => throw <| IO.userError s!"MCP: invalid tool content: {e}"
    return { content, isError }
  | _ => throw <| IO.userError "MCP: content field is not an array"

/-- Disconnect from the server. -/
def McpClient.disconnect (c : McpClient) : IO Unit := do
  let _ ← c.transport.close

end MCP
