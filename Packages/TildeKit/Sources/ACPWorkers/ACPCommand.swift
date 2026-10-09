import TildeSupport

/// How to start one ACP agent.
public struct ACPCommand: Sendable {
    /// User-facing name, for notices ("OpenCode exited").
    public var label: String
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    /// Whether tilde picks `WorkerLaunch.model` through the session's model
    /// selector. Off when the arguments or environment already name it.
    public var selectsModel: Bool

    public init(
        label: String, executable: String, arguments: [String],
        environment: [String: String] = UserEnvironment.shared.variables, selectsModel: Bool = true
    ) {
        self.label = label
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.selectsModel = selectsModel
    }
}
