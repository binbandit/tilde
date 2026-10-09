"""A scripted ACP agent for tilde's tests.

The last line of each prompt names a scenario. Every message tilde sends is
appended to $FAKE_LOG as one JSON line, so tests can check tilde's replies.
$FAKE_LOAD=1 advertises session/load (which replays one old message; "gone" is unknown).
"""
import json
import os
import sys

LOG = open(os.environ["FAKE_LOG"], "a", buffering=1)
OPTIONS = [
    {"optionId": "allow", "name": "Allow once", "kind": "allow_once"},
    {"optionId": "always", "name": "Always allow", "kind": "allow_always"},
    {"optionId": "reject", "name": "Reject", "kind": "reject_once"},
]
state = {"cwd": "/", "cancelled": False, "next_id": 100}


def model_option(current):
    return {
        "id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": current,
        "options": [{"value": "fast", "name": "Fast"}, {"value": "smart", "name": "Smart"}],
    }


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def read():
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    message = json.loads(line)
    LOG.write(json.dumps(message, sort_keys=True) + "\n")
    return message


def call(method, params):
    """Sends a request to tilde and waits for its response, noting any cancel on the way."""
    state["next_id"] += 1
    request_id = state["next_id"]
    send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
    while True:
        message = read()
        if message.get("id") == request_id and "method" not in message:
            return message
        if message.get("method") == "session/cancel":
            state["cancelled"] = True


def update(sid, body):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": body}})


def say(sid, text, message_id):
    update(sid, {"sessionUpdate": "agent_message_chunk", "messageId": message_id, "content": {"type": "text", "text": text}})


def ask_permission(sid, tool_call_id, kind, **fields):
    tool_call = {"toolCallId": tool_call_id, "title": kind, "kind": kind, "status": "pending", **fields}
    response = call("session/request_permission", {"sessionId": sid, "toolCall": tool_call, "options": OPTIONS})
    outcome = response["result"]["outcome"]
    return outcome.get("optionId", outcome["outcome"])


def run(sid, prompt):
    scenario = prompt.strip().splitlines()[-1]
    outside = os.path.join(os.path.dirname(state["cwd"]), "outside.txt")

    if scenario == "work":
        update(sid, {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "hmm"}})
        say(sid, "Let me ", "m1")
        say(sid, "build it.", "m1")
        update(sid, {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "bash", "kind": "execute", "status": "pending", "rawInput": {}})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "in_progress", "rawInput": {"command": "swift build"}})
        update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
        update(sid, {"sessionUpdate": "plan", "entries": [
            {"content": "Build", "priority": "high", "status": "completed"},
            {"content": "Write the summary", "priority": "low", "status": "in_progress"},
        ]})
        say(sid, "Built.", "m2")
        return "end_turn"

    if scenario == "permissions":
        outcomes = [
            ask_permission(sid, "p1", "execute", rawInput={"command": "swift test"}),
            ask_permission(sid, "p2", "execute", rawInput={"command": "git push origin main"}),
            ask_permission(sid, "p3", "edit", locations=[{"path": outside}]),
        ]
        say(sid, "outcomes: " + ", ".join(outcomes), "m1")
        return "end_turn"

    if scenario == "files":
        inside = os.path.join(state["cwd"], "notes", "inside.txt")
        wrote = call("fs/write_text_file", {"sessionId": sid, "path": inside, "content": "one\ntwo\nthree\n"})
        read_back = call("fs/read_text_file", {"sessionId": sid, "path": inside, "line": 2, "limit": 1})
        refused = call("fs/write_text_file", {"sessionId": sid, "path": outside, "content": "nope"})
        say(sid, "inside %s; read %s; outside %s" % (
            "error" if "error" in wrote else "ok",
            read_back["result"]["content"],
            "refused" if "error" in refused else "written",
        ), "m1")
        return "end_turn"

    if scenario == "question":
        response = call("elicitation/create", {
            "sessionId": sid, "mode": "form", "message": "How should the nav behave?",
            "requestedSchema": {"type": "object", "required": ["nav"], "properties": {"nav": {
                "type": "string", "oneOf": [{"const": "sticky", "title": "Sticky"}, {"const": "scroll", "title": "Scroll away"}],
            }}},
        })["result"]
        say(sid, "nav: " + (response["content"]["nav"] if response["action"] == "accept" else response["action"]), "m1")
        return "end_turn"

    if scenario == "hold":
        ask_permission(sid, "h1", "execute", rawInput={"command": "git push origin main"})
        say(sid, "held", "m1")
        return "end_turn"

    if scenario == "silent":
        ask_permission(sid, "s1", "execute", rawInput={"command": "git push origin main"})
        return "end_turn"

    if scenario == "hang":
        outcome = ask_permission(sid, "x1", "execute", rawInput={"command": "git push origin main"})
        say(sid, "permission " + outcome, "m1")
        return "cancelled" if state["cancelled"] else "end_turn"

    say(sid, "echo: " + scenario, "m1")
    return "end_turn"


while True:
    message = read()
    method, request_id, params = message.get("method"), message.get("id"), message.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {
            "protocolVersion": 1,
            "agentCapabilities": {"loadSession": os.environ.get("FAKE_LOAD") == "1"},
            "authMethods": [],
            "agentInfo": {"name": "fake", "version": "1"},
        }})
    elif method == "session/new":
        state["cwd"] = params["cwd"]
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": "sess-1", "configOptions": [model_option("fast")]}})
    elif method == "session/load" and params["sessionId"] == "gone":
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32002, "message": "no such session"}})
    elif method == "session/load":
        state["cwd"] = params["cwd"]
        say(params["sessionId"], "old news", "h1")
        send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": [model_option("fast")]}})
    elif method == "session/set_config_option":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": [model_option(params["value"])]}})
    elif method == "session/prompt":
        stop_reason = run(params["sessionId"], params["prompt"][0]["text"])
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": stop_reason}})
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "fake agent: no " + str(method)}})
