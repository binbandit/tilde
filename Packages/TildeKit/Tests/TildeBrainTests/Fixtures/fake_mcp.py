"""A stdio MCP server with one annotated read, one plain read, and two writes.

Each call it runs is appended to $FAKE_MCP_LOG, so a test can see what was allowed to run.
"""
import json
import os
import sys

LOG = os.environ.get("FAKE_MCP_LOG", os.devnull)
NO_ARGS = {"type": "object", "properties": {}}
TOOLS = [
    {"name": "list_notes", "description": "List notes.", "inputSchema": NO_ARGS, "annotations": {"readOnlyHint": True}},
    {"name": "get_note", "description": "Get a note by id.", "inputSchema": {"type": "object", "properties": {"id": {"type": "string"}}}},
    {"name": "create_note", "description": "Create a note.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
    {"name": "save_note", "description": "Overwrite a note.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
]


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    method, request = message.get("method"), message.get("id")
    if method == "initialize":
        version = message["params"].get("protocolVersion", "2025-06-18")
        result = {"protocolVersion": version, "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        send({"jsonrpc": "2.0", "id": request, "result": result})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": request, "result": {"tools": TOOLS}})
    elif method == "tools/call":
        name = message["params"]["name"]
        with open(LOG, "a") as log:
            log.write(name + "\n")
        send({"jsonrpc": "2.0", "id": request, "result": {"content": [{"type": "text", "text": name + " ok"}]}})
    elif request is not None:
        send({"jsonrpc": "2.0", "id": request, "result": {}})
