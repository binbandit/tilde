// Exercise the shutdown/recovery logic with application handles and a fake clock.
function run(argv) {
    ObjC.import('Foundation');
    var source = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
    eval(ObjC.unwrap(source));

    function assert(value, message) { if (!value) throw new Error(message); }
    function app(path, behavior) {
        var stopped = false;
        return {
            bundleIdentifier: 'dev.tilde.app', bundlePath: path,
            executablePath: path + '/Contents/MacOS/tilde',
            quits: 0, forces: 0,
            isTerminated: function() { return stopped; },
            terminate: function() { this.quits++; if (behavior === 'normal') stopped = true; },
            forceTerminate: function() { this.forces++; if (behavior !== 'stubborn') stopped = true; }
        };
    }
    function runtime(applications) {
        var seconds = 0;
        return {
            saved: [], opened: [],
            running: function() { return applications; },
            now: function() { return seconds; },
            tick: function(value) { seconds += value; },
            remember: function(paths) { this.saved = this.saved.concat(paths); },
            validBundle: function(path) { return path !== '/missing/tilde.app'; },
            open: function(path) { this.opened.push(path); return true; }
        };
    }
    function throws(action, text) {
        var failure;
        try { action(); } catch (error) { failure = String(error); }
        assert(failure && failure.indexOf(text) !== -1, 'Expected failure: ' + text);
    }

    var empty = runtime([]);
    stopTilde(empty);
    assert(empty.saved.length === 0 && empty.now() === 0, 'No running app must not wait');

    var normal = app('/old/tilde.app', 'normal');
    var shell = app('/tmp/tilde.app', 'normal');
    shell.executablePath = '/bin/bash';
    var helper = app('/old/tilde.app', 'normal');
    helper.executablePath += '-helper';
    var unrelated = app('/other/tilde.app', 'normal');
    unrelated.bundleIdentifier = 'example.other';
    var safe = runtime([normal, shell, helper, unrelated]);
    stopTilde(safe);
    assert(normal.quits === 1 && normal.forces === 0, 'Normal app must quit gracefully');
    assert(shell.quits === 0 && helper.quits === 0 && unrelated.quits === 0, 'Unrelated processes must never be stopped');
    assert(safe.saved.length === 1 && safe.saved[0] === '/old/tilde.app', 'Remember only verified apps');

    var slow = app('/old/tilde.app', 'slow');
    var forced = runtime([slow]);
    stopTilde(forced);
    assert(slow.quits === 1 && slow.forces === 1 && forced.now() >= 10 && forced.now() <= 13, 'Bounded forced shutdown');

    var stubborn = app('/old/tilde.app', 'stubborn');
    var failed = runtime([stubborn]);
    throws(function() { stopTilde(failed); }, 'did not shut down');
    assert(failed.now() >= 13 && failed.now() < 13.1 && stubborn.forces === 1, 'Unresponsive app must fail in bounded time');

    var original = app('/old/tilde.app', 'normal');
    var replacement = app('/old/tilde.app', 'normal');
    var restarted = runtime([original]);
    restarted.running = function() { return original.isTerminated() ? [replacement] : [original]; };
    throws(function() { stopTilde(restarted); }, 'restarted during shutdown');
    assert(replacement.quits === 0, 'A newly appearing app must not be confused with the captured handle');

    var untouched = app('/old/tilde.app', 'normal');
    var unsaved = runtime([untouched]);
    unsaved.remember = function() { throw new Error('cannot save'); };
    throws(function() { stopTilde(unsaved); }, 'cannot save');
    assert(untouched.quits === 0, 'Save recovery state before stopping anything');

    var recovery = runtime([app('/running/tilde.app', 'normal')]);
    recoverTilde(['/running/tilde.app', '/old/tilde.app', '/old/tilde.app'], recovery);
    assert(recovery.opened.length === 1 && recovery.opened[0] === '/old/tilde.app', 'Recover the exact old path once, without duplicating running apps');
    throws(function() { recoverTilde(['/missing/tilde.app'], recovery); }, 'Could not restart');
    return 'PASS: native lifecycle identity, graceful/forced/bounded shutdown, restart race and recovery';
}
