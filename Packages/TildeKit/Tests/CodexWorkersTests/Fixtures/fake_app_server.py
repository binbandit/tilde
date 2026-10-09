"""Plays `codex app-server` just far enough to ask three MCP elicitations.

After the handshake it asks about a tool named in `_meta`, one named only in the message, and a
form that isn't an approval at all, then writes the client's answers to $FAKE_OUT and exits.
"""
import json
import os
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    return json.loads(sys.stdin.readline())


hello = read()
send({"jsonrpc": "2.0", "id": hello["id"], "result": {}})
read()  # initialized

asks = [
    {"serverName": "linear", "mode": "form", "message": "Allow Linear to read an issue?",
     "_meta": {"codex_approval_kind": "mcp_tool_call", "tool_name": "get_issue"}, "requestedSchema": {}},
    {"serverName": "linear", "mode": "form", "message": 'Allow the linear MCP server to run tool "save_issue"?',
     "_meta": {"codex_approval_kind": "mcp_tool_call"}, "requestedSchema": {}},
    {"serverName": "linear", "mode": "form", "message": "Pick a team", "_meta": None, "requestedSchema": {}},
]
for number, params in enumerate(asks):
    send({"jsonrpc": "2.0", "id": 100 + number, "method": "mcpServer/elicitation/request", "params": params})

answers = {}
while len(answers) < len(asks):
    message = read()
    if message.get("id") in (100, 101, 102):
        answers[message["id"]] = message["result"]["action"]
with open(os.environ["FAKE_OUT"], "w") as out:
    json.dump([answers[100 + number] for number in range(len(asks))], out)
