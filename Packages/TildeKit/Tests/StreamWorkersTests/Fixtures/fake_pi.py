#!/usr/bin/python3 -I
"""Stands in for `pi --mode rpc` in the StreamWorker tests, speaking Pi's RPC records.
Every command it receives is appended to $FAKE_LOG. Prompts are scripts:

  gate <command>  hold a bash call at tilde's gate extension, as Pi's tool_call hook does
  write <path>    hold a file write there the same way
  ask <question>  raise a select dialog, as a user's own extension might
  hang            start a tool call and wait until aborted
  refuse          refuse the prompt
  handled         take the prompt without starting a run, as an extension command does
  hold-before-settle[-exit], hold-before-disposition <disposition>
                  read the next prompt mid-run and answer it in an order the tests pin down
  anything else   reply "<session> heard: <text>", noting "(briefed)"

Prompts that arrive mid-run are queued as steers and answered before the run settles.
"""
import json
import os
import sys

args = sys.argv[1:]
session = args[args.index("--session-id") + 1]
briefed = "--append-system-prompt" in args
log = open(os.environ["FAKE_LOG"], "a") if "FAKE_LOG" in os.environ else None


def emit(record):
    print(json.dumps(record), flush=True)


def read():
    line = sys.stdin.readline()
    if not line:
        return None
    record = json.loads(line)
    if log:
        log.write(record["type"] + "\n")
        log.flush()
    return record


def say(text):
    emit({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": text}],
                                             "stopReason": "stop"}})


def wait_for(request_id, steers):
    """Reads stdin until the dialog is answered (or the run aborted), queueing steers."""
    while (record := read()) is not None:
        if record["type"] == "extension_ui_response" and record["id"] == request_id:
            return record
        if record["type"] == "prompt":
            steers.append(record["message"])
            emit({"id": record.get("id"), "type": "response", "command": "prompt", "success": True, "data": {"disposition": "queued"}})
        if record["type"] == "abort":
            emit({"type": "response", "command": "abort", "success": True})
            return None
    sys.exit(0)


while (command := read()) is not None:
    if command["type"] != "prompt":
        continue
    if command["message"] == "refuse":
        emit({"id": command.get("id"), "type": "response", "command": "prompt", "success": False,
              "error": "Fixture refused the prompt"})
        continue
    if command["message"] == "handled":
        emit({"id": command.get("id"), "type": "response", "command": "prompt", "success": True,
              "data": {"disposition": "handled"}})
        continue
    emit({"id": command.get("id"), "type": "response", "command": "prompt", "success": True, "data": {"disposition": "started"}})
    emit({"type": "agent_start"})
    script, steers, answer = command["message"], [], {}
    if script in ("hold-before-settle", "hold-before-settle-exit"):
        say("old result")
        following = read()
        emit({"type": "agent_settled", "aborted": False})
        if script == "hold-before-settle-exit":
            sys.exit(3)
        emit({"id": following.get("id"), "type": "response", "command": "prompt", "success": True,
              "data": {"disposition": "started"}})
        say("new result")
    elif script.startswith("hold-before-disposition "):
        say("old result")
        following = read()
        emit({"id": following.get("id"), "type": "response", "command": "prompt", "success": True,
              "data": {"disposition": script.split(" ", 1)[1]}})
        say("old run finished")
    elif script.startswith(("gate ", "write ")):
        verb, target = script.split(" ", 1)
        call = {"tool": "bash", "input": {"command": target}} if verb == "gate" else {"tool": "write", "input": {"path": target}}
        emit({"type": "tool_execution_start", "toolCallId": "call_1", "toolName": call["tool"], "args": call["input"]})
        emit({"type": "extension_ui_request", "id": "ui-1", "method": "input", "title": "tilde:gate",
              "placeholder": json.dumps(call)})
        answer = wait_for("ui-1", steers)
        if answer:
            say(f"ran {target}" if answer["value"] == "allow" else f"blocked: {answer['value']}")
    elif script.startswith("ask "):
        emit({"type": "extension_ui_request", "id": "ui-2", "method": "select", "title": script[len("ask "):],
              "options": ["Sticky", "Scroll away"]})
        answer = wait_for("ui-2", steers)
        if answer:
            say(f"picked {answer.get('value')}")
    elif script == "hang":
        emit({"type": "tool_execution_start", "toolCallId": "call_2", "toolName": "bash", "args": {"command": "sleep 60"}})
        answer = wait_for("never", steers)
    else:
        say(f"{session} heard: {script}" + (" (briefed)" if briefed else ""))
    for steer in steers:
        say(f"steered: {steer}")
    emit({"type": "agent_settled", "aborted": answer is None})
