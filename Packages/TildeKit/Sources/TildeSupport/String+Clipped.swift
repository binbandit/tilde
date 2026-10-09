extension String {
    /// Shortened to `limit` characters, ending in an ellipsis when cut. By default
    /// only the first line is kept, which suits tickers and log lines.
    public func clipped(to limit: Int, keepLines: Bool = false) -> String {
        let line = keepLines ? self : split(separator: "\n").first.map(String.init) ?? self
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
