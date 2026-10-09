# tilde - a coworker that lives in your Mac

derived := "build/DerivedData"
app := derived + "/Build/Products/Debug/tilde.app"

# Generate the Xcode project from project.yml
gen:
    xcodegen generate --quiet

# Build the app (Debug)
build: gen
    xcodebuild -project Tilde.xcodeproj -scheme Tilde -configuration Debug -derivedDataPath {{derived}} -destination 'platform=macOS' build -quiet

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

# Show a surface with fixture data: just show desk|review|caret|caption|listen|fixtures|clear
show surface *query:
    open "tilde://debug/{{surface}}{{query}}"

# Follow tilde's log
log:
    tail -f ~/.tilde/state/tilde.log
