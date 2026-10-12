"""Offline Codex peer. Test-owned files control completion and an initial send failure."""
import json
import os
from pathlib import Path
import sys
import threading
import time

root = Path(os.environ["FAKE_CONTROL"])
lock = threading.Lock()


def send(message):
    with lock:
        print(json.dumps(message), flush=True)


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def finish_when_released(number, rejected):
    marker = root / f"complete-{number}"
    while not marker.exists():
        time.sleep(0.005)
    if rejected:
        os._exit(1)
    notify("item/completed", {"item": {
        "id": f"message-{number}", "type": "agentMessage", "text": f"Reply {number}"}})
    notify("turn/completed", {"turn": {"id": f"turn-{number}", "status": "completed"}})


for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message or "method" not in message:
        continue
    with (root / "requests.jsonl").open("a") as log:
        log.write(json.dumps(message) + "\n")
    method = message["method"]
    result = {}
    if method == "thread/start":
        result = {"thread": {"id": "fixture-thread"}}
    elif method == "config/read":
        result = {"config": {}}
    elif method == "turn/start":
        count_file = root / "turn-count"
        number = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(number))
        rejected = os.environ["FAKE_REJECT_FIRST"] == "1" and number == 1
        if rejected:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {
                "code": -32000, "message": "Fixture rejected this send"}})
        else:
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"turn": {"id": f"turn-{number}"}}})
            notify("turn/started", {"turn": {"id": f"turn-{number}"}})
        threading.Thread(target=finish_when_released, args=(number, rejected), daemon=True).start()
        continue
    send({"jsonrpc": "2.0", "id": message["id"], "result": result})
