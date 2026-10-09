import TildeSupport

/// A tool tilde lends an agent: over MCP for Claude, as a dynamic tool for Codex.
public struct AgentTool: Sendable {
    public var name: String
    public var description: String
    public var schema: JSON
    public var run: @Sendable (JSON) async -> ToolResult

    public init(_ name: String, _ description: String, schema: JSON, run: @escaping @Sendable (JSON) async -> ToolResult) {
        self.name = name
        self.description = description
        self.schema = schema
        self.run = run
    }

    /// `properties` are JSON Schema property definitions; `required` names the mandatory ones.
    public static func object(_ properties: [String: JSON], required: [String] = []) -> JSON {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })]
    }
}

public struct ToolResult: Sendable {
    public var text: String
    public var isError: Bool

    public static func ok(_ text: String) -> ToolResult { ToolResult(text: text, isError: false) }
    public static func error(_ text: String) -> ToolResult { ToolResult(text: text, isError: true) }
}

/// A named set of tools, servable as a minimal MCP server (initialize,
/// tools/list, tools/call) or as Codex dynamic tools.
public struct Toolset: Sendable {
    public var name: String
    public var instructions: String
    public var tools: [AgentTool]

    public init(name: String, instructions: String, tools: [AgentTool]) {
        self.name = name
        self.instructions = instructions
        self.tools = tools
    }

    public func call(_ name: String, _ arguments: JSON) async -> ToolResult {
        guard let tool = tools.first(where: { $0.name == name }) else { return .error("Unknown tool \(name).") }
        return await tool.run(arguments)
    }

    /// ThreadStartParams.dynamicTools
    public var codexSpecs: JSON {
        .array(tools.map {
            ["type": "function", "name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema]
        })
    }

    public func handleMCP(_ message: JSON) async -> JSON? {
        guard let id = message["id"], !id.isNull else { return nil }
        let reply = { (result: JSON) -> JSON in ["jsonrpc": "2.0", "id": id, "result": result] }
        switch message["method"]?.string {
        case "initialize":
            return reply([
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": "1"],
                "instructions": .string(instructions),
            ])
        case "tools/list":
            return reply(["tools": .array(tools.map {
                ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema]
            })])
        case "tools/call":
            let params = message["params"]
            let result = await call(params?["name"]?.string ?? "", params?["arguments"] ?? [:])
            return reply(["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)])
        case "ping":
            return reply([:])
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "method not found"]]
        }
    }
}
