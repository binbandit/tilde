#!/bin/bash
# Embed the no-op at the historical helper path; new discovery installs no project hooks.
set -euo pipefail

: "${SRCROOT:?}" "${TARGET_BUILD_DIR:?}" "${WRAPPER_NAME:?}"
destination="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
mkdir -p "$destination"
cp "$SRCROOT/scripts/terminal-hook-compat.sh" "$destination/tilde-agent-hook"
chmod 755 "$destination/tilde-agent-hook"
