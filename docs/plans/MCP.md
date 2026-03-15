# MCP Client Implementation Plan

Implement an MCP (Model Context Protocol) client in Lean that enables the ReAct agent to
discover and invoke tools hosted by external MCP servers over stdio transport.

**Spec version**: 2025-03-26
**Scope**: stdio transport only, tools capability only, no auth
**Goal**: Agent can use MCP server tools alongside built-in tools (bash, file_editor, etc.)

---

## Milestone 1: JSON-RPC Transport Layer

Standalone JSON-RPC 2.0 over stdio — no MCP-specific logic yet.

- [x] Re-use `Lean.Data.JsonRpc.Message` (Request, Response, Notification, ErrorCode)
- [x] Add MCP helpers: `mkRequest`, `mkNotification`, `getResult`, `getResponseId`, `isResponse`
- [x] Create `StdioTransport` that wraps a child process handle:
  - [x] `send (msg : Message) : IO Unit` — write JSON + newline to child stdin
  - [x] `recv : IO Message` — read one newline-delimited JSON from child stdout
- [x] Implement monotonic request ID counter in `StdioTransport`
- [x] `request` method: send request, skip interleaved notifications, return matching response
- [x] `notify` method: send notification (no response expected)
- [ ] Write `#eval` tests: round-trip serialize/deserialize for each message type

**Tested deliverable**: Can send a JSON-RPC request to a subprocess and read a JSON-RPC response back. Verified with a trivial echo server script.

---

## Milestone 2: MCP Lifecycle (Initialize / Shutdown)

Implement the MCP handshake on top of the transport.

- [x] Define `ServerCapabilities` — `tools : Option ToolsCap` where `ToolsCap` has `listChanged : Bool`
- [x] Define `ServerInfo` — `name : String`, `version : String`
- [x] Implement `McpClient.connect`:
  - [x] Spawn subprocess, create transport
  - [x] Send `initialize` request with `protocolVersion = "2025-03-26"`, `clientInfo`, `capabilities = {}`
  - [x] Parse response: extract `protocolVersion`, `capabilities`, `serverInfo`
  - [x] Send `notifications/initialized` notification
  - [x] Return connected `McpClient`
- [x] Implement `McpClient.disconnect`: close child stdin, wait for process
- [ ] Test: connect to an MCP server, print server info, cleanly shut down

**Tested deliverable**: `McpClient.connect` launches an MCP server, completes handshake, prints server info, then cleanly shuts down.

---

## Milestone 3: Tool Discovery (tools/list)

- [x] Define `McpTool` structure: `name : String`, `description : String`, `inputSchema : Json`
- [x] Implement `McpClient.listTools : IO (List McpTool)`
  - [x] Send `tools/list` request
  - [x] Parse response: extract `tools` array, map to `McpTool`
- [ ] Implement `McpClient.listToolsAll : IO (List McpTool)` with cursor-based pagination
  - [ ] Loop while `nextCursor` is present
- [ ] Test: connect, list tools, print name + description for each

**Tested deliverable**: Connect to an MCP server, list its tools, print name + description for each.

---

## Milestone 4: Tool Invocation (tools/call)

- [x] Define `ToolContent` inductive: `text` | `image` | `audio` | `resource`
- [x] Define `ToolResult` structure: `content : List ToolContent`, `isError : Bool`
- [x] Implement `McpClient.callTool (name : String) (arguments : Json) : IO ToolResult`
  - [x] Send `tools/call` request with `name` and `arguments`
  - [x] Parse response: extract `content` array and `isError`
  - [x] Map content items to `ToolContent` values
  - [x] Handle JSON-RPC error responses (throw)
- [x] Implement `ToolResult.toObservation` — render to plain string
- [ ] Add timeout support: configurable per-call timeout with cancellation
- [ ] Test: call a tool, verify success and isError cases

**Tested deliverable**: Call a tool on a live MCP server, receive and display the text result.

---

## Milestone 5: MCP Tool Registry

Bridge between MCP servers and the agent's tool system.

- [x] Define `McpToolRegistry` that manages multiple `McpClient` connections
  - [x] `addServer` — connect and list tools
  - [x] `removeServer` — disconnect and remove
  - [x] `allTools` — returns `(qualifiedName, McpTool)` pairs
- [x] Namespace tool names: `"mcp__serverName__toolName"` via `qualifiedName`/`parseQualifiedName`
- [x] Implement `McpToolRegistry.execute (qualifiedName : String) (argsJson : String) : IO String`
  - [x] Parse qualified name to extract server + tool
  - [x] Parse args JSON
  - [x] Call `McpClient.callTool`
  - [x] Render `ToolResult` to observation string
- [x] `disconnectAll` — clean shutdown of all servers
- [ ] Test: registry with one server, `allTools` returns tools, `execute` returns output

**Tested deliverable**: Registry with one server. `execute "mcp__srv__toolName" args` returns the tool's text output.

---

## Milestone 6: Agent Integration

Wire MCP tools into the ReAct agent loop so the LLM can discover and call them.

- [x] Add `mcpServers : List McpServerConfig` to `CLIConfig`
- [x] On agent startup (`runReactMode`):
  - [x] Connect to all configured MCP servers via registry
  - [x] Collect their tools via `allTools`
  - [x] Convert `McpTool` → `LLM.ToolFunction` via `mcpToolToLLM`
  - [x] Merge with built-in tools into the tool list sent to the model
- [x] Extend `toolCallToAction` to recognize `mcp__*` prefixed tool names
- [x] Route MCP tool calls through `McpToolRegistry.execute` in the agent loop
- [x] On agent shutdown: `mcpRegistry.disconnectAll`
- [ ] CLI flag to specify MCP servers (e.g. `--mcp-server name:command:args`)
- [ ] Handle MCP server crashes gracefully: catch IO errors, report as tool error observation
- [ ] End-to-end test with a real MCP server

**Tested deliverable**: Full end-to-end: configure agent with an MCP server, LLM sees MCP tools, calls one, gets result back.

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
    JsonRpc.lean        -- Milestone 1: JSON-RPC helpers on top of Lean.Data.JsonRpc
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
