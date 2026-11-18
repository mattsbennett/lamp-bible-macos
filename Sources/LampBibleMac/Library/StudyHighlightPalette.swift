import SwiftUI

struct StudyHighlightColor: Identifiable, Hashable {
    let name: String
    let hex: String

    var id: String { hex }
    var color: Color { Color(lampHex: hex) ?? .yellow }
}

enum StudyHighlightPalette {
    static let colors = [
        StudyHighlightColor(name: "Yellow", hex: "FFCC00"),
        StudyHighlightColor(name: "Green", hex: "34C759"),
        StudyHighlightColor(name: "Blue", hex: "007AFF"),
        StudyHighlightColor(name: "Pink", hex: "FF2D55"),
        StudyHighlightColor(name: "Orange", hex: "FF9500"),
        StudyHighlightColor(name: "Purple", hex: "AF52DE"),
    ]
}

/// One colour of the highlight palette. The chosen one wears a ring set off
/// from it by a gap, as the system's colour wells mark theirs, and a check,
/// so which is chosen does not rest on telling a thin ring from none.
struct HighlightSwatch: View {
    let color: Color
    let isSelected: Bool
    var size: CGFloat = 24

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
            }
            .overlay {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .padding(3)
            .overlay {
                if isSelected {
                    Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                }
            }
            .contentShape(Circle())
    }
}

extension Color {
    init?(lampHex: String) {
        var value = lampHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xff) / 255,
            green: Double((rgb >> 8) & 0xff) / 255,
            blue: Double(rgb & 0xff) / 255
        )
    }
}
