import Foundation
import Testing
@testable import TildeSupport

@Suite struct DayTests {
    /// Half past midnight in Melbourne is the previous afternoon in UTC; it's still the new day there.
    @Test func aDayIsNamedWhereYouAre() throws {
        let melbourne = try #require(TimeZone(identifier: "Australia/Melbourne"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = melbourne
        let early = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 0, minute: 30)))
        #expect(early.day(in: melbourne) == "2026-10-12")
        #expect(early.formatted(.iso8601.year().month().day()) == "2026-10-11")  // what it used to be called
    }
}
