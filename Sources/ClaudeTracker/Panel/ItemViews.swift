import SwiftUI
import TrackerCore

// The display items: tiles, chart, bar, row, alert and tags. Offsets in the
// comments are panel_view.py's, from the top of the item's slot.

/// Big numbers side by side, each in a rounded box 58 pt tall.
struct TilesView: View {
    let tiles: [Item.Tile]
    let width: CGFloat

    private let gap: CGFloat = 8

    var body: some View {
        let count = CGFloat(max(tiles.count, 1))
        let tileWidth = (width - gap * (count - 1)) / count
        HStack(spacing: gap) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                TileView(tile: tile).frame(width: tileWidth, height: PanelLayout.bareTilesHeight)
            }
        }
    }
}

private struct TileView: View {
    let tile: Item.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Label at y+8 (16 tall), its icon beside it at y+9.
            HStack(spacing: 4) {
                if let icon = tile.icon {
                    Symbol(name: icon, size: 11, weight: .semibold, color: .accent)
                        .frame(width: 14, height: 14)
                }
                LabelText(text: tile.label, size: 11, color: .secondaryLabel, height: 16)
            }
            .padding(.top, 8)
            // Value at y+26, 26 tall.
            LabelText(text: tile.value, size: 21, weight: .semibold, digits: true, height: 26)
                .padding(.top, 2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.faint(0.06)))
    }
}

/// A caption over a line chart with a soft gradient underneath. Moving the
/// pointer over it shows that day's date and tokens in the caption, with a
/// dot on the line.
struct ChartItem: View {
    let values: [Int]
    let caption: String
    var labels: [String] = []
    @State private var hovered: Int?

    private var shownCaption: String {
        guard let index = hovered, values.indices.contains(index) else { return caption }
        let day = labels.indices.contains(index) ? labels[index] + " · " : ""
        return day + TokenMath.formatCount(values[index]) + " tokens"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(text: shownCaption, size: 10, color: .secondaryLabel, height: 14)
            LineChart(values: values, hovered: hovered)
                .frame(height: 58)
                .overlay(GeometryReader { proxy in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(point):
                                guard !values.isEmpty, proxy.size.width > 0 else { return }
                                if values.count == 1 {
                                    hovered = 0
                                    return
                                }
                                let step = proxy.size.width / CGFloat(values.count - 1)
                                let index = Int((point.x / step).rounded())
                                hovered = Swift.min(Swift.max(index, 0), values.count - 1)
                            case .ended:
                                hovered = nil
                            }
                        }
                })
        }
    }
}

private struct LineChart: View {
    let given: [Int]
    var hovered: Int?
    /// One value is drawn as a flat line, so a one-day range still shows.
    private var values: [Int] { given.count == 1 ? given + given : given }

    init(values: [Int], hovered: Int?) {
        given = values
        self.hovered = hovered
    }

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height

            // Dashed line marking the peak.
            var dash = Path()
            dash.move(to: CGPoint(x: 0, y: 0.5))
            dash.addLine(to: CGPoint(x: w, y: 0.5))
            context.stroke(dash, with: .color(.faint(0.25)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            guard values.count >= 2 else { return }
            let highest = values.max() ?? 0
            let peak = CGFloat(highest == 0 ? 1 : highest)
            let step = w / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step, y: h - 2 - CGFloat(value) / peak * (h - 4))
            }
            var line = Path()
            line.addLines(points)

            var area = line
            area.addLine(to: CGPoint(x: w, y: h))
            area.addLine(to: CGPoint(x: 0, y: h))
            area.closeSubpath()
            // The gradient spans the filled area, from its top to the bottom.
            let top = points.map(\.y).min() ?? 0
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Color.accent.opacity(0.35), Color.accent.opacity(0)]),
                startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))

            context.stroke(line, with: .color(.accent), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

            // The day under the pointer: a vertical rule and a dot.
            if let index = hovered, points.indices.contains(index) {
                var rule = Path()
                rule.move(to: CGPoint(x: points[index].x, y: 0))
                rule.addLine(to: CGPoint(x: points[index].x, y: h))
                context.stroke(rule, with: .color(.faint(0.35)), style: StrokeStyle(lineWidth: 1))
                let dot = CGRect(x: points[index].x - 3.5, y: points[index].y - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(.accent))
            }
        }
    }
}

