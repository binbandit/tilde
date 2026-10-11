import Foundation
import Testing
import TildeSupport
@testable import TildeBrain

/// Opt in with TILDE_GATEWAY_TEST_CODEX=/absolute/path/to/codex. All HTTP is loopback;
/// a fresh CODEX_HOME and env -i keep the owner's configuration and credentials out.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TILDE_GATEWAY_TEST_CODEX"] != nil))
struct GatewayHTTPTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "tilde-gateway-http-\(UUID().uuidString)")

    @Test(.timeLimit(.minutes(1)), arguments: ["model-route", "header-route", "missing-route"])
    func realCodexUsesTheConfiguredGatewayAndEmitsOneReply(_ route: String) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requests = root.appending(path: "http.jsonl")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/local_gateway.py")
        let server = try ChildProcess(.init(
            executable: "/usr/bin/python3", arguments: ["-I", fixture.path, requests.path], cwd: root.path,
            environment: ["PATH": "/usr/bin:/bin"]))
        defer { Task { await server.terminate() } }
        var lines = server.lines.makeAsyncIterator()
        let port = try #require(await lines.next().flatMap(Int.init), "\(server.stderr)")
        let model = route == "model-route" ? "@work-openai/gateway-model" : "gateway-model"
        let configHome = root.appending(path: "codex-home")
        try FileManager.default.createDirectory(at: configHome, withIntermediateDirectories: true)
        try """
            model = "\(model)"
            model_provider = "portkey"
            [model_providers.portkey]
            name = "Local Portkey fixture"
            base_url = "http://127.0.0.1:\(port)/work/v1"
            wire_api = "responses"
            requires_openai_auth = false
            supports_websockets = false
            request_max_retries = 0
            stream_max_retries = 0
            env_http_headers = { "x-portkey-api-key" = "PORTKEY_API_KEY" }
            \(route == "header-route" ? "http_headers = { \"x-portkey-provider\" = \"@work-openai\" }" : "")
            """.write(to: configHome.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let codex = try #require(ProcessInfo.processInfo.environment["TILDE_GATEWAY_TEST_CODEX"])
        let executable = root.appending(path: "codex")
        // Paths are quoted as shell data; no real authentication enters this child.
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try "#!/bin/sh\nexec /usr/bin/env -i HOME=\(quote(root.path)) CODEX_HOME=\(quote(configHome.path)) PATH=/usr/bin:/bin PORTKEY_API_KEY=fixture-only-key \(quote(codex)) \"$@\"\n"
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var config = Conductor.Config()
        config.initiative = false
        config.projectRoots = []
        config.manager.executable = executable.path
        config.scribe.executable = "/usr/bin/false"
        config.dream.executable = "/usr/bin/false"
        let conductor = try Conductor(home: TildeHome(root: root.appending(path: "tilde-home")), config: config)
        conductor.tap("hi")
        var troubles = 0
        var streamed: [String] = []
        for await output in conductor.manager.outputs {
            conductor.handle(output)
            if case .trouble = output { troubles += 1 }
            if case .reply(_, let text) = output { streamed.append(text) }
            if case .replyDone = output { break }
            if case .undelivered(_, let reason) = output { Issue.record("\(reason)"); break }
        }
        await conductor.manager.shutdown()
        let captured = try String(contentsOf: requests, encoding: .utf8).split(separator: "\n").compactMap { JSON.parse(String($0)) }
        #expect(captured.count == 1)
        let request = try #require(captured.first)
        #expect(request["path"]?.string == "/work/v1/responses")
        #expect(request["model"]?.string == model)
        #expect(request["stream"]?.bool == true)
        #expect(request["key"]?.string == "fixture-only-key")
        #expect(request["authorization"]?.isNull == true)
        #expect(request["provider"]?.string == (route == "header-route" ? "@work-openai" : nil))
        #expect(conductor.thread.map(\.from) == [.you, .tilde])
        #expect(conductor.thread.last?.streaming == false)
        if route == "missing-route" {
            #expect(troubles == 1)
            #expect(conductor.thread.last?.trouble == true)
            #expect(conductor.thread.last?.text.contains("Passthrough target requires a provider") == true)
        } else {
            #expect(troubles == 0)
            #expect(streamed == ["Hello ", "Hello once."])
            #expect(conductor.thread.last?.text == "Hello once.")
        }
        #expect(ThreadStore(home: conductor.home).load().map(\.text) == conductor.thread.map(\.text))
        await server.terminate()
    }
}
