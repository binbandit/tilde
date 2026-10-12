"""Offline peer: execute tools and finish before acknowledging steer RPCs."""
import json
import os
from pathlib import Path
import sys
import threading
import time

root = Path(os.environ["FAKE_CONTROL"])
scenario = os.environ["FAKE_SCENARIO"]
expected = 1 if scenario == "single" else 2
lock = threading.Lock()
turn = 0
steers = []
effects_pending = {}
initial_effects = 0
completed_first = False


def send(value):
    with lock:
        print(json.dumps(value), flush=True)


def reply(message, rejected=False):
    response = {"jsonrpc": "2.0", "id": message["id"]}
    if rejected:
        response["error"] = {"code": -32000, "message": "Fixture rejected this steer"}
    else:
        response["result"] = {}
    send(response)


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def complete(number, text):
    notify("item/completed", {"item": {"id": f"answer-{number}", "type": "agentMessage", "text": text}})
    notify("turn/completed", {"turn": {"id": f"turn-{number}", "status": "completed"}})
    (root / f"completed-{number}").touch()


def wait_marker(name):
    while not (root / name).exists():
        time.sleep(0.005)


def acknowledge_later(message, index, rejected):
    wait_marker(f"release-{index}")
    reply(message, rejected)


def complete_later(number):
    wait_marker(f"complete-{number}")
    complete(number, f"Reply {number}")


def effect(number, text):
    call_id = f"effect-{len(effects_pending)}-{number}-{time.monotonic_ns()}"
    effects_pending[call_id] = number
    send({"jsonrpc": "2.0", "id": call_id, "method": "item/tool/call", "params": {
        "tool": "fixture_effect", "arguments": {"instruction": text}}})


def finish_first_if_ready():
    global completed_first
    if len(steers) == expected and not effects_pending and not completed_first:
        completed_first = True
        complete(1, f"Applied {initial_effects} effect(s).")


for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") in effects_pending and "method" not in message:
        number = effects_pending.pop(message["id"])
        if number == 1:
            finish_first_if_ready()
        else:
            complete(number, f"Retried effect in turn {number}")
        continue
    if "id" not in message or "method" not in message:
        continue
    method = message["method"]
    text = "\n".join(item.get("text", "") for item in message.get("params", {}).get("input", []))
    with (root / "requests.jsonl").open("a") as log:
        log.write(json.dumps({"method": method, "text": text}) + "\n")
    if method == "thread/start":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"thread": {"id": "fixture-thread"}}})
    elif method == "config/read":
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"config": {}}})
    elif method == "turn/start":
        turn += 1
        send({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": f"turn-{turn}"}}})
        notify("turn/started", {"turn": {"id": f"turn-{turn}"}})
        if "STEER_EFFECT" in text:
            effect(turn, text)
        elif turn > 1:
            threading.Thread(target=complete_later, args=(turn,), daemon=True).start()
    elif method == "turn/steer" and turn == 1:
        steers.append(message)
        index = len(steers)
        rejected = scenario == "reject" and index == 2
        if not rejected:
            initial_effects += 1
            effect(turn, text)
        threading.Thread(target=acknowledge_later, args=(message, index, rejected), daemon=True).start()
        finish_first_if_ready()
    else:
        reply(message)