/// Label and value over a rounded 0-1 bar.
struct BarItem: View {
    let label: String
    let value: String
    let fraction: Double
    var sub: String? = nil
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: PanelLayout.valueGap) {
                LabelText(text: label, truncation: .middle)
                ValueText(text: value, color: .secondaryLabel)
            }
            ShareBar(fraction: fraction).frame(height: 6).padding(.top, 3)  // at y+21
            if let sub {
                LabelText(text: sub, size: 11, color: .secondaryLabel, height: PanelLayout.barSubHeight)
                    .padding(.top, 1)
            }
        }
    }
}

/// A rounded track with an accent-colored fill for a 0-1 fraction.
private struct ShareBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            let h = geometry.size.height
            let share = CGFloat(max(0, min(1, fraction)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.faint(0.12))
                if share > 0 {
                    Capsule().fill(Color.accent).frame(width: max(h, geometry.size.width * share))
                }
            }
        }
    }
}

struct RowItem: View {
    let label: String
    let value: String
    var dot: LabelExtras.Dot?
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            if let dot = dot {
                StatusDot(dot: dot).frame(width: PanelLayout.dotWidth, alignment: .leading)
            }
            HStack(spacing: PanelLayout.valueGap) {
                LabelText(text: label, truncation: .middle)
                ValueText(text: value, weight: .semibold)
            }
        }
        .padding(.top, 2)
    }
}

/// A small "Read more" / "Show less" link under an item whose text is cut.
struct ReadMoreItem: View {
    let id: String
    let isOpen: Bool
    let onAction: ActionHandler

    var body: some View {
        Button(action: { onAction("toggle_row:\(id)", .none) }) {
            Text(isOpen ? "Show less" : "Read more")
                .font(.panel(11, .medium))
                .foregroundColor(.accent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
    }
}

/// The colored dot before a status row: green, yellow, grey, or an outline
/// when the state isn't known.
struct StatusDot: View {
    let dot: LabelExtras.Dot

    var body: some View {
        ZStack {
            switch dot {
            case .green: Circle().fill(Color(nsColor: .systemGreen))
            case .yellow: Circle().fill(Color(nsColor: .systemYellow))
            case .grey: Circle().fill(Color.faint(0.4))
            case .hollow: Circle().stroke(Color.secondaryLabel, lineWidth: 1.2).padding(0.6)
            }
        }
        .frame(width: 8, height: 8)
    }
}

/// One line of a warning, in orange; the first line gets an icon.
struct AlertItem: View {
    let text: String
    let showIcon: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Symbol(name: "exclamationmark.triangle.fill", size: 12, color: .orange)
                .frame(width: 16, height: 15)
                .padding(.top, 1)
                .opacity(showIcon ? 1 : 0)  // later lines still line up with the first
            LabelText(text: text, size: 12, weight: .semibold, color: .orange, height: 16)
        }
    }
}

/// A line of small rounded labels; an off one is faded and crossed out.
struct TagsItem: View {
    let tags: [Item.Tag]

    var body: some View {
        TagsLayout {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text(tag.text)
                    .font(.panel(11))
                    .strikethrough(!tag.isOn)
                    .foregroundColor(tag.isOn ? .label : .tertiaryLabel)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(Color.faint(tag.isOn ? 0.08 : 0.04)))
            }
        }
        .padding(.top, 2)
    }
}

/// Tags left to right, 4 pt apart. The one that reaches the edge is cut
/// short, and those after it are left out, as in the Python panel.
private struct TagsLayout: Layout {
    private let spacing: CGFloat = 4
    private let padding: CGFloat = 14  // a tag's text inset, both sides

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: 18)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified).width
            let width = min(ideal, bounds.maxX - x)
            if width <= padding {
                // No room left: out of sight (a layout can't hide a view).
                subview.place(at: CGPoint(x: -10_000, y: bounds.minY), proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: 18))
            x += width + spacing
        }
    }
}
