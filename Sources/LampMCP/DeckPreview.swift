import AppKit
import Foundation
import LampCore
import LampPresentationUI
import SwiftUI

/// Draws a deck's slides to PNG files and reports what the drawing revealed.
///
/// A deck format check cannot see a slide. Every layout problem found in Lamp's
/// own decks — a cover image that never drew, a verse that was dropped, a list
/// crushed to half the size of the prose beside it — was invisible to the
/// validator and obvious in a picture. This gives whoever wrote the deck the
/// same look before anyone stands up to present it.
@MainActor
enum LampDeckPreview {
    struct SlideReport: Codable {
        var index: Int
        var id: String
        var layout: String
        var title: String
        var file: String
        /// Median height, in pixels at the rendered size, of a line of text.
        /// Small values mean the canvas shrank the text to make it fit.
        var textHeight: Int
        /// Whether ink reaches the slide's edge, which means content is being
        /// cut off rather than merely tightened.
        var clipped: Bool
        var notes: [String]
    }

    struct Report: Codable {
        var deckTitle: String
        var slideCount: Int
        var renderedCount: Int
        var width: Int
        var height: Int
        var outputDirectory: String
        var slides: [SlideReport]
        var issues: [String]
    }

    /// Renders `deck`, writing one PNG per slide into `outputDirectory`.
    ///
    /// Images resolve against the deck's own folder first — an agent's `Assets`
    /// directory beside the deck, before Lamp has imported anything — and then
    /// against `libraryRoot` when one is given.
    static func render(
        deckURL: URL,
        outputDirectory: URL,
        libraryRoot: URL?,
        slideNumbers: [Int]?,
        width: Double
    ) async throws -> Report {
        let data = try Data(contentsOf: deckURL)
        // Decode without the store's error-only gate so a deck can be looked at
        // while it is still being fixed.
        let deck = try LampPresentationDeckStore.decodeUnvalidated(data)
        let height = width / deck.aspectRatio.ratio
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let deckDirectory = deckURL.deletingLastPathComponent()
        let libraryStore = libraryRoot.map { LampPresentationDeckStore(rootURL: $0) }
        let resolve: (LampPresentationBlock) -> URL? = { block in
            guard let assetPath = block.assetPath,
                  LampPresentationDeckValidator.isSafeAssetPath(assetPath)
            else { return nil }
            let beside = deckDirectory.appendingPathComponent(assetPath)
            if FileManager.default.fileExists(atPath: beside.path) { return beside }
            guard let inLibrary = libraryStore?.assetURL(forAssetPath: assetPath),
                  FileManager.default.fileExists(atPath: inLibrary.path)
            else { return nil }
            return inLibrary
        }

        let wanted = slideNumbers.map(Set.init)
        var reports: [SlideReport] = []
        for (offset, slide) in deck.slides.enumerated() {
            let number = offset + 1
            if let wanted, !wanted.contains(number) { continue }
            let canvas = LampPresentationSlideCanvas(
                slide: slide,
                style: .init(deck: deck),
                assetURL: resolve
            )
            .frame(width: width, height: height)
            let renderer = ImageRenderer(content: canvas)
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }

            let filename = String(format: "slide-%02d.png", number)
            let destination = outputDirectory.appendingPathComponent(filename)
            let representation = NSBitmapImageRep(cgImage: image)
            if let png = representation.representation(using: .png, properties: [:]) {
                try png.write(to: destination, options: [.atomic])
            }

            let measurement = Measurement(image: image, theme: deck.theme)
            var notes: [String] = []
            if measurement.clipped {
                notes.append("Content reaches the edge of the slide and is being cut off.")
            }
            // Below roughly 20px at 900 high, text is under ~28pt on a
            // 1,600-point slide: legible on a laptop, not from a back row.
            let floor = 20.0 * (height / 900)
            if measurement.textHeight > 0 && Double(measurement.textHeight) < floor {
                notes.append(
                    "Text was shrunk to about \(measurement.textHeight)px a line to fit; "
                        + "move some of this to another slide."
                )
            }
            for ignored in slide.plan.ignored {
                notes.append("A \(slide.layout.rawValue) slide does not draw this slide's "
                    + "\(ignored.kind.rawValue) content.")
            }
            notes.append(contentsOf: await scriptureNotes(for: slide, libraryRoot: libraryRoot))
            reports.append(SlideReport(
                index: number,
                id: slide.id,
                layout: slide.layout.rawValue,
                title: slide.displayTitle,
                file: destination.path,
                textHeight: measurement.textHeight,
                clipped: measurement.clipped,
                notes: notes
            ))
        }

