#!/usr/bin/env python3
"""Verify the retired helper's packaging and old hook argv in a scratch bundle only."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent


def quote(value):
    return "'" + str(value).replace("'", "'\"'\"'") + "'"


def files_under(root):
    return {path.relative_to(root): path.read_bytes() for path in root.rglob("*") if path.is_file()}


with tempfile.TemporaryDirectory(prefix="tilde-hook-compat-") as temporary:
    root = Path(temporary)
    build = root / "build's directory"
    bundle = build / "tilde's app.app"
    environment = dict(os.environ, SRCROOT=str(repo), TARGET_BUILD_DIR=str(build), WRAPPER_NAME=bundle.name)
    subprocess.run(["/bin/bash", str(repo / "scripts/build-terminal-hook-compat.sh")], env=environment, check=True)
    helper = bundle / "Contents/Helpers/tilde-agent-hook"
    assert helper.read_bytes() == (repo / "scripts/terminal-hook-compat.sh").read_bytes()
    assert helper.stat().st_mode & 0o777 == 0o755

    project = root / "project's repo"
    project.mkdir()
    (project / "settings.json").write_text('{"unrelated":"preserve this"}')
    home = root / "home's notebook"
    home.mkdir()
    (home / "registrations.json").write_text('[{"id":"legacy-registration"}]')
    before = files_under(root)
    for target_home in [home, root / "absent home"]:
        # The old registration builder quoted every argv item, including paths with apostrophes.
        command = " ".join(map(quote, [helper, "receive", "--home", target_home, "--registration",
                                      "11111111-1111-1111-1111-111111111111"]))
        result = subprocess.run(["/bin/sh", "-c", command], cwd=project, input="unparsed private hook payload",
                                text=True, capture_output=True, timeout=2, check=True)
        assert result.stdout == "{}\n" and result.stderr == "", result
        assert files_under(root) == before
        assert not (root / "absent home").exists()

print("Retired hook compatibility passed: packaged executable, historical quoted argv, no project or home changes.")
