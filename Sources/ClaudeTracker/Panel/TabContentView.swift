import AppKit
import SwiftUI
import TrackerCore

/// A tab's cards with the footer under them.
struct TabContentView: View {
    let tab: Tab
    let footer: String
    let onAction: ActionHandler

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardStack(cards: tab.cards, onAction: onAction)
            FooterView(text: footer, onAction: onAction)
        }
        .padding(.horizontal, PanelLayout.pad)
        .frame(width: PanelLayout.width, height: PanelLayout.tabContentHeight(tab), alignment: .topLeading)
    }
}

/// "Tracking since ..." with the Settings and Quit buttons.
struct FooterView: View {
    let text: String
    let onAction: ActionHandler

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Color.faint(0.1)).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                Symbol(name: "calendar", size: 11, color: .secondaryLabel)
                    .frame(width: 14, height: 14)
                    .padding(.leading, 2)
                    .padding(.top, 5)
                LabelText(text: text, size: 11, color: .secondaryLabel, height: 16)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                HStack(spacing: 2) {
                    ForEach(PanelLayout.footerButtons, id: \.action) { button in
                        PushButton(title: "", icon: button.icon, iconOnly: true, tooltip: button.tip) {
                            onAction(button.action, .none)
                        }
                        .frame(width: 28, height: 24)
                    }
                }
                .padding(.trailing, 2)
            }
            .padding(.top, 8)
        }
        .frame(height: PanelLayout.footerHeight, alignment: .top)
    }
}

/// The first-run picker: the header, then a title over the tab's cards,
/// without tabs or footer.
struct WelcomeView: View {
    let tab: Tab
    let logo: NSImage?
    let subtitle: String
    let onAction: ActionHandler

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(logo: logo, subtitle: subtitle)
            LabelText(text: tab.title, size: 15, weight: .semibold, height: 20)
                .padding(.leading, 2)
                .padding(.top, 4)
                .frame(height: PanelLayout.welcomeTitleHeight, alignment: .top)
            CardStack(cards: tab.cards, onAction: onAction)
        }
        .padding(PanelLayout.pad)
        .frame(width: PanelLayout.width, height: PanelLayout.welcomeHeight(tab), alignment: .topLeading)
    }
}

/// The Settings window's cards.
struct SettingsContentView: View {
    let settings: Tab
    let onAction: ActionHandler

    var body: some View {
        CardStack(cards: settings.cards, onAction: onAction)
            .padding(PanelLayout.pad)
            .frame(width: PanelLayout.width, height: PanelLayout.settingsHeight(settings), alignment: .topLeading)
    }
}
