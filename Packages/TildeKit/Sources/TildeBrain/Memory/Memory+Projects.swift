import TildeMemory
import TildeSupport
import TildeWork

extension Memory {
    /// Memory over `home` that finds project paths among the repos `projects` knows.
    public init(home: TildeHome, projects: ProjectIndex) throws {
        try self.init(home: home) { name in
            await projects.search(name, limit: 1).first.map { Project(name: $0.name, path: $0.path) }
        }
    }
}
