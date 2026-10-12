#!/usr/bin/env python3
"""An offline Codex protocol peer that records inputs and completes each turn."""
import json
import os
import sys

log = open(os.environ["FAKE_OUT"], "a", buffering=1)


def send(message):
    print(json.dumps(message), flush=True)


for line in sys.stdin:
    message = json.loads(line)
    if "method" not in message or "id" not in message:
        continue
    log.write(json.dumps(message) + "\n")
    method = message["method"]
    if method == "thread/start":
        result = {"thread": {"id": "offline-thread"}}
    elif method == "config/read":
        result = {"config": {}}
    elif method == "turn/start":
        result = {"turn": {"id": "offline-turn"}}
    else:
        result = {}
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})
    if method == "turn/start":
        send({"jsonrpc": "2.0", "method": "turn/started", "params": {"turn": {"id": "offline-turn"}}})
        send({"jsonrpc": "2.0", "method": "item/completed", "params": {
            "item": {"id": "offline-message", "type": "agentMessage", "text": "Read local context."}}})
        send({"jsonrpc": "2.0", "method": "turn/completed", "params": {
            "turn": {"id": "offline-turn", "status": "completed"}}})
