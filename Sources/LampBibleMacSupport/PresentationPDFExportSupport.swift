import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import LampCore
import LampPresentationUI
import SwiftUI

/// Writes a deck as a PDF: the slides alone, or each slide with its speaker
/// notes under it.
///
/// The slides are drawn by `LampPresentationSlideCanvas`, the same view the
/// presenter and the editor preview use, so an exported page is the slide
/// rather than a second rendering of it that can drift.
///
/// Each page is drawn *into the PDF's own context* rather than rasterised and
/// placed as an image. Text stays text: the page can be searched, selected,
/// and printed at any size, and a deck is tens of kilobytes instead of tens of
/// megabytes.
///
/// A slide with a picture behind it is the exception and is drawn as one
/// high-resolution image — see `rasterised(_:)` for why it has to be.
public enum LampPresentationPDFExport {
    public enum ExportError: Error, Equatable, LocalizedError {
        /// A deck with no slides would produce a PDF with no pages, which no
        /// reader will open.
        case noSlides
        /// Every slide is hidden, so there is nothing to put on a page.
        case allSlidesHidden
        /// Core Graphics would not open the destination for writing.
        case destinationUnwritable(URL)

        /// Spelled out, because this surfaces in the editor: the default
        /// description of an enum error is "The operation couldn't be
        /// completed", which tells the person nothing they can act on.
        public var errorDescription: String? {
            switch self {
            case .noSlides:
                "This deck has no slides to export."
            case .allSlidesHidden:
                "Every slide in this deck is hidden, so there is nothing to export."
            case let .destinationUnwritable(url):
                "Could not write to \(url.lastPathComponent)."
            }
        }
    }

    public struct Options: Equatable, Sendable {
        /// Puts each slide on a page of its own with its speaker notes beneath
        /// it, rather than exporting the slides alone.
        public var includesSpeakerNotes: Bool

        public init(includesSpeakerNotes: Bool = false) {
            self.includesSpeakerNotes = includesSpeakerNotes
        }
    }

    /// The page one slide is drawn on, in points, when the slides go out alone.
    ///
    /// 540 points tall, which puts a widescreen slide at 13⅓ × 7½ inches and a
    /// standard one at 10 × 7½ — the page sizes PowerPoint and Keynote export,
    /// so a deck prints and imports elsewhere without being rescaled.
    ///
    /// The canvas works from a fixed design grid and scales to whatever size it
    /// is given, so this is a page size and not a resolution: the type is laid
    /// out for the page, not shrunk to fit it.
    public static func pageSize(for aspectRatio: LampPresentationAspectRatio) -> CGSize {
        let height: Double = 540
        return CGSize(width: (height * aspectRatio.ratio).rounded(), height: height)
    }

    /// US Letter, upright, when the notes come too.
    ///
    /// A notes page is read and written on rather than projected, so it is
    /// ordinary paper and the same whatever shape the slides are — a presenter
    /// printing one wants it to come out of the printer they have.
    public static let notesPageSize = CGSize(width: 612, height: 792)

    private static let margin: Double = 54
    private static let gapUnderSlide: Double = 24
    private static let footerBaseline: Double = 32

    /// Draws `deck` to a PDF at `destination`.
    ///
    /// Yields between slides. Drawing has to happen on the main actor —
    /// `ImageRenderer` is main-isolated — and a forty-slide deck is seconds of
    /// it, so without yielding the window would stop answering for the whole
    /// export. `progress` is called with the slide just finished and the total.
    @MainActor
    public static func write(
        deck: LampPresentationDeck,
        store: LampPresentationDeckStore,
        to destination: URL,
        options: Options = Options(),
        progress: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard !deck.slides.isEmpty else { throw ExportError.noSlides }
        // Hidden slides stay out, as they do when the deck is presented. A
        // slide hidden because it is unfinished, or cut for time, should not
        // reappear in the handout — which is often the copy other people keep.
        let slides = deck.slides.filter { !$0.isHidden }
        guard !slides.isEmpty else { throw ExportError.allSlidesHidden }

        let slideSize = pageSize(for: deck.aspectRatio)
        var mediaBox = CGRect(
            origin: .zero,
            size: options.includesSpeakerNotes ? notesPageSize : slideSize
        )
        guard let consumer = CGDataConsumer(url: destination as CFURL),
              let context = CGContext(
                  consumer: consumer,
                  mediaBox: &mediaBox,
                  [kCGPDFContextTitle as String: deck.title] as CFDictionary
              )
        else { throw ExportError.destinationUnwritable(destination) }

        for (offset, slide) in slides.enumerated() {
            let canvas = LampPresentationSlideCanvas(slide: slide, deck: deck, store: store)
                .frame(width: slideSize.width, height: slideSize.height)
            let renderer = ImageRenderer(content: canvas)
            let overPicture = backgroundPicture(for: slide, store: store) != nil

            if options.includesSpeakerNotes {
                writeNotesPages(
                    for: slide,
                    number: offset + 1,
                    renderer: renderer,
                    overPicture: overPicture,
                    slideSize: slideSize,
                    into: context
                )
            } else {
                context.beginPDFPage(nil)
                draw(
                    renderer,
                    overPicture: overPicture,
                    in: CGRect(origin: .zero, size: slideSize),
                    slideSize: slideSize,
                    into: context
                )
                context.endPDFPage()
            }

            // Numbered as they are presented, so slide 3 in the PDF is slide 3
            // on the screen rather than counting a slide nobody will see.
            progress?(offset + 1, slides.count)
            await Task.yield()
        }

        context.closePDF()
    }

