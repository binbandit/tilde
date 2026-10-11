import Foundation

extension Date {
    /// The day it falls on here, as `2026-10-12`: what names a day's conversation, journal and notes.
    /// (`.iso8601` alone is UTC, which puts the small hours, and in some places the whole morning, on
    /// the day before.)
    public var day: String { day(in: .current) }

    public func day(in zone: TimeZone) -> String { formatted(Date.ISO8601FormatStyle(timeZone: zone).year().month().day()) }
}
