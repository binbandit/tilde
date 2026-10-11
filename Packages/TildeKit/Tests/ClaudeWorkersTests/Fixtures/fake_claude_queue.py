"""Plays `claude -p` with stream-json the way Claude Code 2.1.296 handles a message sent mid-turn: it
queues it and runs it as a turn of its own after the current one, each `result` naming the message it
answered (and `queued_turn_count` saying 0 throughout, so it can't be relied on).
"""
import json
import sys
import time


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    return json.loads(sys.stdin.readline())


hello = read()
send({"type": "control_response", "response": {"subtype": "success", "request_id": hello["request_id"], "response": {}}})
send({"type": "system", "subtype": "init", "session_id": "s", "model": "m"})
first = read()
time.sleep(0.3)  # the follow-up arrives while this turn is still going
second = read()
for message in (first, second):
    text = message["message"]["content"]
    send({"type": "assistant", "parent_tool_use_id": None, "message": {"content": [{"type": "text", "text": f"did: {text}"}]}})
    send({"type": "result", "subtype": "success", "is_error": False, "num_turns": 1, "result": f"did: {text}",
          "user_message_uuid": message["uuid"]})
sys.stdin.readline()
