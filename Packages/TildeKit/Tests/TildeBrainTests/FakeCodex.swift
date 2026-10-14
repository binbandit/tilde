import Foundation
import TildeSupport

/// Stands in for `codex app-server`: Fixtures/fake_codex.py playing `scenario` (they're described there).
struct FakeCodex {
    let executable: String
    /// Every request it gets, one JSON line each.
    let log: URL

    init(in folder: URL, scenario: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/fake_codex.py").path
        log = folder.appending(path: "requests.jsonl")
        executable = folder.appending(path: "codex").path
        try "#!/bin/sh\nFAKE_SCENARIO='\(scenario)' FAKE_OUT='\(log.path)' exec /usr/bin/python3 -I '\(script)'\n"
            .write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
    }

    var requests: [JSON] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { JSON.parse(String($0)) }
    }

    func requests(_ method: String) -> [JSON] { requests.filter { $0["method"]?.string == method } }

    /// What each new turn was sent, in order.
    var turns: [String] { requests("turn/start").compactMap { $0["params"]?["input"]?[0]?["text"]?.string } }

    /// Lets a held steer be acknowledged (the steer-receipt scenario).
    func release() throws { try Data().write(to: URL(fileURLWithPath: log.path + ".release")) }
}
