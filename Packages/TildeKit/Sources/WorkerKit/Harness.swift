/// Which agent harness runs a job ("claude", "codex", "gemini", ...). Each harness
/// family names its own; `HarnessCatalog` (in Harnesses) maps them to their specs.
public struct Harness: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public var description: String { rawValue }
}
