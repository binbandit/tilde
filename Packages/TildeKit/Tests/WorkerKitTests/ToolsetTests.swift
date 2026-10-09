import Testing
import TildeSupport
@testable import WorkerKit

@Suite struct ToolsetTests {
    @Test func toolsetServesMCPAndCodexShapes() async {
        let tools = Toolset(name: "tilde", instructions: "", tools: [
            AgentTool("echo", "Echoes.", schema: AgentTool.object(["text": ["type": "string"]])) { .ok($0["text"]?.string ?? "") },
        ])
        let listed = await tools.handleMCP(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        #expect(listed?["result"]?["tools"]?[0]?["name"] == "echo")
        let called = await tools.handleMCP(["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "echo", "arguments": ["text": "hi"]]])
        #expect(called?["result"]?["content"]?[0]?["text"] == "hi")
        #expect(tools.codexSpecs[0]?["type"] == "function")
        #expect(await tools.handleMCP(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }
}
