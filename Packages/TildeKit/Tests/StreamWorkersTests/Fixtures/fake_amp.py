#!/usr/bin/python3 -I
"""Stands in for `amp -x --stream-json --stream-json-input` in the StreamWorker tests,
speaking the installed CLI's wire format. The last line of each prompt is a script:

  gate <command>  run <command> through the Bash delegate rule, as Amp's permission check does
  fail            end the run with an error result, as Amp does on an inference error
  gate-then-fail <command>  hold at the gate, then fail
  end-then-result end the turn, read the next prompt, then send the first run's success result
  crash           exit mid-turn without a result
  hang            start a tool call and never finish the turn
  anything else   reply "<thread> heard: <line>", noting "(briefed)" and "(resumed)"
"""
import json
import os
import signal
import subprocess
import sys

args = sys.argv[1:]
resumed = args[:2] == ["threads", "continue"]
thread = args[2] if resumed else "T-fake-0001"
with open(args[args.index("--settings-file") + 1]) as settings:
    rules = json.load(settings)["amp.permissions"]


def emit(message):
    print(json.dumps(message), flush=True)


def assistant(content, stop_reason):
    emit({"type": "assistant", "parent_tool_use_id": None, "session_id": thread,
          "message": {"type": "message", "role": "assistant", "content": content, "stop_reason": stop_reason}})


def result_error(error):
    emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "error": error,
          "duration_ms": 1, "num_turns": 1, "session_id": thread})
    sys.exit(1)


def bash(command):
    rule = next(r for r in rules if r["tool"] == "Bash" and r["action"] == "delegate")
    gate = subprocess.run([rule["to"]], input=json.dumps({"cmd": command}), capture_output=True, text=True,
                          env={**os.environ, "AGENT_TOOL_NAME": "Bash"})
    if gate.returncode == 0:
        return False, f"ran {command}"
    return True, f"Tool execution rejected by user: {gate.stderr.strip()}"


signal.signal(signal.SIGTERM, lambda *_: result_error("User cancelled (SIGINT/SIGTERM)"))
emit({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": thread, "tools": ["Bash"],
      "mcp_servers": [], "agent_mode": "smart"})

for line in sys.stdin:
    text = json.loads(line)["message"]["content"][0]["text"]
    script = text.strip().splitlines()[-1]
    if script == "end-then-result":
        assistant([{"type": "text", "text": "old result"}], "end_turn")
        following = json.loads(sys.stdin.readline())
        emit({"type": "result", "subtype": "success", "is_error": False, "result": "old result"})
        assistant([{"type": "text", "text": "new result"}], "end_turn")
    elif script.startswith("gate "):
        command = script[len("gate "):]
        assistant([{"type": "tool_use", "id": "toolu_1", "name": "Bash", "input": {"cmd": command}}], "tool_use")
        is_error, output = bash(command)
        emit({"type": "user", "parent_tool_use_id": None, "session_id": thread, "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "content": output, "is_error": is_error}]}})
        assistant([{"type": "text", "text": output}], "end_turn")
    elif script == "fail":
        result_error("Rate limited, try again later")
    elif script.startswith("gate-then-fail "):
        bash(script[len("gate-then-fail "):])
        result_error("Rate limited, try again later")
    elif script == "crash":
        sys.exit(3)
    elif script == "hang":
        assistant([{"type": "tool_use", "id": "toolu_2", "name": "Bash", "input": {"cmd": "sleep 60"}}], "tool_use")
    else:
        notes = (" (briefed)" if "\n---\n" in text else "") + (" (resumed)" if resumed else "")
        assistant([{"type": "text", "text": f"{thread} heard: {script}{notes}"}], "end_turn")

emit({"type": "result", "subtype": "success", "is_error": False, "result": "", "duration_ms": 1, "num_turns": 1,
      "session_id": thread})
