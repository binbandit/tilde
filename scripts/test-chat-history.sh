#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tilde-chat-history.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
common=(-swift-version 6 -target "$(uname -m)-apple-macosx27.0" -module-cache-path "$scratch/cache")
# Compile the real conversation value and its only dependency, without a brain,
# notebook, Accessibility reads or model process.
swiftc "${common[@]}" -emit-library -emit-module -module-name TildeSupport \
    Packages/TildeKit/Sources/TildeSupport/IDs.swift -o "$scratch/libTildeSupport.dylib" -emit-module-path "$scratch/TildeSupport.swiftmodule"
swiftc "${common[@]}" -I "$scratch" -L "$scratch" -lTildeSupport \
    -emit-library -emit-module -module-name TildeKit \
    Packages/TildeKit/Sources/TildeBrain/Conversation/Message.swift \
    -o "$scratch/libTildeKit.dylib" -emit-module-path "$scratch/TildeKit.swiftmodule"
swiftc "${common[@]}" -parse-as-library -default-isolation MainActor \
    -I "$scratch" -L "$scratch" -lTildeKit -lTildeSupport -Xlinker -rpath -Xlinker "$scratch" \
    Tilde/Inlet/Conversation/ConversationVisibility.swift Tilde/Inlet/InletMinimization.swift scripts/test-chat-history.swift -o "$scratch/tests"
mkdir -p "$scratch/preferences"
CFFIXED_USER_HOME="$scratch/preferences" "$scratch/tests"
