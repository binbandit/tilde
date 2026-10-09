import ACPWorkers
import ClaudeWorkers
import CodexWorkers
import StreamWorkers
import Synchronization
import WorkerKit

/// Every harness tilde can drive. This is the one place that knows every family.
public enum HarnessCatalog {
    /// Each family's specs, in the order the manager sees them. A new family is one more line.
    private static let families: [[HarnessSpec]] = [
        ClaudeHarnesses.specs,
        CodexHarnesses.specs,
        ACPHarnesses.specs,
        StreamHarnesses.specs,
    ]

    public static var all: [HarnessSpec] { families.flatMap(\.self) + extra.withLock { $0 } }

    /// Harnesses added at runtime (tests, and later user-defined harnesses).
    private static let extra = Mutex<[HarnessSpec]>([])

    public static func register(_ spec: HarnessSpec) {
        extra.withLock { specs in
            specs.removeAll { $0.id == spec.id }
            specs.append(spec)
        }
    }

    public static func spec(_ id: Harness) -> HarnessSpec? { all.first { $0.id == id } }

    /// The harnesses actually installed, in catalog order.
    public static func installed() -> [HarnessSpec] { all.filter(\.isInstalled) }
}

extension Harness {
    /// The default worker.
    public static let claude = ClaudeHarnesses.claude
    public static let codex = CodexHarnesses.codex

    public var spec: HarnessSpec? { HarnessCatalog.spec(self) }
    public var label: String { spec?.label ?? rawValue.capitalized }
}
