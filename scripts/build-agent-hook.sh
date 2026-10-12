#!/bin/bash
# Xcode build phase: embed a native, non-UI lifecycle event receiver.
# This builds inside DerivedData only; it never installs or registers hooks.
set -euo pipefail

: "${SRCROOT:?}" "${TARGET_BUILD_DIR:?}" "${WRAPPER_NAME:?}" "${DERIVED_FILE_DIR:?}"
configuration=debug
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then configuration=release; fi
args=(--package-path "$SRCROOT/Packages/TildeKit" --scratch-path "$DERIVED_FILE_DIR/AgentHook" --configuration "$configuration" --product tilde-agent-hook)
for architecture in ${ARCHS:-}; do args+=(--arch "$architecture"); done

xcrun swift build "${args[@]}"
binary_directory=$(xcrun swift build "${args[@]}" --show-bin-path)
destination="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Helpers"
mkdir -p "$destination"
ditto "$binary_directory/tilde-agent-hook" "$destination/tilde-agent-hook"
chmod 755 "$destination/tilde-agent-hook"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$destination/tilde-agent-hook"
fi