        return Report(
            deckTitle: deck.title,
            slideCount: deck.slides.count,
            renderedCount: reports.count,
            width: Int(width),
            height: Int(height),
            outputDirectory: outputDirectory.path,
            slides: reports,
            issues: LampPresentationDeckValidator.validate(deck) { assetPath in
                resolve(.init(kind: .image, assetPath: assetPath)) != nil
            }.map { "\($0.severity == .error ? "error" : "warning") \($0.path): \($0.message)" }
        )
    }

    /// Checks a slide's quoted scripture against the translation it names.
    ///
    /// A deck can quote a passage that is subtly not what the installed
    /// translation says — a paraphrase, a remembered wording, a verse off by
    /// one — and nothing else would ever notice. Only blocks that carry a
    /// `scriptureReference` can be checked; the rest are left alone.
    private static func scriptureNotes(
        for slide: LampPresentationSlide,
        libraryRoot: URL?
    ) async -> [String] {
        guard let libraryRoot else { return [] }
        let library = LampLibrary(rootURL: libraryRoot)
        var notes: [String] = []
        for block in slide.blocks {
            guard block.kind == .scripture, let reference = block.scriptureReference else {
                continue
            }
            guard let chapter = try? await library.chapter(
                moduleID: reference.translationID,
                bookNumber: reference.bookNumber,
                chapterNumber: reference.chapterNumber
            ) else {
                notes.append(
                    "Could not read \(reference.translationID) "
                        + "\(reference.bookNumber):\(reference.chapterNumber) to check this "
                        + "quotation. Is that translation installed?"
                )
                continue
            }
            let verses = chapter.verses.filter {
                $0.number >= reference.startVerse && $0.number <= reference.endVerse
            }
            guard !verses.isEmpty else {
                notes.append(
                    "\(reference.translationID) has no verses "
                        + "\(reference.startVerse)-\(reference.endVerse) in that chapter."
                )
                continue
            }
            let installed = comparable(verses.map(\.text).joined(separator: " "))
            let quoted = comparable(block.text)
            if installed != quoted {
                notes.append(
                    "This quotation does not match \(reference.translationID) as installed. "
                        + "Label it a paraphrase, or copy the translation's wording."
                )
            }
        }
        return notes
    }

    /// Wording only: punctuation, case, and spacing differ harmlessly between
    /// a deck and a database, and flagging those would make the check useless.
    private static func comparable(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// What a rendered slide shows about its own fit: how tall a line of text
    /// came out, and whether anything is touching the edge.
    private struct Measurement {
        let textHeight: Int
        let clipped: Bool

        init(image: CGImage, theme: LampPresentationTheme) {
            let background = Measurement.channels(of: theme.backgroundColor) ?? (0, 0, 0)
            let bytesPerPixel = 4
            let bytesPerRow = image.width * bytesPerPixel
            var pixels = [UInt8](repeating: 0, count: image.height * bytesPerRow)
            guard let context = CGContext(
                data: &pixels,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                self.textHeight = 0
                self.clipped = false
                return
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

            func inked(_ x: Int, _ y: Int) -> Bool {
                let offset = y * bytesPerRow + x * bytesPerPixel
                return abs(Int(pixels[offset]) - background.0)
                    + abs(Int(pixels[offset + 1]) - background.1)
                    + abs(Int(pixels[offset + 2]) - background.2) > 30
            }

            /// Heights of contiguous inked row-runs within one vertical strip.
            func bands(fromLeft: Double, toLeft: Double) -> [Int] {
                let first = Int(Double(image.width) * fromLeft)
                let last = min(Int(Double(image.width) * toLeft), image.width)
                var heights: [Int] = []
                var run = 0
                for y in 0..<image.height {
                    var rowInked = false
                    for x in stride(from: first, to: last, by: 2) where inked(x, y) {
                        rowInked = true
                        break
                    }
                    if rowInked {
                        run += 1
                    } else if run > 0 {
                        heights.append(run)
                        run = 0
                    }
                }
                if run > 0 { heights.append(run) }
                return heights
            }

            // Runs under 10px are rules and specks; runs taller than a sixth of
            // the slide are pictures and placeholders, not lines of text.
            let ceiling = max(20, image.height / 6)
            // A picture beside the prose shares its rows, so scanning the whole
            // width merges the two into one tall band and finds no text at all.
            // Each strip is measured on its own and the one that looks most like
            // a column of text decides.
            // Strips start past the leading edge: a quotation slide draws an
            // accent rule down the full height of its prose, which would
            // otherwise ink every row and merge the lines into one band.
            let strips = [(0.0, 1.0), (0.10, 0.50), (0.52, 0.95), (0.10, 0.95)]
            let candidates = strips
                .map { bands(fromLeft: $0.0, toLeft: $0.1).filter { $0 >= 10 && $0 <= ceiling } }
                .filter { !$0.isEmpty }
            let lines = candidates.max(by: { $0.count < $1.count })?.sorted() ?? []
            self.textHeight = lines.isEmpty ? 0 : lines[lines.count / 2]

            // The canvas pads by 72 of 900 vertically; ink inside the outermost
            // few pixels means something has run past the padding and been cut.
            let margin = max(2, image.height / 90)
            var touches = false
            for y in 0..<margin {
                for x in stride(from: 0, to: image.width, by: 2)
                where inked(x, y) || inked(x, image.height - 1 - y) {
                    touches = true
                    break
                }
                if touches { break }
            }
            self.clipped = touches
        }

        private static func channels(of hex: String) -> (Int, Int, Int)? {
            var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("#") { value.removeFirst() }
            guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
            return (Int((rgb >> 16) & 0xff), Int((rgb >> 8) & 0xff), Int(rgb & 0xff))
        }
    }
}
