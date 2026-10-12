#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT

xcrun swiftc -module-cache-path "$scratch/cache" -swift-version 6 \
    "$repo/Tilde/Inlet/InletGeometry.swift" \
    "$repo/Tilde/Inlet/InletPreferences.swift" \
    "$repo/Tilde/Inlet/InletPlacement.swift" \
    "$repo/Tilde/Inlet/InletShape.swift" \
    "$repo/Tilde/Inlet/Inlet.swift" \
    "$repo/scripts/test-inlet-geometry.swift" \
    -o "$scratch/test-inlet-geometry"
mkdir -p "$scratch/preferences"
CFFIXED_USER_HOME="$scratch/preferences" "$scratch/test-inlet-geometry"
