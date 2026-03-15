# MCP Client Implementation Plan

Implement an MCP (Model Context Protocol) client in Lean that enables the ReAct agent to
discover and invoke tools hosted by external MCP servers over stdio transport.

**Spec version**: 2025-03-26
**Scope**: stdio transport only, tools capability only, no auth
**Goal**: Agent can use MCP server tools alongside built-in tools (bash, file_editor, etc.)

---

## Milestone 1: JSON-RPC Transport Layer

Standalone JSON-RPC 2.0 over stdio — no MCP-specific logic yet.

- [ ] Define `JsonRpc.Request` structure: `jsonrpc`, `id` (Nat), `method` (String), `params` (Option Json)
- [ ] Define `JsonRpc.Response` structure: `jsonrpc`, `id`, `result` (Option Json), `error` (Option ErrorObj)
- [ ] Define `JsonRpc.Notification` structure: `jsonrpc`, `method`, `params` (Option Json)
- [ ] Define `JsonRpc.ErrorObj`: `code` (Int), `message` (String), `data` (Option Json)
- [ ] Implement `JsonRpc.Request.toJson` and `JsonRpc.Response.fromJson`
- [ ] Implement `JsonRpc.Notification.toJson`
- [ ] Create `StdioTransport` that wraps a child process handle:
  - [ ] `send (msg : Json) : IO Unit` — write JSON + newline to child stdin
  - [ ] `recv : IO Json` — read one newline-delimited JSON from child stdout
- [ ] Implement monotonic request ID counter in `StdioTransport`
- [ ] Write `#eval` tests: round-trip serialize/deserialize for each message type

**Tested deliverable**: Can send a JSON-RPC request to a subprocess and read a JSON-RPC response back. Verified with a trivial echo server script.

---

## Milestone 2: MCP Lifecycle (Initialize / Shutdown)

Implement the MCP handshake on top of the transport.

- [ ] Define `McpClient.ClientCapabilities` — empty struct (we advertise no client caps for now)
- [ ] Define `McpClient.ServerCapabilities` — `tools : Option ToolsCap` where `ToolsCap` has `listChanged : Bool`
- [ ] Define `McpClient.ServerInfo` — `name : String`, `version : String`
- [ ] Implement `McpClient.initialize`:
  - [ ] Send `initialize` request with `protocolVersion = "2025-03-26"`, `clientInfo`, `capabilities = {}`
  - [ ] Parse response: extract `protocolVersion`, `capabilities`, `serverInfo`
  - [ ] Validate protocol version matches (disconnect if mismatch)
  - [ ] Send `notifications/initialized` notification
- [ ] Implement `McpClient.shutdown`: close child stdin, wait/SIGTERM/SIGKILL
- [ ] Define `McpClient` state structure holding transport + negotiated capabilities + server info
- [ ] Implement `McpClient.connect (cmd : String) (args : Array String) : IO McpClient`
  - [ ] Spawn subprocess, create transport, run initialize handshake, return connected client
- [ ] Implement `McpClient.disconnect : IO Unit`

**Tested deliverable**: `McpClient.connect` launches an MCP server (e.g. `npx @modelcontextprotocol/server-everything`), completes handshake, prints server info, then cleanly shuts down.

---

## Milestone 3: Tool Discovery (tools/list)

- [ ] Define `McpTool` structure: `name : String`, `description : String`, `inputSchema : Json`
- [ ] Implement `McpClient.listTools : IO (List McpTool)`
  - [ ] Send `tools/list` request (no pagination for v1)
  - [ ] Parse response: extract `tools` array, map to `McpTool`
- [ ] Implement `McpClient.listToolsAll : IO (List McpTool)` with cursor-based pagination
  - [ ] Loop while `nextCursor` is present

**Tested deliverable**: Connect to an MCP server, list its tools, print name + description for each. Verify against known server that exposes tools.

---

## Milestone 4: Tool Invocation (tools/call)

