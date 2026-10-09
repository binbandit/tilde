import Darwin
import Foundation
import TildeSupport
import Synchronization

/// tilde's gate for harnesses that hand permission decisions to an external program
/// (Amp's `delegate` rules) rather than to their client.
///
/// The harness runs `helper` once per call. It drops `<call>.request` into the folder
/// (tool name, a newline, the JSON input) and waits for `<call>.verdict`: "allow", or
/// "deny" with the reason on the next line. It gives up, rejecting, if the request
/// disappears or tilde's process is gone, so a crashed tilde never hangs the agent.
final class GateMailbox: Sendable {
    let folder: URL
    private let source: any DispatchSourceFileSystemObject
    private let seen = Mutex<Set<String>>([])

    init(in scratch: URL, onCall: @escaping @Sendable (GateCall) -> Void) throws {
        folder = Self.folder(in: scratch)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: folder.path]) }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .global())
        source.setEventHandler { [weak self] in self?.collect(onCall) }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }

    func reply(_ id: String, _ verdict: GateVerdict) {
        let text =
            switch verdict {
            case .allow: "allow\n"
            case .deny(let reason): "deny\n\(reason)\n"
            }
        try? Data(text.utf8).write(to: folder.appending(path: "\(id).verdict"), options: .atomic)
    }

    /// Stops watching and removes the folder, which turns away any call still waiting.
    func close() {
        source.cancel()
        try? FileManager.default.removeItem(at: folder)
    }

    private func collect(_ onCall: @Sendable (GateCall) -> Void) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasSuffix(".request") {
            let id = String(name.dropLast(".request".count))
            guard seen.withLock({ $0.insert(id).inserted }),
                let text = try? String(contentsOf: folder.appending(path: name), encoding: .utf8)
            else { continue }
            let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            onCall(GateCall(
                id: id, tool: parts.first.map(String.init) ?? "",
                input: parts.count > 1 ? JSON.parse(String(parts[1])) ?? [:] : [:]))
        }
    }

    // MARK: Helper

    static func folder(in scratch: URL) -> URL { scratch.appending(path: "gate") }

    /// Writes the helper program into `scratch` and returns its path.
    static func installHelper(in scratch: URL) throws -> URL {
        let helper = scratch.appending(path: "tilde-gate")
        let script = """
            #!/bin/sh
            # tilde's gate: hands one tool call to the tilde worker supervising this agent and
            # exits with its verdict (0 allows; 2 rejects, and the agent is shown stderr).
            PATH=/usr/bin:/bin
            dir=\(shellQuoted(folder(in: scratch).path))
            call=$(mktemp "$dir/call.XXXXXX") || exit 2
            { printf '%s\\n' "${AGENT_TOOL_NAME:-unknown}"; cat; } > "$call.part" && mv "$call.part" "$call.request"
            while [ ! -f "$call.verdict" ]; do
                if [ ! -f "$call.request" ] || ! kill -0 \(getpid()) 2>/dev/null; then
                    echo "tilde is no longer supervising this job." >&2
                    rm -f "$call" "$call.request"
                    exit 2
                fi
                sleep 0.05
            done
            { read -r verdict; reason=$(cat); } < "$call.verdict"
            rm -f "$call" "$call.request" "$call.verdict"
            [ "$verdict" = allow ] && exit 0
            printf '%s\\n' "${reason:-tilde did not allow this.}" >&2
            exit 2

            """
        try Data(script.utf8).write(to: helper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
