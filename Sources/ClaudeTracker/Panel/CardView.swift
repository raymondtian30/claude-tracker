import SwiftUI
import TrackerCore

/// A rounded card with an optional title over its items. A card of tiles
/// alone is drawn without the box: tiles are already boxes.
struct CardView: View {
    let card: Card
    let onAction: ActionHandler

    var body: some View {
        if PanelLayout.isBareTiles(card), case let .tiles(tiles) = card.items[0] {
            TilesView(tiles: tiles, width: PanelLayout.inner)
        } else {
            boxed
        }
    }

    private var boxed: some View {
        let width = PanelLayout.inner - 2 * PanelLayout.cardPad
        return VStack(alignment: .leading, spacing: 0) {
            if let title = card.title {
                LabelText(text: title, weight: .semibold, color: .secondaryLabel)
                    .frame(height: PanelLayout.cardTitleHeight, alignment: .top)
            }
            ForEach(Array(card.items.enumerated()), id: \.offset) { _, item in
                ItemView(item: item, width: width, onAction: onAction)
                    .frame(width: width, height: PanelLayout.height(of: item), alignment: .topLeading)
            }
        }
        .padding(PanelLayout.cardPad)
        .frame(width: PanelLayout.inner, height: PanelLayout.cardHeight(card), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: PanelLayout.corner)
                .fill(Color.faint(0.05))
                .overlay(RoundedRectangle(cornerRadius: PanelLayout.corner).strokeBorder(Color.faint(0.08), lineWidth: 1))
        )
    }
}

/// Cards stacked with a gap after each, as on a tab and in Settings.
struct CardStack: View {
    let cards: [Card]
    let onAction: ActionHandler

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                CardView(card: card, onAction: onAction)
                Color.clear.frame(height: PanelLayout.gap)
            }
        }
    }
}

/// One item, by kind.
struct ItemView: View {
    let item: Item
    let width: CGFloat
    let onAction: ActionHandler

    var body: some View {
        switch item {
        case let .tiles(tiles):
            TilesView(tiles: tiles, width: width)
        case let .chart(values, caption, labels):
            ChartItem(values: values, caption: caption, labels: labels)
        case let .bar(label, value, fraction, sub, _):
            BarItem(label: label, value: value, fraction: fraction, sub: sub, width: width)
        case let .row(label, value, extras):
            RowItem(label: label, value: value, dot: extras.dot, width: width)
        case let .readMore(id, isOpen):
            ReadMoreItem(id: id, isOpen: isOpen, onAction: onAction)
        case let .heading(text):
            LabelText(text: text, size: 12, weight: .semibold, height: 16).padding(.top, 5)
        case let .note(text):
            LabelText(text: text, size: 11, color: .secondaryLabel, height: 14).padding(.top, 1)
        case let .alert(text, showIcon):
            AlertItem(text: text, showIcon: showIcon)
        case let .tags(tags):
            TagsItem(tags: tags)
        case let .buttons(buttons):
            ButtonsItem(buttons: buttons, onAction: onAction)
        case let .segmented(label, options, selected, action):
            SegmentedItem(label: label, options: options, selected: selected, action: action, onAction: onAction)
        case let .popup(label, options, selected, action):
            PopupItem(label: label, options: options, selected: selected, action: action, onAction: onAction)
        case let .switch(label, isOn, action):
            SwitchItem(label: label, isOn: isOn, action: action, onAction: onAction)
        case let .rangePicker(from, to, earliest, latest):
            RangePickerItem(from: from, to: to, earliest: earliest, latest: latest, onAction: onAction)
        case let .choices(label, options, selected, action):
            ChoicesItem(label: label, options: options, selected: selected, action: action, onAction: onAction)
        }
    }
}
