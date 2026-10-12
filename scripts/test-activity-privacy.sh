#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# Use production method bodies and the terminal catalog, replacing only their platform dependencies.
python3 - "$repo" "$scratch/ActivityPrivacyTests.swift" <<'PY'
from pathlib import Path
import re
import sys

repo, output = map(Path, sys.argv[1:])
referent = (repo / 'Tilde/Perception/Referent.swift').read_text()
catalog = re.search(r'    static let terminals: Set<String> = \[.*?\n    \]', referent, re.S)
assert catalog, 'Production terminal catalog not found'
fixture = (repo / 'scripts/test-activity-privacy.swift').read_text()
fixture = fixture.replace('    // TERMINAL_CATALOG', catalog.group())
policy = (repo / 'Tilde/Perception/WorkTitles.swift').read_text()
sampler = (repo / 'Tilde/Perception/MacPerception.swift').read_text()
sampler = '\n'.join(line for line in sampler.splitlines() if not line.startswith('import '))
output.write_text(fixture + '\n' + policy + '\n' + sampler)
PY
xcrun swiftc -parse-as-library -default-isolation MainActor -module-cache-path "$scratch/modules" \
    "$scratch/ActivityPrivacyTests.swift" -o "$scratch/test-activity-privacy"
"$scratch/test-activity-privacy" "$scratch/activity"
