import SwiftUI

/// A row that moves onto a second line instead of running off the edge.
///
/// `HStack` would push key scripture or metadata out of a narrow pane rather than
/// wrapping it, and these panes are resizable down to a column much narrower than
/// the content they carry.
struct WrappingRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maximumWidth: maximumWidth)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0.0) { $0 + $1.height } +
            spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, maximumWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = arrange(subviews: subviews, maximumWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maximumWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithItem = current.indices.isEmpty
                ? size.width
                : current.width + spacing + size.width
            if !current.indices.isEmpty, widthWithItem > maximumWidth {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = widthWithItem
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
