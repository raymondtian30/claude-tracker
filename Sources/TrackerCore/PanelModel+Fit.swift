import Foundation

// Text that does not fit its slot. The views first shrink a label up to 15%
// (`PanelLayout.minTextScale`); what is still too wide is cut off with "…",
// and this pass puts a small "Read more" under it. Opening it shows the full
// text under the item, so nothing beside the item moves. Notes and warnings
// wrap instead: a line still too wide is broken into more lines.
extension PanelModel {
    /// `tab` with a "Read more" under every item (or card title) whose text
    /// is cut off, the full text under the ones `open` lists, and notes and
    /// warnings re-wrapped to fit. `ids` are the "Read more" ids, so the app
    /// keeps them open across redraws. An id names the tab, the card (by
    /// title, or by position when it has none) and the item's position before
    /// anything was added, never the text, so a changing value (a Live tab
    /// timer) does not close it.
    public static func fitted(_ tab: Tab, measure: TextMeasure, open: [String: Bool]) -> (tab: Tab, ids: Set<String>) {
        var ids = Set<String>()
        var out = tab
        for (cardIndex, card) in tab.cards.enumerated() {
            let cardKey = card.title ?? "#\(cardIndex)"
            var items = [Item]()
            func readMore(_ id: String, _ texts: [String]) {
                ids.insert(id)
                let isOpen = open[id] != nil
                if isOpen {
                    for text in texts {
                        items += wrapMeasured(text, width: PanelLayout.cardInner - 1, size: 11, measure: measure)
                            .map { .note($0) }
                    }
                }
                items.append(.readMore(id: id, isOpen: isOpen))
            }
            if let title = card.title,
               PanelLayout.isCutEvenShrunk(title, size: 13, weight: .semibold, width: PanelLayout.cardInner,
                                           measure: measure) {
                readMore("fit:\(tab.key):\(cardKey):title", [title])
            }
            for (index, item) in card.items.enumerated() {
                switch item {
                case let .note(text):
                    items += rewrapped(text, size: 11, weight: .regular, width: PanelLayout.cardInner,
                                       measure: measure).map { .note($0) }
                case let .alert(text, showIcon):
                    let lines = rewrapped(text, size: 12, weight: .semibold, width: PanelLayout.alertTextWidth,
                                          measure: measure)
                    items += lines.enumerated().map { .alert(text: $0.element, showIcon: showIcon && $0.offset == 0) }
                default:
                    items.append(item)
                    let texts = cutTexts(item, measure: measure)
                    if !texts.isEmpty {
                        readMore("fit:\(tab.key):\(cardKey):\(index)", texts)
                    }
                }
            }
            out.cards[cardIndex].items = items
        }
        return (out, ids)
    }

    /// `text` as it is when it fits shrunk, else broken into lines that do.
    static func rewrapped(_ text: String, size: CGFloat, weight: LabelWeight, width: CGFloat,
                          measure: TextMeasure) -> [String] {
        guard PanelLayout.isCutEvenShrunk(text, size: size, weight: weight, width: width, measure: measure) else {
            return [text]
        }
        let lines = wrapMeasured(text, width: width - 1, size: size, measure: { text, size, _ in measure(text, size, weight) })
        return lines.isEmpty ? [text] : lines
    }

    /// The full texts of `item` that are cut off even shrunk: for a row or
    /// bar its label (or "label: value" when the value is cut) and a bar's
    /// grey line; for a heading or a control, its label. Empty when it fits.
    static func cutTexts(_ item: Item, measure: TextMeasure) -> [String] {
        func cut(_ text: String, _ size: CGFloat, _ weight: LabelWeight, _ width: CGFloat) -> Bool {
            PanelLayout.isCutEvenShrunk(text, size: size, weight: weight, width: width, measure: measure)
        }
        func labelAndValue(_ label: String, _ value: String, _ valueWeight: LabelWeight, _ hasDot: Bool) -> [String] {
            let widths = PanelLayout.labelValueWidths(label: label, value: value, valueWeight: valueWeight,
                                                      hasDot: hasDot, measure: measure)
            if cut(value, 13, valueWeight, PanelLayout.valueCap) {
                return ["\(label): \(value)"]
            }
            return cut(label, 13, .regular, widths.label) ? [label] : []
        }
        switch item {
        case let .row(label, value, extras):
            return labelAndValue(label, value, .semibold, extras.dot != nil)
        case let .bar(label, value, _, sub, _):
            var texts = labelAndValue(label, value, .regular, false)
            if let sub = sub, cut(sub, 11, .regular, PanelLayout.cardInner) {
                texts.append(sub)
            }
            return texts
        case let .heading(text):
            return cut(text, 12, .semibold, PanelLayout.cardInner) ? [text] : []
        case let .switch(label, _, _):
            return cut(label, 13, .regular, PanelLayout.switchLabelWidth) ? [label] : []
        case let .popup(label?, _, _, _):
            return cut(label, 13, .regular, PanelLayout.popupLabelWidth) ? [label] : []
        case let .segmented(label?, _, _, _):
            return cut(label, 13, .regular, PanelLayout.segmentedLabelWidth) ? [label] : []
        case let .choices(label?, _, _, _):
            return cut(label, 13, .regular, PanelLayout.cardInner) ? [label] : []
        default:
            return []
        }
    }
}
