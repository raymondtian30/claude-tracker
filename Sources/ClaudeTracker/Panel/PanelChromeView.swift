import AppKit
import SwiftUI
import TrackerCore

/// What the panel's top part shows. The selected tab changes without a
/// rebuild: only the tab bar's highlight moves.
final class PanelChrome: ObservableObject {
    @Published var selected: String
    let tabs: [Tab]
    let logo: NSImage?
    let subtitle: String
    let toolPicker: Item?
    let onSelectTab: (Int) -> Void
    let onAction: ActionHandler

    init(selected: String, tabs: [Tab], logo: NSImage?, subtitle: String, toolPicker: Item?,
         onSelectTab: @escaping (Int) -> Void, onAction: @escaping ActionHandler) {
        self.selected = selected
        self.tabs = tabs
        self.logo = logo
        self.subtitle = subtitle
        self.toolPicker = toolPicker
        self.onSelectTab = onSelectTab
        self.onAction = onAction
    }
}

/// The header, the tool picker (2+ tools) and the tab bar.
struct PanelChromeView: View {
    @ObservedObject var chrome: PanelChrome

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(logo: chrome.logo, subtitle: chrome.subtitle)
            if let picker = chrome.toolPicker {
                // Drawn 4 pt higher than its slot, as in the Python panel.
                ItemView(item: picker, width: PanelLayout.inner - 4, onAction: chrome.onAction)
                    .frame(width: PanelLayout.inner - 4, height: PanelLayout.height(of: picker), alignment: .topLeading)
                    .offset(x: 2, y: -4)
                    .frame(height: PanelLayout.toolPickerHeight, alignment: .top)
            }
            TabBar(tabs: chrome.tabs, selected: chrome.selected, onSelect: chrome.onSelectTab)
        }
        .padding(.top, PanelLayout.pad)
        .padding(.horizontal, PanelLayout.pad)
        .frame(width: PanelLayout.width, alignment: .topLeading)
    }
}

/// The selected AI's logo (or the coin), the app's name and a subtitle.
struct PanelHeaderView: View {
    let logo: NSImage?
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Group {
                if let logo = logo {
                    // Template images follow the text colour.
                    Image(nsImage: logo).renderingMode(logo.isTemplate ? .template : .original)
                        .resizable().foregroundColor(.label)
                } else {
                    Text(PanelLayout.coin).font(.system(size: 22))
                }
            }
            .frame(width: 28, height: 28)
            .padding(.top, 2)
            VStack(alignment: .leading, spacing: -1) {
                LabelText(text: Version.appName, size: 14, weight: .semibold, height: 18)
                LabelText(text: subtitle, size: 11, color: .secondaryLabel, height: 15)
            }
        }
        .frame(height: PanelLayout.headerHeight, alignment: .top)
    }
}

/// Icon tabs with captions. The selected one is accent-colored with a
/// bolder icon and an underline; a hairline runs under them all.
struct TabBar: View {
    let tabs: [Tab]
    let selected: String
    let onSelect: (Int) -> Void

    var body: some View {
        let slot = PanelLayout.inner / CGFloat(max(tabs.count, 1))
        let selectedIndex = tabs.firstIndex { $0.key == selected }
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        tabButton(tab, isSelected: tab.key == selected)
                            .frame(width: slot, height: PanelLayout.tabBarHeight, alignment: .top)
                            // Clicking anywhere on the tab switches to it.
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(index) }
                            .help(tab.title)
                            // One button per tab for VoiceOver (and other
                            // accessibility clients), as the tap gesture alone isn't.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(tab.title)
                            .accessibilityAddTraits(tab.key == selected ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { onSelect(index) }
                    }
                }
                if let index = selectedIndex {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accent)
                        .frame(width: slot * 0.5, height: 3)
                        .offset(x: CGFloat(index) * slot + slot * 0.25, y: PanelLayout.tabBarHeight - 3)
                }
            }
            .frame(height: PanelLayout.tabBarHeight, alignment: .topLeading)
            Rectangle().fill(Color.faint(0.1)).frame(height: 1)
        }
    }

    private func tabButton(_ tab: Tab, isSelected: Bool) -> some View {
        let tint: Color = isSelected ? .accent : .secondaryLabel
        let weight: Font.Weight = isSelected ? .semibold : .regular
        return VStack(spacing: 0) {
            Symbol(name: tab.icon, size: 16, weight: weight, color: tint).frame(height: 26)
            Text(tab.short)
                .font(.panel(9, weight))
                .foregroundColor(tint)
                .lineLimit(1)
                .frame(height: 13)
        }
    }
}
