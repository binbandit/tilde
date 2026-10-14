# tilde - a coworker that lives in your Mac

derived := "build/DerivedData"
products := derived / "Build/Products"

# Generate the Xcode project from project.yml
gen:
    xcodegen generate --quiet

# Regenerate the checked-in macOS icon assets from tilde's wave
icon:
    swift scripts/generate-app-icon.swift

# Build the app: just build [Debug|Release]
build configuration="Debug": gen
    xcodebuild -project Tilde.xcodeproj -scheme Tilde -configuration {{configuration}} -derivedDataPath {{derived}} -destination 'platform=macOS' build -quiet

# Build Release, replace tilde.app in /Applications (or the folder given) and relaunch it
install destination="/Applications": (build "Release")
    #!/bin/bash
    set -euo pipefail
    mkdir -p {{quote(destination)}}
    target={{quote(destination / "tilde.app")}}
    # Stage beside the destination so the swap is a rename on the same volume.
    stage=$(mktemp -d {{quote(destination / ".tilde-install.XXXXXX")}})
    trap 'rm -rf "$stage"' EXIT
    ditto {{quote(products / "Release/tilde.app")}} "$stage/tilde.app"
    # Ask tilde to quit, and kill it if it's still there after five seconds.
    if pgrep -x tilde >/dev/null; then
        osascript -e 'quit app id "dev.tilde.app"' || true
        for _ in {1..50}; do pgrep -x tilde >/dev/null || break; sleep 0.1; done
        pkill -KILL -x tilde && sleep 0.5 || true
    fi
    rm -rf "$target"
    mv "$stage/tilde.app" "$target"
    open "$target"
    echo "Installed $target"

# Terminal handoff quoting, without opening Terminal
test-terminal:
    bash scripts/test-terminal-command.sh

# Build and (re)launch the app
run: build
    -pkill -x tilde
    open {{products}}/Debug/tilde.app

# Unit tests: the brain (Packages/TildeKit), then the app's logic (TildeTests)
test: gen
    cd Packages/TildeKit && swift test
    xcodebuild -project Tilde.xcodeproj -scheme TildeTests -derivedDataPath {{derived}} -destination 'platform=macOS' test -quiet

# Headless end-to-end run against a repo: just smoke <repo> "<what to say>"
smoke repo utterance *flags:
    cd Packages/TildeKit && swift build --product tilde-smoke && TILDE_HOME=${TILDE_HOME:-/tmp/tilde-smoke} .build/debug/tilde-smoke {{repo}} "{{utterance}}" {{flags}}

# Targets bundle id dev.tilde.app, which the installed copy shares.
# Let `just show` drive the running app (debug routes are off unless this is set)
debug-routes on="true":
    defaults write dev.tilde.app debugRoutes -bool {{on}}

# Targets bundle id dev.tilde.app, which the installed copy shares.
# Show the Inlet with fixture data, without taking the keyboard (after `just debug-routes`):
# just show fixtures|empty|clear|hide|frame, inlet "?mode=rest|open|compose|peek", listen "?text=...", job "?id=j-r4k2", place "?edge=top&notch=1"
show surface *query:
    open "tilde://debug/{{surface}}{{query}}"

# Follow tilde's log
log:
    tail -f ~/.tilde/state/tilde.log
