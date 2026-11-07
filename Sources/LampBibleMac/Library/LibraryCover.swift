import SwiftUI

/// A cover for something on the library shelf that came without one.
///
/// Modules and books carry no artwork — not one book in a typical library has
/// a cover image — so a shelf of them was a column of identical icons, which
/// gave the eye nothing to tell one from another. This draws each a bound
/// cover instead: cloth in one of twelve deep, quiet colours, lettered in
/// ivory, with a spine down the left edge. The colour is chosen from the
/// module's identifier, so a module keeps its colour from launch to launch
/// and on every surface it appears on.
///
/// The cloth colours are decoration, the way a book's binding is, and
/// deliberately avoid the hues Lamp gives a meaning to: no red (the app), no
/// blue bright enough to read as a link, no purple (original languages), no
/// yellow (a find).
struct LibraryCover: View {
    @Environment(\.colorScheme) private var colorScheme

    /// Set large on the cover when it is short enough to read as a mark:
    /// "BSB", "ESV", "TAGNT".
    let monogram: String?
    /// Lettered alone when there is no monogram, and under it when there is
    /// no `caption`.
    let title: String
    /// Lettered small under a monogram in place of the title — a language,
    /// a kind — so the cover does not repeat the name printed beneath it.
    var caption: String? = nil
    /// Drawn in place of a monogram for things that are not texts — the
    /// reader's own notes, writing and highlights.
    var systemImage: String? = nil
    /// What the cloth colour and the binding's ornament are chosen from.
    let seed: String
    let width: CGFloat
    /// A place on a shelf, when the cover stands on one: the cloth is then
    /// taken in turn from an order that alternates hue and lightness, so no
    /// two neighbours share a binding, which chance alone did not ensure.
    var shelfPosition: Int? = nil

    private var height: CGFloat { (width * 1.36).rounded() }
    private var isThumbnail: Bool { width < 60 }
    private var isDark: Bool { colorScheme == .dark }

    private var binding: LibraryCoverCloth.Binding {
        LibraryCoverCloth.binding(for: seed, shelfPosition: shelfPosition)
    }
    private var cloth: LibraryCoverCloth { binding.cloth }

