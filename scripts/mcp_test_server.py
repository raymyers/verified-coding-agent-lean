#!/usr/bin/env python3
"""Minimal MCP test server over stdio. No dependencies."""

import json
import sys

def respond(id, result):
    msg = {"jsonrpc": "2.0", "id": id, "result": result}
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def respond_error(id, code, message):
    msg = {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

TOOLS = [
    {
        "name": "echo",
        "description": "Echoes back the input message",
        "inputSchema": {
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "Message to echo"}
            },
            "required": ["message"]
        }
    },
    {
        "name": "add",
        "description": "Adds two numbers",
        "inputSchema": {
            "type": "object",
            "properties": {
                "a": {"type": "number", "description": "First number"},
                "b": {"type": "number", "description": "Second number"}
            },
            "required": ["a", "b"]
        }
    }
]

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue

    method = msg.get("method", "")
    id = msg.get("id")

    # Notifications (no id) — just ack silently
    if id is None:
        continue

    if method == "initialize":
        respond(id, {
            "protocolVersion": "2025-03-26",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "test-server", "version": "0.1.0"}
        })
    elif method == "tools/list":
        respond(id, {"tools": TOOLS})
    elif method == "tools/call":
        params = msg.get("params", {})
        name = params.get("name", "")
        args = params.get("arguments", {})
        if name == "echo":
            text = args.get("message", "")
            respond(id, {
                "content": [{"type": "text", "text": text}],
                "isError": False
            })
        elif name == "add":
            a = args.get("a", 0)
            b = args.get("b", 0)
            respond(id, {
                "content": [{"type": "text", "text": str(a + b)}],
                "isError": False
            })
        else:
            respond_error(id, -32602, f"Unknown tool: {name}")
    else:
        respond_error(id, -32601, f"Method not found: {method}")
