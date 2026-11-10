import AppKit
import SwiftUI
import TrackerCore

/// What was picked on the Custom range page but not applied yet. A redraw
/// (new numbers arriving, say) rebuilds the page, which must not lose it.
@MainActor
enum RangeDraft {
    private static var base: RangePick?
    private static var draft: RangePick?

    /// The dates to show: the draft, if the page was built from the same
    /// range and days as it was; else `built`, and the draft starts again.
    static func pick(for built: RangePick) -> RangePick {
        if let base = base, base == built, let draft = draft { return draft }
        base = built
        draft = built
        return built
    }

    static func save(_ pick: RangePick) { draft = pick }

    /// Forget it: the page was opened, applied or cancelled.
    static func clear() {
        base = nil
        draft = nil
    }
}

/// The Custom range page: a calendar for the start and one for the end,
/// side by side, so both dates are in view. The days between them are tinted
/// in both. Nothing changes until Apply is clicked.
struct RangePickerItem: View {
    let onAction: ActionHandler
    @State private var pick: RangePick
    @State private var fromMonth: Day
    @State private var toMonth: Day

    private static let gap: CGFloat = 18

    init(from: Day, to: Day, earliest: Day, latest: Day, onAction: @escaping ActionHandler) {
        self.onAction = onAction
        let start = RangeDraft.pick(for: RangePick(from: from, to: to, earliest: earliest, latest: latest))
        _pick = State(initialValue: start)
        _fromMonth = State(initialValue: start.from.firstOfMonth(adding: 0))
        _toMonth = State(initialValue: start.to.firstOfMonth(adding: 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Self.gap) {
                CalendarMonth(title: "From", selected: pick.from, pick: pick, month: $fromMonth) { day in
                    pick.setFrom(day)
                    toMonth = pick.to.firstOfMonth(adding: 0)  // the end may have moved with it
                    RangeDraft.save(pick)
                }
                CalendarMonth(title: "To", selected: pick.to, pick: pick, month: $toMonth) { day in
                    pick.setTo(day)
                    fromMonth = pick.from.firstOfMonth(adding: 0)
                    RangeDraft.save(pick)
                }
            }
            .frame(height: CalendarMonth.height, alignment: .top)

            Text(summary)
                .font(.panel(12, .semibold, digits: true))
                .foregroundColor(.accent)
                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .center)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Text("Cancel")
                    .font(.panel(13, .medium))
                    .foregroundColor(.label)
                    .frame(width: 84, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.faint(0.1)))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        RangeDraft.clear()
                        onAction("chart_cancel", .none)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Cancel")
                    .accessibilityAddTraits(.isButton)
                // Big and in the accent colour: this is the button that does it.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    Text("Apply").font(.panel(13, .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accent))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture {
                    RangeDraft.clear()
                    onAction("chart_range", .text("\(pick.from.iso),\(pick.to.iso)"))
                }
                .accessibilityElement()
                .accessibilityLabel("Apply range")
                .accessibilityAddTraits(.isButton)
            }
            .frame(height: 34, alignment: .top)
            .padding(.top, 8)
        }
    }

    private var summary: String {
        let days = pick.dayCount
        let dates = pick.from == pick.to ? PanelModel.formatShortDate(pick.from)
            : "\(PanelModel.formatShortDate(pick.from)) – \(PanelModel.formatShortDate(pick.to))"
        return "\(dates) · \(days) day\(days == 1 ? "" : "s")"
    }
}

/// One month of days. The picked day is filled, the other end of the range is
/// outlined, the days between are tinted, and days that can't be picked are dim.
private struct CalendarMonth: View {
    let title: String
    let selected: Day
    let pick: RangePick
    @Binding var month: Day
    let onPick: (Day) -> Void

    static let cell: CGFloat = 21
    static let height: CGFloat = 196  // the title, the month's name, the weekdays and 6 weeks
    private var firstWeekday: Int { Calendar.current.firstWeekday - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabelText(text: title, size: 11, weight: .semibold, color: .secondaryLabel, height: 16)
                .padding(.top, 4)
            header
            weekdays
            VStack(spacing: 0) {
                ForEach(Array(MonthGrid.weeks(of: month, firstWeekday: firstWeekday).enumerated()), id: \.offset) { _, week in
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            dayCell(day)
                        }
                    }
                }
            }
        }
        .frame(width: 7 * Self.cell, height: Self.height, alignment: .topLeading)
    }

    private var header: some View {
        let canGoBack = month > pick.earliest.firstOfMonth(adding: 0)
        let canGoOn = month < pick.latest.firstOfMonth(adding: 0)
        return HStack(spacing: 0) {
            arrow("chevron.left", enabled: canGoBack) { month = month.firstOfMonth(adding: -1) }
            Text("\(Calendar.current.standaloneMonthSymbols[month.month - 1]) \(String(month.year))")
                .font(.panel(12, .semibold))
                .foregroundColor(.label)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
            arrow("chevron.right", enabled: canGoOn) { month = month.firstOfMonth(adding: 1) }
        }
        .frame(height: 24)
    }

    private func arrow(_ symbol: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(enabled ? .label : .tertiaryLabel)
            .frame(width: 22, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { if enabled { action() } }
            .accessibilityElement()
            .accessibilityLabel(symbol == "chevron.left" ? "Previous month" : "Next month")
            .accessibilityAddTraits(.isButton)
    }

    private var weekdays: some View {
        let symbols = Calendar.current.veryShortStandaloneWeekdaySymbols
        return HStack(spacing: 0) {
            ForEach(Array(MonthGrid.weekdayOrder(firstWeekday: firstWeekday).enumerated()), id: \.offset) { _, weekday in
                Text(symbols[weekday])
                    .font(.panel(10, .medium))
                    .foregroundColor(.secondaryLabel)
                    .frame(width: Self.cell, height: 16)
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Day?) -> some View {
        if let day = day {
            let isPicked = day == selected
            let isOtherEnd = !isPicked && (day == pick.from || day == pick.to)
            let canPick = pick.canPick(day)
            ZStack {
                if pick.isInside(day) {
                    Rectangle().fill(Color.accent.opacity(0.16))
                }
                if isPicked {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accent).padding(1)
                } else if isOtherEnd {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accent, lineWidth: 1.5).padding(1)
                }
                Text(String(day.day))
                    .font(.panel(11, isPicked ? .bold : .regular, digits: true))
                    .foregroundColor(isPicked ? .white : (canPick ? .label : .tertiaryLabel))
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Rectangle())
            .onTapGesture { if canPick { onPick(day) } }
            .accessibilityElement()
            .accessibilityLabel("\(PanelModel.formatShortDate(day)), \(day.year)")
            .accessibilityAddTraits(canPick ? .isButton : [])
        } else {
            Color.clear.frame(width: Self.cell, height: Self.cell)
        }
    }
}
