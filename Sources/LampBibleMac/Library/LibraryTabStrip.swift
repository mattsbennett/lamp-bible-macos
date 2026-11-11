import SwiftUI

/// The chrome a rank of tabs is drawn with, shared by the reader's tabs and
/// the Search pane's.
///
/// Only the parts that would drift: the height, the hairline between cells
/// and the fill behind one. Each bar keeps its own cells, because what a tab
/// offers differs — a reader tab is renamed and opened at a passage, a search
/// tab is duplicated and closed — and flattening those into one view would
/// hide a real difference behind a shared shape.
///
/// What must not differ is how the two read side by side: a window shows one
/// rank of tabs in whichever pane it is on, and two ranks that disagree about
/// their height or their dividers look like two apps. Written down once so a
/// restyling of one reaches the other.
enum LibraryTabStrip {
    static let height: CGFloat = 30
    /// A cell narrow enough that several fit, wide enough to read a title in.
    static let minimumCellWidth: CGFloat = 104
    static let maximumCellWidth: CGFloat = 190

    /// The fill behind a cell. The open tab takes the content colour, so it
    /// reads as the page below it; the others take a hover tint or nothing.
    static func cellBackground(isSelected: Bool, isHovered: Bool) -> some ShapeStyle {
        if isSelected {
            return AnyShapeStyle(.background)
        }
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
    }
}

/// The hairline between cells.
///
/// Fades out toward the top, so it rises out of the bar rather than stopping
/// short against the toolbar above, which has no border for it to meet. A
/// gradient of the colour rather than a mask over `.separator`: in dark mode
/// the masked style drew nothing at all.
struct LibraryTabStripSeparator: View {
    var body: some View {
        let line = Color(nsColor: .separatorColor)
        return Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: line.opacity(0), location: 0),
                        .init(color: line, location: 0.75),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
    }
}
