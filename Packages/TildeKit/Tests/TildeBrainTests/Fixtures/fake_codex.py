"""Plays `codex app-server` for tilde's own threads, offline. Every request is logged to $FAKE_OUT as a
JSON line. $FAKE_SCENARIO says how turns go:

- answer: each turn streams "Hello once." and completes.
- retry: the same, after an error Codex says it will retry.
- duplicate-completion: the same, with the completion sent twice.
- error, notice-only, error-exit, error-drop: each turn fails as a misconfigured gateway does: the error
  on the completion too, or only before it; then the process exits, or exits instead of completing.
- cancel: turns run until they're interrupted.
- quiet: turns go quiet, as on a connection that never answers, until interrupted; input steered
  into one is answered ("You said: ...") and completes it.
- steer-receipt: steered input calls the `fixture_effect` tool, and the turn completes with the tool's
  result before the steer itself is acknowledged, which waits for the file $FAKE_OUT.release.

A turn whose input says BARRIER is answered "Done." whatever the scenario, so a test can tell when
everything before it has been seen.
"""
import json
import os
import sys
import time

out = os.environ["FAKE_OUT"]
scenario = os.environ["FAKE_SCENARIO"]
gateway_error = '{"status":"failure","message":"Passthrough target requires a provider. Provide x-portkey-provider header or model in the request body."}'
turns = 0
held_steer = None


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def reply(message, result):
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def turn_id():
    return f"turn-{turns}"


def complete(status="completed", error=None):
    turn = {"id": turn_id(), "status": status}
    if error:
        turn["error"] = {"message": error}
    notify("turn/completed", {"turn": turn})


def answer(text):
    item = {"id": f"message-{turns}", "type": "agentMessage", "text": text}
    notify("item/completed", {"turnId": turn_id(), "item": item})
    complete()


def stream_answer():
    item = {"id": f"message-{turns}", "type": "agentMessage", "text": "Hello once."}
    notify("item/started", {"turnId": turn_id(), "item": {**item, "text": ""}})
    for delta in ("Hello ", "once."):
        notify("item/agentMessage/delta", {"turnId": turn_id(), "itemId": item["id"], "delta": delta})
    notify("item/completed", {"turnId": turn_id(), "item": item})
    complete()


def start_turn(message, text):
    global turns
    turns += 1
    reply(message, {"turn": {"id": turn_id()}})
    notify("turn/started", {"turn": {"id": turn_id()}})
    if "BARRIER" in text:
        return answer("Done.")
    if scenario in ("error", "notice-only", "error-exit", "error-drop"):
        notify("error", {"turnId": turn_id(), "willRetry": False, "error": {"message": gateway_error}})
        if scenario == "error-drop":
            sys.exit(1)
        complete("failed", None if scenario == "notice-only" else gateway_error)
        if scenario == "error-exit":
            sys.exit(1)
    elif scenario in ("answer", "retry", "duplicate-completion"):
        if scenario == "retry":
            notify("error", {"turnId": turn_id(), "willRetry": True, "error": {"message": "Temporary failure"}})
        stream_answer()
        if scenario == "duplicate-completion":
            complete()


for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method is None:
        # The tool's result: the turn it was called in is done before its steer is acknowledged.
        if held_steer and message.get("id") == "effect":
            answer("Applied it.")
            while not os.path.exists(out + ".release"):
                time.sleep(0.01)
            reply(held_steer, {})
            held_steer = None
        continue
    if "id" not in message:
        continue
    with open(out, "a") as log:
        log.write(json.dumps(message) + "\n")
    text = "\n".join(item.get("text", "") for item in message.get("params", {}).get("input", []))
    if method == "thread/start":
        reply(message, {"thread": {"id": "thread-1"}})
    elif method == "config/read":
        reply(message, {"config": {}})
    elif method == "turn/start":
        start_turn(message, text)
    elif method == "turn/interrupt":
        reply(message, {})
        complete("interrupted")
    elif method == "turn/steer" and scenario == "steer-receipt":
        held_steer = message
        send({"jsonrpc": "2.0", "id": "effect", "method": "item/tool/call",
              "params": {"tool": "fixture_effect", "arguments": {"instruction": text}}})
    elif method == "turn/steer" and scenario == "quiet":
        reply(message, {})
        answer("You said: " + text.split("\n")[-1])
    else:
        reply(message, {})
