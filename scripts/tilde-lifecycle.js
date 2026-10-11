// Run with osascript -l JavaScript. NSRunningApplication handles avoid PID reuse.
function isTilde(application) {
    return application.bundleIdentifier === 'dev.tilde.app' &&
        /\.app$/i.test(application.bundlePath) &&
        application.executablePath === application.bundlePath + '/Contents/MacOS/tilde';
}

function runningTilde(runtime) {
    return runtime.running().filter(function(application) {
        return isTilde(application) && !application.isTerminated();
    });
}

function waitForShutdown(applications, seconds, runtime) {
    var deadline = runtime.now() + seconds;
    while (applications.some(function(application) { return !application.isTerminated(); })) {
        if (runtime.now() >= deadline) return false;
        runtime.tick(Math.min(0.1, deadline - runtime.now()));
    }
    return true;
}

function stopTilde(runtime) {
    var applications = runningTilde(runtime);
    runtime.remember(applications.map(function(application) { return application.bundlePath; }));
    applications.forEach(function(application) { application.terminate(); });
    if (!waitForShutdown(applications, 10, runtime)) {
        applications.filter(function(application) { return !application.isTerminated(); })
            .forEach(function(application) { application.forceTerminate(); });
        if (!waitForShutdown(applications, 3, runtime)) {
            throw new Error('tilde did not shut down; the installation was not replaced');
        }
    }
    if (runningTilde(runtime).length !== 0) {
        throw new Error('A tilde instance restarted during shutdown; installation aborted');
    }
}

function recoverTilde(paths, runtime) {
    var running = runningTilde(runtime).map(function(application) { return application.bundlePath; });
    var failures = [];
    paths.forEach(function(path) {
        if (running.indexOf(path) !== -1) return;
        if (!runtime.validBundle(path) || !runtime.open(path)) failures.push(path);
        else running.push(path);
    });
    if (failures.length !== 0) throw new Error('Could not restart previous tilde app: ' + failures.join(', '));
}

function run(arguments) {
    ObjC.import('AppKit');
    var mode = arguments[0];
    var statePath = arguments[1];

    function readState() {
        var value = $.NSString.stringWithContentsOfFileEncodingError(statePath, $.NSUTF8StringEncoding, null);
        if (!ObjC.unwrap(value)) throw new Error('Cannot read shutdown state');
        var paths = JSON.parse(ObjC.unwrap(value));
        if (!Array.isArray(paths) || paths.some(function(path) { return typeof path !== 'string'; })) {
            throw new Error('Invalid shutdown state');
        }
        return paths;
    }

    function pathOf(url) {
        return ObjC.unwrap(url.URLByResolvingSymlinksInPath.path);
    }

    var runtime = {
        running: function() {
            var native = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('dev.tilde.app');
            var applications = [];
            for (var index = 0; index < native.count; index++) {
                (function(application) {
                    try {
                        applications.push({
                            bundleIdentifier: ObjC.unwrap(application.bundleIdentifier),
                            bundlePath: pathOf(application.bundleURL),
                            executablePath: pathOf(application.executableURL),
                            isTerminated: function() { return application.isTerminated; },
                            terminate: function() { return application.terminate; },
                            forceTerminate: function() { return application.forceTerminate; }
                        });
                    } catch (error) {
                        // A process that exited during enumeration has no usable bundle URL.
                        if (!application.isTerminated) throw error;
                    }
                })(native.objectAtIndex(index));
            }
            return applications;
        },
        now: function() { return $.NSProcessInfo.processInfo.systemUptime; },
        tick: function(seconds) {
            // AppKit's time-varying properties refresh only when the run loop runs.
            $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(seconds));
        },
        remember: function(paths) {
            var saved = readState();
            paths.forEach(function(path) { if (saved.indexOf(path) === -1) saved.push(path); });
            if (!$(JSON.stringify(saved)).writeToFileAtomicallyEncodingError(statePath, true, $.NSUTF8StringEncoding, null)) {
                throw new Error('Cannot save shutdown state; no app was stopped');
            }
        },
        validBundle: function(path) {
            var bundle = $.NSBundle.bundleWithPath(path);
            try {
                return ObjC.unwrap(bundle.bundleIdentifier) === 'dev.tilde.app' &&
                    pathOf(bundle.executableURL) === path + '/Contents/MacOS/tilde';
            } catch (error) { return false; }
        },
        open: function(path) {
            var task = $.NSTask.alloc.init;
            task.launchPath = '/usr/bin/open';
            task.arguments = $(['-n', path]);
            task.launch;
            task.waitUntilExit;
            return task.terminationStatus === 0;
        }
    };

    if (mode === 'list' && arguments.length === 1) {
        return JSON.stringify(runningTilde(runtime).map(function(application) { return application.bundlePath; }));
    }
    if (arguments.length !== 2) throw new Error('Usage: tilde-lifecycle.js stop|recover STATE, or list');
    if (mode === 'stop') stopTilde(runtime);
    else if (mode === 'recover') recoverTilde(readState(), runtime);
    else throw new Error('Unknown lifecycle operation');
}
