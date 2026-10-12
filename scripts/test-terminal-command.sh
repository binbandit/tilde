#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$scratch/modules" \
    "$repo/Tilde/App/TerminalCommand.swift" "$repo/scripts/test-terminal-command.swift" \
    -o "$scratch/test-terminal-command"
"$scratch/test-terminal-command"