    /// The picture behind `slide`, when the deck names one and the file is
    /// there. Its presence is what decides how the slide reaches the page.
    private static func backgroundPicture(
        for slide: LampPresentationSlide,
        store: LampPresentationDeckStore
    ) -> URL? {
        guard let block = slide.plan.background,
              let url = store.assetURL(for: block),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// Puts one slide on the page, as drawing or as picture.
    @MainActor
    private static func draw(
        _ renderer: ImageRenderer<some View>,
        overPicture: Bool,
        in rect: CGRect,
        slideSize: CGSize,
        into context: CGContext
    ) {
        if overPicture, let image = rasterised(renderer) {
            context.draw(image, in: rect)
            return
        }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / slideSize.width, y: rect.height / slideSize.height)
        renderer.render { _, draw in draw(context) }
        context.restoreGState()
    }

    /// A slide drawn to pixels, for the one case where it must be.
    ///
    /// Lamp sets words over a picture by laying a feathered gradient behind
    /// each block — part scrim, part the picture blurred — so only the bands
    /// under the words are covered and the rest of the picture is left alone.
    /// Drawn into a PDF context those gradients lose their transparency and
    /// paint flat, edge to edge, hiding the picture completely: the page came
    /// out a single colour with the words on it, and the picture was embedded
    /// in the file but never visible.
    ///
    /// So these slides are rendered to a bitmap, which composites them exactly
    /// as the presenter does, and the bitmap goes on the page. The words on
    /// such a slide stop being selectable text, which is the price. Every slide
    /// without a picture behind it stays vector.
    ///
    /// Re-encoded as a JPEG before it goes in: a 1,920 x 1,080 slide is six
    /// megabytes of pixels and a few hundred kilobytes of JPEG, and what is
    /// being stored is a photograph.
    @MainActor
    private static func rasterised(_ renderer: ImageRenderer<some View>) -> CGImage? {
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return image }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(data, nil),
              let encoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return image }
        return encoded
    }

    /// One page with the slide and as much of its notes as will fit, then a
    /// page of notes alone for each further part.
    ///
    /// Notes that follow the manuscript are whole paragraphs of a talk, so
    /// running over a page is the normal case rather than the exception. They
    /// are laid out by Core Text, which reports how much of the text it managed
    /// to set, and the remainder starts the next page. Shrinking the type to
    /// fit instead would make the one thing a speaker reads from a lectern the
    /// smallest print in the document.
    @MainActor
    private static func writeNotesPages(
        for slide: LampPresentationSlide,
        number: Int,
        renderer: ImageRenderer<some View>,
        overPicture: Bool,
        slideSize: CGSize,
        into context: CGContext
    ) {
        let page = notesPageSize
        let contentWidth = page.width - margin * 2
        let slideHeight = contentWidth / (slideSize.width / slideSize.height)
        let slideRect = CGRect(
            x: margin,
            y: page.height - margin - slideHeight,
            width: contentWidth,
            height: slideHeight
        )
        let firstNotesRect = CGRect(
            x: margin,
            y: margin + footerBaseline,
            width: contentWidth,
            height: slideRect.minY - gapUnderSlide - margin - footerBaseline
        )
        let laterNotesRect = CGRect(
            x: margin,
            y: margin + footerBaseline,
            width: contentWidth,
            height: page.height - margin * 2 - footerBaseline
        )

        let notes = slide.speakerNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = notesText(notes)
        let framesetter = attributed.length > 0
            ? CTFramesetterCreateWithAttributedString(attributed)
            : nil

        var drawn = 0
        var isFirstPage = true
        repeat {
            context.beginPDFPage(nil)

            if isFirstPage {
                draw(
                    renderer,
                    overPicture: overPicture,
                    in: slideRect,
                    slideSize: slideSize,
                    into: context
                )
            }

            if let framesetter, drawn < attributed.length {
                let rect = isFirstPage ? firstNotesRect : laterNotesRect
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: drawn, length: 0),
                    CGPath(rect: rect, transform: nil),
                    nil
                )
                CTFrameDraw(frame, context)
                let visible = CTFrameGetVisibleStringRange(frame)
                // A rect too short for even one line sets nothing, which would
                // spin here forever. Give up on the remainder instead.
                guard visible.length > 0 else {
                    drawFooter(number: number, continued: !isFirstPage, into: context)
                    context.endPDFPage()
                    return
                }
                drawn += visible.length
            }

            drawFooter(number: number, continued: !isFirstPage, into: context)
            context.endPDFPage()
            isFirstPage = false
        } while drawn < attributed.length
    }

    /// The notes' own typography: the system text face at reading size, black
    /// on the page. Not the deck's theme — a notes page is paper, and setting a
    /// talk in a display face on a dark ground is the opposite of legible under
    /// a lectern lamp.
    private static func notesText(_ notes: String) -> NSAttributedString {
        guard !notes.isEmpty else { return NSAttributedString(string: "") }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        paragraph.paragraphSpacing = 8
        return NSAttributedString(
            string: notes,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: NSColor(calibratedWhite: 0, alpha: 1),
                .paragraphStyle: paragraph,
            ]
        )
    }

    private static func drawFooter(number: Int, continued: Bool, into context: CGContext) {
        let label = continued ? "Slide \(number) (continued)" : "Slide \(number)"
        let text = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                // A fixed grey, not `secondaryLabelColor`. The dynamic colours
                // resolve against an appearance, and a PDF context has none —
                // the footer came out white on white paper.
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
            ]
        )
        let line = CTLineCreateWithAttributedString(text)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(
            x: (notesPageSize.width - width) / 2,
            y: footerBaseline
        )
        CTLineDraw(line, context)
    }
}