- [ ] Define `ToolContent` inductive: `text (t : String)` | `image (data : String) (mime : String)` | `resource (uri : String) (text : String)`
- [ ] Define `ToolResult` structure: `content : List ToolContent`, `isError : Bool`
- [ ] Implement `McpClient.callTool (name : String) (arguments : Json) : IO ToolResult`
  - [ ] Send `tools/call` request with `name` and `arguments`
  - [ ] Parse response: extract `content` array and `isError`
  - [ ] Map content items to `ToolContent` values
  - [ ] Handle JSON-RPC error responses (throw or return error)
- [ ] Add timeout support: configurable per-call timeout with cancellation

**Tested deliverable**: Call a tool on a live MCP server, receive and display the text result. Test both success and `isError: true` cases.

---

## Milestone 5: MCP Tool Registry

Bridge between MCP servers and the agent's tool system.

- [ ] Define `McpToolRegistry` that manages multiple `McpClient` connections
  - [ ] `addServer (name : String) (cmd : String) (args : Array String) : IO Unit`
  - [ ] `removeServer (name : String) : IO Unit`
  - [ ] `allTools : IO (List (String × McpTool))` — returns `(serverName, tool)` pairs
- [ ] Convert `McpTool` to the agent's `LLM.Tool` schema format:
  - [ ] `McpTool.toLLMTool (serverPrefix : String) : LLM.Tool`
  - [ ] Namespace tool names: `"mcp__serverName__toolName"` to avoid collisions
- [ ] Implement `McpToolRegistry.execute (qualifiedName : String) (argsJson : String) : IO String`
  - [ ] Parse qualified name to extract server + tool
  - [ ] Parse args JSON
  - [ ] Call `McpClient.callTool`
  - [ ] Render `ToolResult` to observation string (concatenate text content, note errors)

**Tested deliverable**: Registry with one server. `allTools` returns `LLM.Tool` list. `execute "mcp__srv__toolName" args` returns the tool's text output.

---

## Milestone 6: Agent Integration

Wire MCP tools into the ReAct agent loop so the LLM can discover and call them.

- [ ] Extend agent config to accept MCP server specifications: `mcpServers : List McpServerConfig`
  - [ ] `McpServerConfig`: `name`, `command`, `args`, `env` (optional)
- [ ] On agent startup (`runAgent`):
  - [ ] Connect to all configured MCP servers
  - [ ] Collect their tools via `allTools`
  - [ ] Merge with built-in tools into the `LLM.Tool` list sent to the model
- [ ] Extend `toolCallToAction` to recognize `mcp__*` prefixed tool names:
  - [ ] Route to `McpToolRegistry.execute` instead of `Tools.execute`
- [ ] Extend `Tools.execute` (or add parallel path) for MCP tool dispatch
- [ ] On agent shutdown: disconnect all MCP clients
- [ ] Handle MCP server crashes gracefully: catch IO errors, report as tool error observation

**Tested deliverable**: Full end-to-end: configure agent with an MCP server, agent receives a task, LLM sees MCP tools in its tool list, calls one, gets result back, uses it to complete the task.

---

## Milestone 7: Hardening

- [ ] Request timeout with configurable duration (default 30s)
- [ ] Reconnection: if a server dies mid-session, attempt one reconnect before failing
- [ ] `notifications/tools/list_changed` handling: re-fetch tools when server sends this
- [ ] Structured error types: distinguish transport errors, protocol errors, tool execution errors
- [ ] Logging: log MCP traffic when verbose mode is on
- [ ] Multiple concurrent MCP servers: test with 2+ servers, verify no name collisions

**Tested deliverable**: Agent survives MCP server restart, handles tool list changes, logs all MCP traffic in verbose mode.

---

## File Layout

```
ReActAgent/
  MCP/
    JsonRpc.lean        -- Milestone 1: JSON-RPC types and serialization
    Transport.lean      -- Milestone 1: StdioTransport (spawn + read/write)
    Client.lean         -- Milestones 2-4: McpClient (lifecycle + tools/list + tools/call)
    Registry.lean       -- Milestone 5: McpToolRegistry (multi-server, name mapping)
  MCP.lean              -- Re-export module
Main.lean               -- Milestone 6: Integration changes
```

## Non-Goals (for this plan)

- HTTP/SSE transport (stdio only)
- Auth / OAuth
- Resources, Prompts, Sampling, Completions (tools only)
- Server implementation (client only)
- Formal verification of MCP protocol conformance
