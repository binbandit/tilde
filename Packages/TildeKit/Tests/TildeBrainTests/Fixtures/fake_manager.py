"""Plays `codex app-server` for the manager, with the connection trouble seen in real use.

The first turn hangs: Codex says nothing after `turn/started`, as when a sampling request sits on a
connection that never answers, until it's interrupted. Later turns wait for steered input and
answer it. Every request's method goes to $FAKE_OUT, one per line.
"""
import json
import os
import sys

log = open(os.environ["FAKE_OUT"], "w", buffering=1)


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(message, result):
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})


def started(turn):
    send({"jsonrpc": "2.0", "method": "turn/started", "params": {"turn": {"id": turn}}})


def completed(turn, status):
    send({"jsonrpc": "2.0", "method": "turn/completed", "params": {"turn": {"id": turn, "status": status}}})


turns = 0
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method is None or "id" not in message:
        continue  # notifications, and answers to requests of ours
    log.write(method + "\n")
    if method == "thread/start":
        reply(message, {"thread": {"id": "thread-1"}})
    elif method == "config/read":
        reply(message, {"config": {}})
    elif method == "turn/start":
        turns += 1
        turn = f"turn-{turns}"
        reply(message, {"turn": {"id": turn}})
        started(turn)  # and then, for the first turn, nothing
    elif method == "turn/interrupt":
        reply(message, {})
        completed(f"turn-{turns}", "interrupted")
    elif method == "turn/steer":
        reply(message, {})
        said = message["params"]["input"][0]["text"].split("\n")[-1]
        item = {"id": "msg-1", "type": "agentMessage", "text": f"You said: {said}"}
        send({"jsonrpc": "2.0", "method": "item/completed", "params": {"item": item}})
        completed(f"turn-{turns}", "completed")
    else:
        reply(message, {})
