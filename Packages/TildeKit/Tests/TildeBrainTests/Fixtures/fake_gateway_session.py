"""Deterministic Codex notifications from a gateway, without HTTP or credentials."""
import json
import os
import sys


def send(method, params):
    print(json.dumps({"jsonrpc": "2.0", "method": method, "params": params}), flush=True)


def reply(message, result):
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)


error = '{"status":"failure","message":"Passthrough target requires a provider. Provide x-portkey-provider header or model in the request body."}'
turns = 0
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if "id" not in message:
        continue
    with open(os.environ["FAKE_OUT"], "a") as log:
        log.write(json.dumps(message) + "\n")
    if method == "config/read":
        reply(message, {"config": {}})
    elif method == "thread/start":
        reply(message, {"thread": {"id": "thread-1"}})
    elif method == "turn/start":
        turns += 1
        turn = f"turn-{turns}"
        reply(message, {"turn": {"id": turn}})
        send("turn/started", {"turn": {"id": turn}})
        scenario = os.environ["FAKE_SCENARIO"]
        if scenario in ("error", "notice-only", "error-exit", "error-drop"):
            send("error", {"turnId": turn, "willRetry": False, "error": {"message": error}})
            if scenario == "error-drop":
                sys.exit(1)
            result = {"id": turn, "status": "failed"}
            if scenario != "notice-only":
                result["error"] = {"message": error}
            send("turn/completed", {"turn": result})
            if scenario == "error-exit":
                sys.exit(1)
        elif scenario != "cancel":
            if scenario == "retry":
                send("error", {"turnId": turn, "willRetry": True, "error": {"message": "Temporary failure"}})
            item = {"id": f"message-{turns}", "type": "agentMessage", "text": "Hello once."}
            send("item/started", {"turnId": turn, "item": {**item, "text": ""}})
            for delta in ("Hello ", "once."):
                send("item/agentMessage/delta", {"turnId": turn, "itemId": item["id"], "delta": delta})
            send("item/completed", {"turnId": turn, "item": item})
            send("turn/completed", {"turn": {"id": turn, "status": "completed"}})
            if scenario == "duplicate-completion":
                send("turn/completed", {"turn": {"id": turn, "status": "completed"}})
    elif method == "turn/interrupt":
        reply(message, {})
        send("turn/completed", {"turn": {"id": f"turn-{turns}", "status": "interrupted"}})
    else:
        reply(message, {})
