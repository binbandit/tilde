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

# Build Release and relaunch in /Applications, falling back to ~/Applications unless a folder is given
install destination="": (build "Release")
    #!/bin/bash
    set -euo pipefail
    directory={{quote(destination)}}
    if [[ -z "$directory" ]]; then directory=/Applications; fallback="$HOME/Applications"; else fallback=; fi
    [[ "$directory" == /* ]] || directory="$PWD/$directory"
    # Stage beside the destination so the swap is a rename on the same volume.
    if ! mkdir -p -- "$directory" || ! stage=$(mktemp -d "$directory/.tilde-install.XXXXXX"); then
        [[ -n "$fallback" ]] || exit 1
        directory="$fallback"
        mkdir -p -- "$directory"
        stage=$(mktemp -d "$directory/.tilde-install.XXXXXX")
    fi
    target="$directory/tilde.app"
    previous="$stage/previous.app"
    cleanup() {
        if [[ -e "$previous" || -L "$previous" ]]; then
            echo "Previous installation retained at $previous" >&2
        else
            rm -rf -- "$stage"
        fi
    }
    trap cleanup EXIT
    ditto {{quote(products / "Release/tilde.app")}} "$stage/tilde.app"
    # AppKit handles identify the bundle and executable, and avoid PID reuse.
    stop() {
        osascript -l JavaScript <<'JXA'
    function run() {
        ObjC.import('AppKit');
        function running() {
            var found = [], apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('dev.tilde.app');
            for (var i = 0; i < apps.count; i++) {
                var app = apps.objectAtIndex(i);
                if (app.isTerminated) continue;
                var bundle = ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path);
                var executable = ObjC.unwrap(app.executableURL.URLByResolvingSymlinksInPath.path);
                if (/\.app$/i.test(bundle) && executable === bundle + '/Contents/MacOS/tilde') found.push(app);
            }
            return found;
        }
        function wait(apps, seconds) {
            var deadline = $.NSProcessInfo.processInfo.systemUptime + seconds;
            while (apps.some(function(app) { return !app.isTerminated; })) {
                if ($.NSProcessInfo.processInfo.systemUptime >= deadline) return false;
                $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1));
            }
            return true;
        }
        var apps = running();
        apps.forEach(function(app) { app.terminate; });
        if (!wait(apps, 5)) {
            apps.filter(function(app) { return !app.isTerminated; }).forEach(function(app) { app.forceTerminate; });
            if (!wait(apps, 3)) throw new Error('tilde did not stop');
        }
        if (running().length) throw new Error('tilde restarted during shutdown');
        return apps.length;
    }
    JXA
    }
    running=$(stop)
    restore() {
        if [[ -e "$previous" || -L "$previous" ]]; then
            mv -- "$previous" "$target"
            if [[ "$running" != 0 ]]; then open -n "$target" || true; fi
        fi
    }
    if [[ -e "$target" || -L "$target" ]]; then
        if ! mv -- "$target" "$previous"; then
            if [[ "$running" != 0 ]]; then open -n "$target" || true; fi
            exit 1
        fi
    fi
    if ! mv -- "$stage/tilde.app" "$target"; then restore; exit 1; fi
    if ! open -n "$target"; then
        # A failed launch may still have started; stop it before restoring the old bundle.
        stop >/dev/null
        mv -- "$target" "$stage/failed.app"
        restore
        exit 1
    fi
    rm -rf -- "$previous"
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
