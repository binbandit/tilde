import Foundation

/// Follow-ups and routines, kept in the notebook's `agenda.md` as one bullet each that starts
/// with when it's due:
///
///     ## Follow-ups
///     - 2026-10-09 17:00 check on the nav bar (j-n8v3)
///
///     ## Routines
///     - every weekday 09:00 morning brief
///     - every friday 16:00 what shipped this week
///
/// The file stays the owner's: anything that isn't an item (headings, notes, a bullet tilde can't
/// read) is kept exactly as written, and tilde only ever adds or removes whole lines.
public struct Agenda: Sendable, Equatable {
    public struct Item: Sendable, Hashable {
        public enum When: Sendable, Hashable {
            /// Once, at a local time.
            case once(Date)
            /// Again and again, at `hour:minute` on the matching days.
            case every(Days, hour: Int, minute: Int)
        }

        public enum Days: String, Sendable, CaseIterable {
            case day, weekday, weekend, monday, tuesday, wednesday, thursday, friday, saturday, sunday

            /// Lenient about plurals and case: "Fridays" is `friday`.
            init?(word: some StringProtocol) {
                let word = word.lowercased()
                guard let days = Days(rawValue: word) ?? (word.hasSuffix("s") ? Days(rawValue: String(word.dropLast())) : nil)
                else { return nil }
                self = days
            }

            /// `weekday` is Calendar's: 1 is Sunday, 7 is Saturday.
            func includes(weekday: Int) -> Bool {
                switch self {
                case .day: true
                case .weekday: (2...6).contains(weekday)
                case .weekend: weekday == 1 || weekday == 7
                default: Self.week.firstIndex(of: self).map { $0 + 1 == weekday } ?? false
                }
            }

            private static let week: [Days] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
        }

        public var when: When
        public var text: String

        public init(when: When, text: String) {
            self.when = when
            self.text = text
        }

        /// One agenda bullet; nil for anything that isn't one.
        public init?(line: String, calendar: Calendar = .current) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
            guard let parsed = Self.parse(trimmed.dropFirst(2).split(separator: " ")[...], calendar: calendar), !parsed.rest.isEmpty
            else { return nil }
            when = parsed.when
            text = parsed.rest.joined(separator: " ")
        }

        /// The when at the start of `words`, and the words after it.
        fileprivate static func parse(_ words: ArraySlice<Substring>, calendar: Calendar) -> (when: When, rest: ArraySlice<Substring>)? {
            var words = words
            if words.first?.lowercased() == "every" {
                guard words.count >= 3, let days = Days(word: words[words.startIndex + 1]) else { return nil }
                words = words.dropFirst(2)
                if words.first?.lowercased() == "at" { words = words.dropFirst() }
                guard let time = words.first.flatMap({ LocalTime.clock($0) }) else { return nil }
                return (.every(days, hour: time.hour, minute: time.minute), words.dropFirst())
            }
            guard words.count >= 2, let date = LocalTime.parse("\(words[words.startIndex]) \(words[words.startIndex + 1])", calendar: calendar)
            else { return nil }
            return (.once(date), words.dropFirst(2))
        }

        public var isRoutine: Bool {
            if case .every = when { true } else { false }
        }

        /// The when, written the way agenda.md writes it.
        public func schedule(calendar: Calendar = .current) -> String {
            switch when {
            case .once(let date): LocalTime.format(date, calendar: calendar)
            case .every(let days, let hour, let minute): String(format: "every %@ %02d:%02d", days.rawValue, hour, minute)
            }
        }

        public func line(calendar: Calendar = .current) -> String { "- \(schedule(calendar: calendar)) \(text)" }

        /// The job a follow-up is about, written `(j-n8v3)`, so its notes come along.
        public var job: String? {
            text.firstMatch(of: /\((j-[a-z0-9]{3,8})\)/).map { String($0.1) }
        }

        /// When it was most recently due, at or before `now`: the time itself for a one-off that
        /// has passed, the latest occurrence for a routine (looking back a week).
        public func latest(atOrBefore now: Date, calendar: Calendar = .current) -> Date? {
            switch when {
            case .once(let date):
                return date <= now ? date : nil
            case .every(let days, let hour, let minute):
                let today = calendar.startOfDay(for: now)
                for back in 0...7 {
                    guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                        days.includes(weekday: calendar.component(.weekday, from: day)),
                        let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), at <= now
                    else { continue }
                    return at
                }
                return nil
            }
        }

        /// When it's next due, after `now`.
        public func next(after now: Date, calendar: Calendar = .current) -> Date? {
            switch when {
            case .once(let date):
                return date > now ? date : nil
            case .every(let days, let hour, let minute):
                let today = calendar.startOfDay(for: now)
                for ahead in 0...8 {
                    guard let day = calendar.date(byAdding: .day, value: ahead, to: today),
                        days.includes(weekday: calendar.component(.weekday, from: day)),
                        let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), at > now
                    else { continue }
                    return at
                }
                return nil
            }
        }
    }

    /// The whole file, as written.
    public private(set) var text: String
    private let calendar: Calendar

    public init(text: String? = nil, calendar: Calendar = .current) {
        self.text = text ?? Self.seed
        self.calendar = calendar
    }

    public var items: [Item] {
        text.components(separatedBy: "\n").compactMap { Item(line: $0, calendar: calendar) }
    }

    /// Adds the item at the end of its section (Follow-ups or Routines), creating the section if needed.
    public mutating func add(_ item: Item) {
        var lines = text.components(separatedBy: "\n")
        let heading = item.isRoutine ? "Routines" : "Follow-ups"
        let isHeading = { (line: String) in
            line.hasPrefix("## ") && line.dropFirst(3).trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(heading) == .orderedSame
        }
        if let start = lines.firstIndex(where: isHeading) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
            var at = lines[(start + 1)..<end].lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0 + 1 } ?? start + 1
            if at == start + 1 {
                lines.insert("", at: at)
                at += 1
            }
            lines.insert(item.line(calendar: calendar), at: at)
            if at + 1 < lines.count, lines[at + 1].hasPrefix("#") { lines.insert("", at: at + 1) }
        } else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            lines += ["", "## \(heading)", "", item.line(calendar: calendar)]
        }
        text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
    }

    /// Removes the line holding `item`; false if it isn't there.
    @discardableResult
    public mutating func remove(_ item: Item) -> Bool {
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { Item(line: $0, calendar: calendar) == item }) else { return false }
        lines.remove(at: index)
        text = lines.joined(separator: "\n")
        return true
    }

    public static func == (a: Agenda, b: Agenda) -> Bool { a.text == b.text }

    static let seed = """
        # Agenda

        Follow-ups and routines, one per line, each starting with when it's due: a date and time for a \
        one-off (2026-10-09 17:00), or "every day / weekday / weekend / monday ... sunday" and a time for a \
        routine (every friday 16:00). tilde brings each up when it comes due, and drops one-offs once it has.

        ## Follow-ups

        ## Routines

        """
}

extension Agenda.Item.When {
    /// Just a when, nothing after it: `2026-10-09 17:00` or `every friday 16:00`.
    public init?(_ text: String, calendar: Calendar = .current) {
        guard let parsed = Agenda.Item.parse(text.split(separator: " ")[...], calendar: calendar), parsed.rest.isEmpty else { return nil }
        self = parsed.when
    }
}
