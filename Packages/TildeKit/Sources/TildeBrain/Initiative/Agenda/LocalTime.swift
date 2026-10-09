import Foundation

/// Times as the agenda and goals write them, in the owner's time zone: `2026-10-09 17:00`.
/// Plain enough to read and edit by hand, exact enough to schedule from.
enum LocalTime {
    static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// `2026-10-09 17:00`; nil for anything else, including dates that don't exist.
    static func parse(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, let time = clock(parts[1]) else { return nil }
        let day = parts[0].split(separator: "-").compactMap { Int($0) }
        guard day.count == 3, day[0] >= 2000 else { return nil }
        let components = DateComponents(year: day[0], month: day[1], day: day[2], hour: time.hour, minute: time.minute)
        guard let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: day[0], month: day[1], day: day[2])
        else { return nil }
        return date
    }

    /// `09:00` or `9:00`.
    static func clock(_ text: some StringProtocol) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[1].count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
            (0..<24).contains(hour), (0..<60).contains(minute)
        else { return nil }
        return (hour, minute)
    }

    /// `17:00` today, `Fri 16:00` this week, the full stamp beyond that.
    static func describe(_ date: Date, from now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 {
            return "\(date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated))) \(time)"
        }
        return format(date, calendar: calendar)
    }
}
