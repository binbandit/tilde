#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

# Retain the production class and Attention type; supply only fake platform/app dependencies.
python3 - "$repo" "$scratch/NotificationActionsTests.swift" <<'PY'
from pathlib import Path
import sys

repo, output = map(Path, sys.argv[1:])
fixture = (repo / 'scripts/test-notification-actions.swift').read_text()
attention = (repo / 'Packages/TildeKit/Sources/TildeBrain/Conductor/Attention.swift').read_text()
notifications = (repo / 'Tilde/Notifications/Notifications.swift').read_text()
app_fixtures = fixture[fixture.index('struct Job {'):fixture.index('@main\nstruct NotificationActionsTests')]
native = notifications.replace('import TildeKit\n', '')
output.with_name('NotificationActionsTypecheck.swift').write_text('import Foundation\n' + attention + '\n' + app_fixtures + '\n' + native)
notifications = '\n'.join(line for line in notifications.splitlines()
                          if not line.startswith(('import ', '@preconcurrency import ')))
output.write_text(fixture + '\n' + attention + '\n' + notifications)
PY
# Check real AppKit/UserNotifications signatures without executing any platform API.
xcrun swiftc -typecheck -swift-version 6 -default-isolation MainActor -module-cache-path "$scratch/modules" \
    "$scratch/NotificationActionsTypecheck.swift"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor -module-cache-path "$scratch/modules" \
    "$scratch/NotificationActionsTests.swift" -o "$scratch/test-notification-actions"
"$scratch/test-notification-actions"
