import Foundation

/// A calendar day, like Python's `datetime.date`: no time, no time zone.
///
/// The usage buckets in state.json are keyed by `iso` ("2026-07-29"), and
/// "today" and a log entry's day are local dates, as Python's
/// `date.today()` and `datetime.astimezone().date()` give them.
public struct Day: Hashable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Python's `date.min` and `date.max`.
    public static let min = Day(1, 1, 1)
    public static let max = Day(9999, 12, 31)

    /// "2026-07-29" -> Day; nil if it isn't a valid date in that form.
    public init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), day >= 1, day <= Day.daysIn(month: month, year: year)
        else { return nil }
        self.init(year, month, day)
    }

    /// The local calendar day `timestamp` (Unix seconds) falls on.
    public init(timestamp: Double) {
        var seconds = time_t(timestamp.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        self.init(Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday))
    }

    /// Today, in the local time zone.
    public static func today(now: Double = Date().timeIntervalSince1970) -> Day {
        Day(timestamp: now)
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// This day moved by `days` (negative goes back), like `date + timedelta(days=n)`.
    public func adding(days: Int) -> Day {
        Day.fromOrdinal(ordinal + days)
    }

    /// The first of this day's month, like `date.replace(day=1)`.
    public var firstOfMonth: Day { Day(year, month, 1) }

    // MARK: - Day arithmetic (proleptic Gregorian, no time zones involved)

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func fromOrdinal(_ ordinal: Int) -> Day {
        let z = ordinal + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return Day(yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}

/// Local wall-clock times and ISO 8601 timestamps, as Python's `datetime`
/// reads and writes them.
public enum LocalTime {
    /// Unix seconds for a local wall-clock time, like
    /// `datetime(year, month, day, hour, minute, second).timestamp()`.
    public static func timestamp(_ year: Int, _ month: Int, _ day: Int,
                                 _ hour: Int = 0, _ minute: Int = 0, _ second: Double = 0) -> Double {
        var parts = tm()
        parts.tm_year = Int32(year - 1900)
        parts.tm_mon = Int32(month - 1)
        parts.tm_mday = Int32(day)
        parts.tm_hour = Int32(hour)
        parts.tm_min = Int32(minute)
        parts.tm_sec = 0
        parts.tm_isdst = -1  // let the system work out daylight saving time
        return Double(mktime(&parts)) + second
    }

    /// The local wall-clock parts of a Unix time.
    public static func parts(of timestamp: Double) -> (day: Day, hour: Int, minute: Int, second: Int) {
        var seconds = time_t(timestamp.rounded(.down))
        var parts = tm()
        localtime_r(&seconds, &parts)
        let day = Day(Int(parts.tm_year) + 1900, Int(parts.tm_mon) + 1, Int(parts.tm_mday))
        return (day, Int(parts.tm_hour), Int(parts.tm_min), Int(parts.tm_sec))
    }

    /// Unix seconds for an ISO 8601 timestamp such as
    /// "2026-07-29T12:00:00.000Z" or "2026-07-29T14:00:00+02:00", as
    /// `datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()` reads
    /// it. A timestamp without a zone is local time, as in Python. nil if it
    /// can't be read.
    public static func parseISO(_ text: String) -> Double? {
        var scanner = DigitScanner(Array(text.utf8))
        guard let year = scanner.number(4), scanner.skip("-"),
              let month = scanner.number(2), scanner.skip("-"),
              let day = scanner.number(2),
              (1...12).contains(month), day >= 1, day <= Day.daysIn(month: month, year: year)
        else { return nil }
        var hour = 0, minute = 0
        var second = 0.0
        if scanner.skip("T") || scanner.skip(" ") {
            guard let h = scanner.number(2), h < 24 else { return nil }
            hour = h
            if scanner.skip(":") {
                guard let m = scanner.number(2), m < 60 else { return nil }
                minute = m
                if scanner.skip(":") {
                    guard let s = scanner.number(2), s < 60 else { return nil }
                    second = Double(s) + scanner.fraction()
                }
            }
        }
        if scanner.atEnd {
            return timestamp(year, month, day, hour, minute, second)
        }
        guard let offset = scanner.zoneOffset(), scanner.atEnd else { return nil }
        let utcDay = Day(year, month, day)
        return Double(utcDay.ordinal * 86_400 + hour * 3600 + minute * 60) + second - Double(offset)
    }
}

/// Reads the digits and punctuation of an ISO 8601 timestamp.
private struct DigitScanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index == bytes.count }

    mutating func skip(_ character: Character) -> Bool {
        guard index < bytes.count, bytes[index] == character.asciiValue else { return false }
        index += 1
        return true
    }

    /// Exactly `count` digits as a number.
    mutating func number(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[index..<index + count] {
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        index += count
        return value
    }

    /// ".880" -> 0.88; 0 when there's no fraction.
    mutating func fraction() -> Double {
        guard skip(".") || skip(",") else { return 0 }
        var value = 0.0
        var scale = 0.1
        while index < bytes.count, (48...57).contains(bytes[index]) {
            value += Double(bytes[index] - 48) * scale
            scale /= 10
            index += 1
        }
        return value
    }

    /// "Z", "+02:00", "-0530" or "+02" -> seconds east of UTC.
    mutating func zoneOffset() -> Int? {
        if skip("Z") || skip("z") { return 0 }
        let sign: Int
        if skip("+") { sign = 1 } else if skip("-") { sign = -1 } else { return nil }
        guard let hours = number(2) else { return nil }
        var minutes = 0
        if !atEnd {
            _ = skip(":")
            guard let m = number(2) else { return nil }
            minutes = m
        }
        return sign * (hours * 3600 + minutes * 60)
    }
}