    private var shownMonogram: String? {
        guard let monogram = monogram?.trimmingCharacters(in: .whitespaces),
              !monogram.isEmpty, monogram.count <= 6 else { return nil }
        return monogram
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(cloth.color)
            // Light from above, falling off down the board.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .clear, .black.opacity(0.14)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            if !isThumbnail { ornament }
            spine
            lettering
                .padding(.leading, spineWidth + inset * 0.6)
                .padding(.trailing, inset * 0.8)
                .padding(.vertical, inset)
                .frame(width: width, height: height)
        }
        .frame(width: width, height: height)
        // A touch lighter on the dark window, where the deepest cloths sat
        // within a shade of the page and lost their edges.
        .brightness(isDark ? 0.05 : 0)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.14),
                    lineWidth: isDark ? 1 : 0.5
                )
        )
        .shadow(
            color: .black.opacity(isDark ? 0.35 : (isThumbnail ? 0.10 : 0.14)),
            radius: isThumbnail ? 1 : 3,
            y: isThumbnail ? 0.5 : 2
        )
        .accessibilityHidden(true)
    }

    private var corner: CGFloat { max(2, width * 0.035) }
    private var spineWidth: CGFloat { max(3, width * 0.075) }
    private var inset: CGFloat { max(4, width * 0.1) }
    private var hairline: CGFloat { max(0.5, width * 0.007) }

    /// A darker band down the bound edge, with the crease of the hinge beside it.
    private var spine: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(.black.opacity(0.22))
                .frame(width: spineWidth)
            Rectangle()
                .fill(.white.opacity(0.12))
                .frame(width: max(0.5, width * 0.006))
            Rectangle()
                .fill(.black.opacity(0.10))
                .frame(width: max(0.5, width * 0.01))
            Spacer(minLength: 0)
        }
    }

    /// The tooling on the board, one of three, so that two covers in the same
    /// cloth still differ: plain, a pair of bands at head and tail, or a
    /// ruled frame.
    @ViewBuilder
    private var ornament: some View {
        let ink = cloth.ink.opacity(0.42)
        switch binding.ornament {
        case .plain:
            EmptyView()
        case .bands:
            VStack(spacing: 0) {
                band(ink).padding(.top, height * 0.08)
                Spacer(minLength: 0)
                band(ink).padding(.bottom, height * 0.08)
            }
            .padding(.leading, spineWidth)
            .frame(width: width, height: height)
        case .frame:
            Rectangle()
                .strokeBorder(ink, lineWidth: hairline)
                .padding(.leading, spineWidth + inset * 0.45)
                .padding(.trailing, inset * 0.45)
                .padding(.vertical, inset * 0.55)
                .frame(width: width, height: height)
        }
    }

    private func band(_ ink: Color) -> some View {
        VStack(spacing: width * 0.02) {
            Rectangle().fill(ink).frame(height: hairline * 1.6)
            Rectangle().fill(ink).frame(height: hairline)
        }
    }

    @ViewBuilder
    private var lettering: some View {
        if isThumbnail {
            thumbnailLettering
        } else {
            VStack(spacing: width * 0.06) {
                Spacer(minLength: 0)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: width * 0.26, weight: .light))
                } else if let shownMonogram {
                    Text(shownMonogram)
                        .font(.system(size: monogramSize(shownMonogram), weight: .semibold, design: .serif))
                        .tracking(width * 0.006)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Rectangle()
                    .fill(cloth.ink.opacity(0.5))
                    .frame(width: width * 0.22, height: hairline)
                if let caption, shownMonogram != nil || systemImage != nil {
                    Text(caption.uppercased())
                        .font(.system(size: width * 0.07, weight: .semibold, design: .serif))
                        .tracking(width * 0.012)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } else {
                    Text(title)
                        .font(.system(
                            size: width * (shownMonogram == nil && systemImage == nil ? 0.11 : 0.088),
                            weight: .medium,
                            design: .serif
                        ))
                        .multilineTextAlignment(.center)
                        .lineLimit(shownMonogram == nil && systemImage == nil ? 5 : 3)
                        .minimumScaleFactor(0.8)
                        .lineSpacing(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(cloth.ink)
            .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            .frame(maxWidth: .infinity)
        }
    }

    /// Too small for a title: the monogram, or the title's first letter.
    private var thumbnailLettering: some View {
        Group {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: width * 0.34))
            } else {
                Text(shownMonogram ?? String(initialLetter))
                    .font(.system(
                        size: shownMonogram.map { monogramSize($0) } ?? width * 0.42,
                        weight: .semibold,
                        design: .serif
                    ))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(cloth.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initialLetter: Character {
        // "The Parables of Christ" is shelved as much under P as under T, but
        // a cover's letter is the first one printed on it.
        title.first(where: \.isLetter) ?? "·"
    }

    private func monogramSize(_ monogram: String) -> CGFloat {
        let scale: CGFloat = switch monogram.count {
        case ...3: 0.25
        case 4: 0.21
        default: 0.17
        }
        return width * (isThumbnail ? scale * 1.25 : scale)
    }
}

/// The bindings a cover can be given.
struct LibraryCoverCloth {
    let color: Color
    let ink: Color

    enum Ornament: CaseIterable {
        case plain, bands, frame
    }

    struct Binding {
        let cloth: LibraryCoverCloth
        let ornament: Ornament
    }

    private static let ivory = Color(red: 0.96, green: 0.93, blue: 0.85)
    private static let sepia = Color(red: 0.20, green: 0.16, blue: 0.12)

    private static func cloth(_ red: Double, _ green: Double, _ blue: Double) -> LibraryCoverCloth {
        LibraryCoverCloth(color: Color(red: red, green: green, blue: blue), ink: ivory)
    }

    /// A pale binding, lettered in dark sepia.
    private static func linen(_ red: Double, _ green: Double, _ blue: Double) -> LibraryCoverCloth {
        LibraryCoverCloth(color: Color(red: red, green: green, blue: blue), ink: sepia)
    }

    /// Twelve deep cloths spread round the wheel — navy, forest, slate,
    /// umber, aubergine, teal, olive, charcoal, bronze, sage, steel and
    /// cocoa — and four pale ones — linen, sand, celadon and dove — so a
    /// shelf varies in lightness as well as hue, and neighbours rarely
    /// match. Ivory lettering on the deep cloths, sepia on the pale.
    static let all: [LibraryCoverCloth] = [
        cloth(0.13, 0.20, 0.34),
        cloth(0.15, 0.31, 0.22),
        cloth(0.27, 0.31, 0.37),
        cloth(0.42, 0.27, 0.16),
        cloth(0.30, 0.20, 0.31),
        cloth(0.09, 0.31, 0.33),
        cloth(0.33, 0.33, 0.16),
        cloth(0.19, 0.19, 0.21),
        cloth(0.47, 0.35, 0.14),
        cloth(0.28, 0.38, 0.30),
        cloth(0.17, 0.29, 0.42),
        cloth(0.31, 0.21, 0.17),
        linen(0.89, 0.85, 0.76),
        linen(0.85, 0.77, 0.62),
        linen(0.76, 0.82, 0.75),
        linen(0.82, 0.83, 0.84),
    ]

    /// The cloths in shelf order: each a step away from the last in hue and
    /// in lightness — navy, umber, linen, forest, aubergine, bronze, dove…
    private static let shelfOrder = [0, 3, 12, 1, 4, 8, 15, 5, 11, 13, 10, 6, 14, 2, 7, 9]

    /// The same binding for the same seed on every launch. Swift's own hash
    /// is seeded per process, so it would rebind the whole shelf each time
    /// the app opened. FNV-1a, which spreads short similar identifiers well.
    static func binding(for seed: String, shelfPosition: Int? = nil) -> Binding {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let cloth = shelfPosition.map { all[shelfOrder[$0 % shelfOrder.count]] }
            ?? all[Int(hash % UInt64(all.count))]
        let ornaments = Ornament.allCases
        let ornament = ornaments[Int((hash / UInt64(all.count)) % UInt64(ornaments.count))]
        return Binding(cloth: cloth, ornament: ornament)
    }
}
