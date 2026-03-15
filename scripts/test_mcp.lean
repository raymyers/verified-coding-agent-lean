/-
# MCP Client Integration Test

Tests the full MCP client stack against scripts/mcp_test_server.py.
Run: lake env lean --run scripts/test_mcp.lean
-/
import ReActAgent.MCP

open MCP

def main : IO Unit := do
  IO.println "=== MCP Client Integration Test ==="

  -- [1] Direct client: connect, list, call
  IO.println "\n[1] Direct client test..."
  let client ← McpClient.connect "python3" #["scripts/mcp_test_server.py"]
  IO.println s!"  Server: {client.serverInfo.name} v{client.serverInfo.version}"
  IO.println s!"  Protocol: {client.protocolVersion}"
  let tools ← client.listTools
  IO.println s!"  Tools ({tools.length}): {tools.map (·.name)}"
  let r1 ← client.callTool "echo" (Lean.Json.mkObj [("message", "hello from Lean!")])
  assert! r1.toObservation == "hello from Lean!"
  IO.println s!"  echo: {r1.toObservation}"
  let r2 ← client.callTool "add" (Lean.Json.mkObj [("a", (17 : Int)), ("b", (25 : Int))])
  assert! r2.toObservation == "42"
  IO.println s!"  add(17,25): {r2.toObservation}"
  client.disconnect

  -- [2] Registry: multi-server routing
  IO.println "\n[2] Registry test..."
  let reg ← McpToolRegistry.create
  reg.addServer { name := "srv", command := "python3", args := #["scripts/mcp_test_server.py"] }
  let allTools ← reg.allTools
  assert! allTools.length == 2
  assert! allTools.any (·.1 == "mcp__srv__echo")
  assert! allTools.any (·.1 == "mcp__srv__add")
  IO.println s!"  Qualified names: {allTools.map (·.1)}"
  let obs ← reg.execute "mcp__srv__echo" "{\"message\": \"via registry\"}"
  assert! obs == "via registry"
  IO.println s!"  execute: {obs}"
  reg.disconnectAll

  -- [3] Name parsing
  IO.println "\n[3] Name parsing..."
  assert! isMcpTool "mcp__srv__echo" == true
  assert! isMcpTool "bash" == false
  assert! parseQualifiedName "mcp__srv__echo" == some ("srv", "echo")
  assert! parseQualifiedName "mcp__srv__tool__with__underscores" == some ("srv", "tool__with__underscores")
  assert! parseQualifiedName "bash" == none
  IO.println "  All name parsing assertions passed"

  IO.println "\n=== All tests passed ==="
