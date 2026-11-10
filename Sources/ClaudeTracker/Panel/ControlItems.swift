import AppKit
import SwiftUI
import TrackerCore

// The control items: buttons, segmented, popup, switch and choices. Pickers
// and switches are the AppKit controls themselves (in AppKitControls.swift):
// SwiftUI has no multi-select segmented control, and these keep the
// Python panel's look exactly.

/// Push buttons sharing a row equally.
struct ButtonsItem: View {
    let buttons: [Item.Button]
    let onAction: ActionHandler

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                PushButton(title: button.title, icon: button.icon) { onAction(button.action, .none) }
                    .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26)
            }
        }
    }
}

/// A control's label on the left, 13 pt at y+5.
private struct ControlLabel: View {
    let text: String?

    var body: some View {
        if let text = text {
            LabelText(text: text).padding(.top, 5)
        }
    }
}

/// One choice from a row of segments, after a 90 pt label (if any).
struct SegmentedItem: View {
    let label: String?
    let options: [String]
    let selected: Int
    let action: String
    let onAction: ActionHandler

    var body: some View {
        ZStack(alignment: .topLeading) {
            ControlLabel(text: label)
            SegmentedControl(options: options, selected: [selected], multiple: false) { picked in
                onAction(action, .index(picked.first ?? 0))
            }
            .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
            .padding(.leading, label == nil ? 0 : 90)
            .padding(.top, 2)
        }
    }
}

/// A label over a full-width row of segments, any number of them on.
struct ChoicesItem: View {
    let label: String?
    let options: [String]
    let selected: [Int]
    let action: String
    let onAction: ActionHandler

    var body: some View {
        ZStack(alignment: .topLeading) {
            ControlLabel(text: label)
            // Small, so seven percentages fit across a card without spilling over.
            SegmentedControl(options: options, selected: selected, multiple: true, small: true) { picked in
                onAction(action, .indices(picked))
            }
            .controlSize(.small)  // SwiftUI hands its control size to AppKit controls
            .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
            .padding(.top, 27)
        }
    }
}

/// A label with a 140 pt dropdown on the right.
struct PopupItem: View {
    let label: String?
    let options: [String]
    let selected: Int
    let action: String
    let onAction: ActionHandler

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ControlLabel(text: label)
            PopUpControl(options: options, selected: selected) { onAction(action, .index($0)) }
                .frame(width: 140, height: 26)
                .padding(.top, 1)
        }
    }
}

/// A label with a small switch on the right.
struct SwitchItem: View {
    let label: String
    let isOn: Bool
    let action: String
    let onAction: ActionHandler

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ControlLabel(text: label)
            SwitchControl(isOn: isOn) { onAction(action, .bool($0)) }
                .frame(width: 34, height: 20)
                .padding(.top, 4)
        }
    }
}

/// What was typed into the date fields but not applied yet. A redraw (new
/// numbers arriving, say) rebuilds the fields, which must not lose it.
@MainActor
enum DateDraft {
    private static var base: (from: Day, to: Day)?
    private static var from: Day?
    private static var to: Day?

    /// The dates to show: the draft if the applied dates are still the ones it
    /// was made from, else the applied ones (and the draft starts again).
    static func dates(from applied: (from: Day, to: Day)) -> (from: Day, to: Day) {
        if let base = base, base.from == applied.from, base.to == applied.to, let from = from, let to = to {
            return (from, to)
        }
        base = applied
        (from, to) = (applied.from, applied.to)
        return applied
    }

    static func set(from newFrom: Day? = nil, to newTo: Day? = nil) {
        from = newFrom ?? from
        to = newTo ?? to
    }
}

/// "From" and "To" date fields and a check mark. The fields are plain text
/// fields with a stepper (no pop-up calendar, which the panel can't hold
/// open). Nothing changes until the check mark is clicked: typing a date takes
/// a few keystrokes, and the chart must not jump around meanwhile.
struct DateRangeItem: View {
    let applied: (from: Day, to: Day)
    let earliest: Day
    let latest: Day
    let onAction: ActionHandler
    @State private var from: Day
    @State private var to: Day

    init(from: Day, to: Day, earliest: Day, latest: Day, onAction: @escaping ActionHandler) {
        applied = (from, to)
        self.earliest = earliest
        self.latest = latest
        self.onAction = onAction
        let draft = DateDraft.dates(from: (from, to))
        _from = State(initialValue: draft.from)
        _to = State(initialValue: draft.to)
    }

    var body: some View {
        HStack(spacing: 6) {
            LabelText(text: "From").frame(width: 32, alignment: .leading)
            DateField(day: $from, earliest: earliest, latest: latest) { DateDraft.set(from: $0) }
            LabelText(text: "To").frame(width: 18, alignment: .leading)
            DateField(day: $to, earliest: earliest, latest: latest) { DateDraft.set(to: $0) }
            PushButton(title: "", icon: "checkmark", iconOnly: true, tooltip: "Show this range") {
                onAction("chart_range", .text("\(from.iso),\(to.iso)"))
            }
            .frame(width: 28, height: 24)
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
    }
}

private struct DateField: View {
    @Binding var day: Day
    let earliest: Day
    let latest: Day
    let changed: (Day) -> Void

    private static func date(_ day: Day) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    var body: some View {
        DatePicker("", selection: Binding(
            get: { Self.date(day) },
            set: { new in
                day = Day(timestamp: new.timeIntervalSince1970)
                changed(day)
            }),
                   in: Self.date(earliest)...Self.date(latest), displayedComponents: .date)
            .datePickerStyle(.field)
            .labelsHidden()
            .frame(maxWidth: .infinity)
    }
}
