#!/usr/bin/env python3
"""Exercise the built helper with synthetic events and disposable projects only."""
import json
import pathlib
import subprocess
import sys
import tempfile
import time

if len(sys.argv) != 2:
    raise SystemExit("usage: python3 scripts/test-terminal-hooks.py /absolute/path/to/tilde-agent-hook")
binary = str(pathlib.Path(sys.argv[1]).resolve(strict=True))

with tempfile.TemporaryDirectory(prefix="tilde-hook-cli-") as temporary:
    root = pathlib.Path(temporary)
    project = root / "project's repo"
    home = root / "home's notebook"
    project.mkdir()

    def cli(*args, payload=None):
        return subprocess.run(
            [binary, *args, "--home", str(home)], input=payload,
            text=True, capture_output=True, check=True, timeout=5,
        )

    for adapter, relative in [
        ("claude", ".claude/settings.local.json"),
        ("codex", ".codex/hooks.json"),
        ("gemini", ".gemini/settings.json"),
    ]:
        registration = cli("install", adapter, str(project)).stdout.splitlines()[0]
        config = json.loads((project / relative).read_text())
        command = config["hooks"]["SessionStart"][0]["hooks"][0]["command"]
        payload = json.dumps({
            "session_id": "scratch-session", "cwd": str(project),
            "hook_event_name": "SessionStart", "prompt": "sentinel-private-content",
        })
        hook = subprocess.run(
            ["/bin/sh", "-c", command], input=payload,
            text=True, capture_output=True, check=True, timeout=5,
        )
        assert hook.stdout == "{}\n" and hook.stderr == "", hook
        observations = json.loads(cli("sessions").stdout)
        assert len(observations) == 1 and observations[0]["state"] == "started", observations
        assert "sentinel-private-content" not in (home / "state/terminal-agents/inbox.json").read_text()
        cli("remove", registration)
        assert json.loads(cli("sessions").stdout) == []
        revoked = cli("receive", "--registration", registration, payload=payload)
        assert revoked.stdout == "{}\n" and "not enabled" in revoked.stderr
        assert json.loads((project / relative).read_text()) == {}

    started = time.monotonic()
    with subprocess.Popen(
        [binary, "receive", "--registration", "00000000-0000-0000-0000-000000000000", "--home", str(home)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ) as process:
        process.wait(timeout=3)
        assert process.returncode == 0 and time.monotonic() - started < 2
        process.stdin.close()
        assert process.stdout.read() == b"{}\n"

print("Terminal hook CLI passed: 3 adapters, quoted paths, sanitized inbox, revocation, bounded stdin.")
