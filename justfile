# tilde - a coworker that lives in your Mac

derived := "build/DerivedData"
app := derived + "/Build/Products/Debug/tilde.app"

# Generate the Xcode project from project.yml
gen:
    xcodegen generate --quiet

# Build the app (Debug)
build: gen
    xcodebuild -project Tilde.xcodeproj -scheme Tilde -configuration Debug -derivedDataPath {{derived}} -destination 'platform=macOS' build -quiet

# Build, replace and launch the app: just install [destination]
install destination="": build
    bash scripts/install-app.sh {{quote(app)}} {{if destination == "" { "'/Applications' \"$HOME/Applications\"" } else { quote(destination) }}}

# Install recipe regressions using scratch app bundles
test-install:
    bash scripts/test-install.sh

# Terminal handoff quoting, without opening Terminal
test-terminal:
    bash scripts/test-terminal-command.sh

# Build and (re)launch the app
run: build
    -pkill -x tilde
    open {{app}}

# Unit tests for the brain
test:
    cd Packages/TildeKit && swift test

# Headless end-to-end run against a repo: just smoke <repo> "<what to say>"
smoke repo utterance *flags:
    cd Packages/TildeKit && swift build --product tilde-smoke && TILDE_HOME=${TILDE_HOME:-/tmp/tilde-smoke} .build/debug/tilde-smoke {{repo}} "{{utterance}}" {{flags}}

# Let `just show` drive the running app (debug routes are off unless this is set)
debug-routes on="true":
    defaults write dev.tilde.app debugRoutes -bool {{on}}

# Show the Inlet with fixture data, without taking the keyboard (after `just debug-routes`):
# just show fixtures|empty|clear|hide|frame, inlet "?mode=rest|open|compose|peek", listen "?text=...", job "?id=j-r4k2", place "?edge=top&notch=1"
show surface *query:
    open "tilde://debug/{{surface}}{{query}}"

# Follow tilde's log
log:
    tail -f ~/.tilde/state/tilde.log
