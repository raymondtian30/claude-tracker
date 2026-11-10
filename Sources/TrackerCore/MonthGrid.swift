import Foundation

extension Day {
    /// 0 = Sunday ... 6 = Saturday.
    public var weekday: Int {
        // Day 0 (1970-01-01) was a Thursday; `%` of a negative count goes negative.
        ((ordinal % 7) + 7 + 4) % 7
    }

    /// How many days this day's month has.
    public var daysInMonth: Int { Day.daysIn(month: month, year: year) }

    /// The first of the month `months` away from this day's month (negative
    /// goes back).
    public func firstOfMonth(adding months: Int) -> Day {
        let total = year * 12 + (month - 1) + months
        let newYear = total >= 0 ? total / 12 : -((-total + 11) / 12)
        return Day(newYear, total - newYear * 12 + 1, 1)
    }
}

/// The calendar of one month, for the Custom range page.
public enum MonthGrid {
    /// The month starting on `first`, as 6 weeks of 7 days (a blank, nil, where
    /// the week belongs to the month before or after), so every month is as
    /// tall as every other. `firstWeekday` is the column the weeks start on
    /// (0 = Sunday ... 6 = Saturday).
    public static func weeks(of first: Day, firstWeekday: Int) -> [[Day?]] {
        let lead = ((first.weekday - firstWeekday) % 7 + 7) % 7
        var cells = [Day?](repeating: nil, count: lead)
        cells += (1...first.daysInMonth).map { Day(first.year, first.month, $0) }
        cells += [Day?](repeating: nil, count: Swift.max(42 - cells.count, 0))
        return stride(from: 0, to: 42, by: 7).map { Array(cells[$0..<$0 + 7]) }
    }

    /// The weekdays (0 = Sunday ...) in column order for weeks starting on `firstWeekday`.
    public static func weekdayOrder(firstWeekday: Int) -> [Int] {
        (0..<7).map { (firstWeekday + $0) % 7 }
    }
}

/// The two dates being picked on the Custom range page. They stay in order
/// (picking a start after the end moves the end, and the other way round),
/// and inside the days with data and today.
public struct RangePick: Equatable {
    public private(set) var from: Day
    public private(set) var to: Day
    public let earliest: Day
    public let latest: Day

    public init(from: Day, to: Day, earliest: Day, latest: Day) {
        self.earliest = Swift.min(earliest, latest)
        self.latest = latest
        let (a, b) = (Swift.min(Swift.max(from, self.earliest), latest), Swift.min(Swift.max(to, self.earliest), latest))
        self.from = Swift.min(a, b)
        self.to = Swift.max(a, b)
    }

    private func clamped(_ day: Day) -> Day { Swift.min(Swift.max(day, earliest), latest) }

    public mutating func setFrom(_ day: Day) {
        from = clamped(day)
        if from > to { to = from }
    }

    public mutating func setTo(_ day: Day) {
        to = clamped(day)
        if to < from { from = to }
    }

    /// Whether `day` is from the start to the end, both included.
    public func isInside(_ day: Day) -> Bool { from <= day && day <= to }

    /// Whether `day` can be picked.
    public func canPick(_ day: Day) -> Bool { earliest <= day && day <= latest }

    /// How many days the range has.
    public var dayCount: Int { from.days(to: to) + 1 }
}
