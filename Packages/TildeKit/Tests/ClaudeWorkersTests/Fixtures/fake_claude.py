"""Plays `claude -p` with stream-json, as it behaves with a plugin that runs a local command at
startup: that command reports its own `result` before the turn tilde sent has even started.
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
send({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": "done"}]}})
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "done"})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "completed"})
sys.stdin.readline()  # until tilde closes stdin
