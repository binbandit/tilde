"""Offline Codex peer: completes turns before acknowledging turn/start."""
import json
import os
import sys
import time

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
        # A previously buffered completion belongs before the next submission marker, even
        # if nobody consumes the worker event stream until start() has returned.
        complete("old", "previous completion")
        result = {"thread": {"id": "offline-thread"}}
    elif method == "turn/start":
        text = request["params"]["input"][0]["text"]
        event("turn/started", {"turn": {"id": "new-turn"}})
        complete("new-turn", "finished: " + text)
        if text == "hold":
            deadline = time.monotonic() + 15
            while not os.path.exists(os.environ["FAKE_RELEASE"]):
                if time.monotonic() >= deadline:
                    raise RuntimeError("test did not release the response")
                time.sleep(0.01)
        result = {"turn": {"id": "new-turn"}}
    elif method == "turn/steer":
        send({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32600, "message": "completed turn was resurrected"}})
        continue
    send({"jsonrpc": "2.0", "id": request["id"], "result": result})
