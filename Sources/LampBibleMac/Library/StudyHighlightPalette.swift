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
