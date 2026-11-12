// The month grids of the Custom range page, and the weekday and month
// arithmetic behind them.

import Foundation
import Testing
@testable import TrackerCore

@Test func weekdaysCountFromSunday() {
    #expect(Day(1970, 1, 1).weekday == 4)   // a Thursday
    #expect(Day(2000, 1, 1).weekday == 6)   // a Saturday
    #expect(Day(2024, 2, 29).weekday == 4)  // a leap day, a Thursday
    #expect(Day(2026, 11, 8).weekday == 0)  // a Sunday
    #expect(Day(2026, 11, 9).weekday == 1)  // the Monday after
    #expect(Day(1969, 12, 31).weekday == 3) // before 1970 too: a Wednesday
}

@Test func monthsHaveTheirOwnLengths() {
    #expect(Day(2026, 2, 10).daysInMonth == 28 && Day(2024, 2, 10).daysInMonth == 29)
    #expect(Day(2026, 11, 1).daysInMonth == 30 && Day(2026, 12, 31).daysInMonth == 31)
}

@Test func movingByMonthsLandsOnTheFirst() {
    #expect(Day(2026, 11, 9).firstOfMonth(adding: 0) == Day(2026, 11, 1))
    #expect(Day(2026, 11, 9).firstOfMonth(adding: 1) == Day(2026, 12, 1))
    #expect(Day(2026, 12, 31).firstOfMonth(adding: 1) == Day(2027, 1, 1))
    #expect(Day(2026, 1, 15).firstOfMonth(adding: -1) == Day(2025, 12, 1))
    #expect(Day(2026, 3, 31).firstOfMonth(adding: -13) == Day(2025, 2, 1))
    #expect(Day(2026, 3, 31).firstOfMonth(adding: 22) == Day(2028, 1, 1))
}

@Test func aMonthGridIsSixWeeksOfSeven() {
    for first in [Day(2026, 11, 1), Day(2026, 2, 1), Day(2024, 2, 1), Day(2026, 5, 1)] {
        for firstWeekday in 0...6 {
            let weeks = MonthGrid.weeks(of: first, firstWeekday: firstWeekday)
            #expect(weeks.count == 6 && weeks.allSatisfy { $0.count == 7 })
            let days = weeks.flatMap { $0 }.compactMap { $0 }
            #expect(days == (1...first.daysInMonth).map { Day(first.year, first.month, $0) })  // each day once, in order
        }
    }
}

@Test func aMonthGridStartsUnderTheRightWeekday() {
    // November 2026 starts on a Sunday.
    let sundayFirst = MonthGrid.weeks(of: Day(2026, 11, 1), firstWeekday: 0)
    #expect(sundayFirst[0].map { $0?.day } == [1, 2, 3, 4, 5, 6, 7])
    #expect(sundayFirst[4].map { $0?.day } == [29, 30, nil, nil, nil, nil, nil])
    #expect(sundayFirst[5].allSatisfy { $0 == nil })

    let mondayFirst = MonthGrid.weeks(of: Day(2026, 11, 1), firstWeekday: 1)
    #expect(mondayFirst[0].map { $0?.day } == [nil, nil, nil, nil, nil, nil, 1])
    #expect(mondayFirst[1].map { $0?.day } == [2, 3, 4, 5, 6, 7, 8])

    // February 2024 starts on a Thursday.
    #expect(MonthGrid.weeks(of: Day(2024, 2, 1), firstWeekday: 0)[0].map { $0?.day } == [nil, nil, nil, nil, 1, 2, 3])
    #expect(MonthGrid.weeks(of: Day(2024, 2, 1), firstWeekday: 4)[0].map { $0?.day } == [1, 2, 3, 4, 5, 6, 7])
}

@Test func weekdayColumnsStartWherever() {
    #expect(MonthGrid.weekdayOrder(firstWeekday: 0) == [0, 1, 2, 3, 4, 5, 6])
    #expect(MonthGrid.weekdayOrder(firstWeekday: 1) == [1, 2, 3, 4, 5, 6, 0])
    #expect(MonthGrid.weekdayOrder(firstWeekday: 6) == [6, 0, 1, 2, 3, 4, 5])
}

@Test func theRangePickerKeepsTheDatesInOrder() {
    var pick = RangePick(from: Day(2026, 11, 1), to: Day(2026, 11, 9), earliest: Day(2026, 10, 29), latest: Day(2026, 11, 9))

    pick.setFrom(Day(2026, 11, 5))
    #expect(pick.from == Day(2026, 11, 5) && pick.to == Day(2026, 11, 9))

    // A start after the end drags the end along.
    pick.setFrom(Day(2026, 11, 9))
    pick.setTo(Day(2026, 11, 9))
    pick.setFrom(Day(2026, 11, 8))
    pick.setTo(Day(2026, 11, 3))  // an end before the start drags the start along
    #expect(pick.from == Day(2026, 11, 3) && pick.to == Day(2026, 11, 3))

    // Days outside the data, and the future, can't be picked.
    pick.setFrom(Day(2025, 1, 1))
    #expect(pick.from == Day(2026, 10, 29))
    pick.setTo(Day(2027, 1, 1))
    #expect(pick.to == Day(2026, 11, 9))
}

@Test func theRangePickerKnowsWhatIsInsideTheRange() {
    let pick = RangePick(from: Day(2026, 11, 3), to: Day(2026, 11, 6), earliest: Day(2026, 10, 1), latest: Day(2026, 11, 9))

    #expect(pick.isInside(Day(2026, 11, 3)) && pick.isInside(Day(2026, 11, 5)) && pick.isInside(Day(2026, 11, 6)))
    #expect(!pick.isInside(Day(2026, 11, 2)) && !pick.isInside(Day(2026, 11, 7)))
    #expect(pick.canPick(Day(2026, 10, 1)) && pick.canPick(Day(2026, 11, 9)))
    #expect(!pick.canPick(Day(2026, 9, 30)) && !pick.canPick(Day(2026, 11, 10)))
    #expect(pick.dayCount == 4)
}
