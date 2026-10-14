"""Offline Codex peer: completes each turn before replying to its turn/start, and replays an older
completion when a thread starts. It rejects turn/steer, which no test here should need."""
import json
import os
import sys

log = open(os.environ["FAKE_LOG"], "a", buffering=1)


def send(message):
    print(json.dumps(message), flush=True)


def event(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def complete(turn, text):
    event("item/completed", {"item": {"id": "message-" + turn, "type": "agentMessage", "text": text}})
    event("turn/completed", {"turn": {"id": turn, "status": "completed"}})


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if "id" not in request or method is None:
        continue
    log.write(method + "\n")
    result = {}
    if method in ("thread/start", "thread/resume"):
        complete("old", "previous completion")
        result = {"thread": {"id": "offline-thread"}}
    elif method == "turn/start":
        text = request["params"]["input"][0]["text"]
        event("turn/started", {"turn": {"id": "new-turn"}})
        complete("new-turn", "finished: " + text)
        result = {"turn": {"id": "new-turn"}}
    elif method == "turn/steer":
        send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32600, "message": "completed turn was resurrected"}})
        continue
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})
