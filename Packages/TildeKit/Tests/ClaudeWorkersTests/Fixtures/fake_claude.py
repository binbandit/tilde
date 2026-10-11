"""Plays `claude -p` with stream-json as Claude Code 2.1.296 does with a plugin that runs a local command
at startup: the command runs under its own id and reports its own `result` (naming that id) before the
turn tilde sent has even started.
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
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "result": "slopothon: SLOPOTHON",
      "local_command": "custom", "user_message_uuid": "plugin-command"})
send({"type": "command_lifecycle", "command_uuid": "plugin-command", "state": "completed"})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "started"})
send({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": "done"}]}})
send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": "done", "user_message_uuid": turn})
send({"type": "command_lifecycle", "command_uuid": turn, "state": "completed"})
sys.stdin.readline()  # until tilde closes stdin
