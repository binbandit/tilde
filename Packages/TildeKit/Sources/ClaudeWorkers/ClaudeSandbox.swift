import TildeSupport

/// Claude Code's sandbox, as workers run it: their shell commands can write only inside the
/// job (its worktree, the repo's git directory so commits land, and the caches build tools
/// expect) and reach only the hosts development needs. Without it, a command like a plugin
/// reinstall can rewrite the owner's settings, which the rails can't see in a shell line.
///
/// Leaving the sandbox (`dangerouslyDisableSandbox`) is a rail; opening it to another host is
/// a request tilde decides. In auto mode Claude would otherwise retry both without asking.
public enum ClaudeSandbox {
    /// Where build and package tools keep their caches.
    static let caches = [
        "~/Library/Caches", "~/Library/Developer/Xcode/DerivedData", "~/.cache", "~/.npm", "~/Library/pnpm",
        "~/.bun/install/cache", "~/.cargo/registry", "~/.cargo/git", "~/go/pkg/mod", "~/.gradle/caches",
    ]

    /// Package registries and source hosts.
    static let hosts = [
        "github.com", "*.github.com", "*.githubusercontent.com", "registry.npmjs.org", "*.npmjs.org", "registry.yarnpkg.com",
        "pypi.org", "files.pythonhosted.org", "crates.io", "*.crates.io", "proxy.golang.org", "sum.golang.org", "rubygems.org",
        "*.rubygems.org", "bun.sh", "jsr.io", "deno.land", "swiftpackageindex.com", "cdn.cocoapods.org",
    ]

    /// `--settings` for a worker that may also write to `writable`.
    public static func settings(writable: [String]) -> JSON {
        [
            "sandbox": [
                "enabled": true,
                // Inside the sandbox a command can't reach anything that matters, so it needn't ask.
                "autoAllowBashIfSandboxed": true,
                // A repo's git directory is writable so commits land (and installers that set up hooks work);
                // what in it makes git run code is put back after each turn (GitGuard).
                "filesystem": ["allowWrite": .array((writable + caches).map { .string($0) })],
                // Dev servers listen on localhost.
                "network": ["allowedDomains": .array(hosts.map { .string($0) }), "allowLocalBinding": true],
            ],
        ]
    }

    /// The hosts a command asks the sandbox to let it reach, if any.
    static func newHosts(_ input: JSON) -> [String]? {
        let hosts = (input["allowed_domains"]?.array ?? []).compactMap(\.string)
        return hosts.isEmpty ? nil : hosts
    }
}
