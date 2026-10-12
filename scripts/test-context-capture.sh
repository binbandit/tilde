#!/bin/bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d /tmp/tilde-context-capture.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

# Compile the real context value in a narrow TildeKit module. This fixture harness needs neither
# Xcode nor a package build, and never invokes the production Accessibility collector.
xcrun swiftc -module-cache-path "$scratch/cache" -swift-version 6 \
    -emit-module -emit-library -module-name TildeKit \
    "$root/Packages/TildeKit/Sources/TildeBrain/Perception/Perception.swift" \
    -emit-module-path "$scratch/TildeKit.swiftmodule" -o "$scratch/libTildeKit.dylib"
xcrun swiftc -module-cache-path "$scratch/cache" -swift-version 6 \
    -default-isolation MainActor -strict-concurrency=complete -warnings-as-errors \
    -I "$scratch" -L "$scratch" -lTildeKit -Xlinker -rpath -Xlinker "$scratch" \
    "$root/Tilde/Perception/Coordinates.swift" \
    "$root/Tilde/Perception/Shells.swift" \
    "$root/Tilde/Perception/Referent.swift" \
    "$root/Tilde/Perception/ContextCapture.swift" \
    "$root/scripts/tests/context-capture.swift" -o "$scratch/context-capture-checks"
"$scratch/context-capture-checks"
