"""Plays `claude -p` with stream-json, as it behaves with plugins that run local commands: one at
startup, under its own id, and one that answers tilde's message locally (Claude Code 2.1.296).
Each reports its own `result` before the model's turn has even started.
"""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    return json.loads(sys.stdin.readline())


hello = read()
send({"type": "control_response", "response": {"subtype": "success", "request_id": hello["request_id"], "response": {}}})
turn = read()["uuid"]

send({"type": "command_lifecycle", "command_uuid": "plugin-command", "state": "started"})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "queued"})
send({"type": "system", "subtype": "init", "session_id": "s", "model": "m"})
send({"type": "assistant", "parent_tool_use_id": None, "local_command_run": {"command": "slopothon"},
      "message": {"content": [{"type": "text", "text": "slopothon: SLOPOTHON"}]}})
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": "slopothon: SLOPOTHON"})
send({"type": "command_lifecycle", "command_uuid": "plugin-command", "state": "completed"})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "started"})
send({"type": "assistant", "parent_tool_use_id": None, "local_command_run": {"command": "slopothon", "args": ""},
      "message": {"model": "<synthetic>", "content": [{"type": "text", "text": "slopothon: SLOPOTHON"}]}})
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": "slopothon: SLOPOTHON",
      "local_command": "custom", "origin": {"kind": "plugin", "name": "slopothon"}})
send({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": "done"}]}})
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "done"})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "completed"})
sys.stdin.readline()  # until tilde closes stdin
