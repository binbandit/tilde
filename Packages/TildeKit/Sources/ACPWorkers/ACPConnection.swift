import Foundation
import TildeSupport

/// A JSON-RPC error, from either side of an ACP connection.
public struct ACPError: Error, CustomStringConvertible, Sendable {
    public var code: Int
    public var message: String
    public var description: String { message }

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    static let authRequired = -32000
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let resourceNotFound = -32002
}

/// One ACP agent process speaking JSON-RPC 2.0, one message per stdout line.
///
/// Everything the agent sends reaches the handler in order, and a response
/// only resumes its caller after every message before it was handled, so a
/// turn's `session/update`s are all applied by the time `session/prompt` returns.
actor ACPConnection {
    enum Incoming: Sendable {
        case notification(method: String, params: JSON)
        case request(id: JSON, method: String, params: JSON)
        case exited(status: Int32, stderr: String)
    }

    private let process: ChildProcess
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Result<JSON, ACPError>, Never>] = [:]

    init(_ spec: ChildProcess.Spec) throws {
        process = try ChildProcess(spec)
    }

    /// Starts delivering the agent's messages. Call once.
    nonisolated func listen(_ handler: @escaping @Sendable (Incoming) async -> Void) {
        Task { await pump(handler) }
    }

    var hasExited: Bool { process.exitStatus != nil }

    func request(_ method: String, _ params: JSON) async throws -> JSON {
        nextID += 1
        let id = nextID
        let result = await withCheckedContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(returning: .failure(ACPError(code: ACPError.internalError, message: "\(error)")))
            }
        }
        return try result.get()
    }

    func notify(_ method: String, _ params: JSON) {
        try? send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    func respond(to id: JSON, _ reply: Result<JSON, ACPError>) {
        switch reply {
        case .success(let result):
            try? send(["jsonrpc": "2.0", "id": id, "result": result])
        case .failure(let error):
            try? send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(error.code)), "message": .string(error.message)]])
        }
    }

    func terminate() async {
        await process.terminate()
    }

    private func send(_ message: JSON) throws {
        try process.write(message.line())
    }

    private func pump(_ handler: @Sendable (Incoming) async -> Void) async {
        for await line in process.lines {
            // Some agents log to stdout; anything that isn't JSON isn't for us.
            guard let message = JSON.parse(line) else { continue }
            let id = message["id"].flatMap { $0.isNull ? nil : $0 }
            switch (message["method"]?.string, id) {
            case (let method?, let id?):
                await handler(.request(id: id, method: method, params: message["params"] ?? [:]))
            case (let method?, nil):
                await handler(.notification(method: method, params: message["params"] ?? [:]))
            case (nil, let id?):
                guard let n = id.int, let continuation = pending.removeValue(forKey: n) else { continue }
                if let error = message["error"] {
                    continuation.resume(returning: .failure(ACPError(
                        code: error["code"]?.int ?? ACPError.internalError, message: error["message"]?.string ?? error.compact)))
                } else {
                    continuation.resume(returning: .success(message["result"] ?? nil))
                }
            case (nil, nil):
                continue
            }
        }
        let status = await process.waitForExit()
        for continuation in pending.values {
            continuation.resume(returning: .failure(ACPError(code: ACPError.internalError, message: "The agent exited")))
        }
        pending = [:]
        await handler(.exited(status: status, stderr: String(process.stderr.suffix(2000))))
    }
}
