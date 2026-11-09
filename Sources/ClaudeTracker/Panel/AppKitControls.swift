import AppKit
import SwiftUI

// AppKit controls for the SwiftUI items. Each reports the user's change
// through `changed`; the model's value is set on creation and when the app
// renders again.

/// An NSSegmentedControl with equal segments: pick one, or any number.
struct SegmentedControl: NSViewRepresentable {
    let options: [String]
    let selected: [Int]
    let multiple: Bool
    var small = false
    let changed: ([Int]) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options, trackingMode: multiple ? .selectAny : .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        if small {
            control.controlSize = .small
            control.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        update(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        update(control)
    }

    private func update(_ control: NSSegmentedControl) {
        for index in 0..<control.segmentCount {
            control.setSelected(selected.contains(index), forSegment: index)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SegmentedControl

        init(_ parent: SegmentedControl) { self.parent = parent }

        @objc func changed(_ sender: NSSegmentedControl) {
            parent.changed((0..<sender.segmentCount).filter { sender.isSelected(forSegment: $0) })
        }
    }
}

/// An NSPopUpButton.
struct PopUpControl: NSViewRepresentable {
    let options: [String]
    let selected: Int
    let changed: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: options)
        popup.selectItem(at: selected)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.changed(_:))
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popup
    }

    func updateNSView(_ popup: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        if popup.itemTitles != options {
            popup.removeAllItems()
            popup.addItems(withTitles: options)
        }
        popup.selectItem(at: selected)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PopUpControl

        init(_ parent: PopUpControl) { self.parent = parent }

        @objc func changed(_ sender: NSPopUpButton) {
            parent.changed(sender.indexOfSelectedItem)
        }
    }
}

/// A small NSSwitch.
struct SwitchControl: NSViewRepresentable {
    let isOn: Bool
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.state = isOn ? .on : .off
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        return control
    }

    func updateNSView(_ control: NSSwitch, context: Context) {
        context.coordinator.parent = self
        control.state = isOn ? .on : .off
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SwitchControl

        init(_ parent: SwitchControl) { self.parent = parent }

        @objc func changed(_ sender: NSSwitch) {
            parent.changed(sender.state == .on)
        }
    }
}

/// An NSButton: a push button with an optional leading SF Symbol, or (with
/// `iconOnly`) a subtle icon button like the footer's.
struct PushButton: NSViewRepresentable {
    let title: String
    let icon: String?
    var iconOnly = false
    var tooltip: String?
    let clicked: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        if let icon = icon, let image = NSImage(systemSymbolName: icon, accessibilityDescription: tooltip) {
            button.image = image.withSymbolConfiguration(.init(pointSize: iconOnly ? 13 : 12, weight: .regular))
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        }
        if iconOnly {
            // Raw value 15, as panel_view.py set it: a subtle rounded button.
            button.bezelStyle = NSButton.BezelStyle(rawValue: 15) ?? .inline
            button.contentTintColor = .secondaryLabelColor
        }
        button.toolTip = tooltip
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: PushButton

        init(_ parent: PushButton) { self.parent = parent }

        @objc func clicked() {
            parent.clicked()
        }
    }
}
