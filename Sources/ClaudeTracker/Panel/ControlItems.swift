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
                .controlSize(.small)
                .frame(width: 40, height: 22)
                .padding(.top, 3)
        }
    }
}

/// "From" and "To" date fields side by side. They are plain text fields with
/// a stepper (no pop-up calendar, which the panel can't hold open); typing a
/// date or stepping it sends the new day. Nothing after `latest` can be set.
struct DateRangeItem: View {
    let from: Day
    let to: Day
    let earliest: Day
    let latest: Day
    let onAction: ActionHandler

    var body: some View {
        HStack(spacing: 6) {
            LabelText(text: "From").frame(width: 34, alignment: .leading)
            DateField(day: from, earliest: earliest, latest: latest) { onAction("chart_from", .text($0.iso)) }
            LabelText(text: "To").frame(width: 20, alignment: .leading).padding(.leading, 4)
            DateField(day: to, earliest: earliest, latest: latest) { onAction("chart_to", .text($0.iso)) }
        }
        .frame(maxWidth: .infinity, minHeight: 26, maxHeight: 26, alignment: .leading)
    }
}

/// One date field. Typing a date changes it a digit at a time, and every
/// change redraws the panel (which would end the typing), so the new day is
/// sent once the field has been still for a moment.
private struct DateField: View {
    let day: Day
    let earliest: Day
    let latest: Day
    let picked: (Day) -> Void
    @State private var typed: Date?
    @State private var waiting: DispatchWorkItem?

    private static let stillSeconds = 0.7

    private static func date(_ day: Day) -> Date {
        Calendar.current.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? Date()
    }

    var body: some View {
        DatePicker("", selection: Binding(
            get: { typed ?? Self.date(day) },
            set: { new in
                typed = new
                waiting?.cancel()
                let send = DispatchWorkItem { picked(Day(timestamp: new.timeIntervalSince1970)) }
                waiting = send
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillSeconds, execute: send)
            }),
                   in: Self.date(earliest)...Self.date(latest), displayedComponents: .date)
            .datePickerStyle(.field)
            .labelsHidden()
            .frame(maxWidth: .infinity)
    }
}
