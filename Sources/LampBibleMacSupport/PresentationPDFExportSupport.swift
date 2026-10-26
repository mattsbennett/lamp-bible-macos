import AppKit
import CoreText
import Foundation
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
/// megabytes. A picture behind a slide is still a picture, and is embedded as
/// one.
public enum LampPresentationPDFExport {
    public enum ExportError: Error, Equatable, LocalizedError {
        /// A deck with no slides would produce a PDF with no pages, which no
        /// reader will open.
        case noSlides
        /// Core Graphics would not open the destination for writing.
        case destinationUnwritable(URL)

        /// Spelled out, because this surfaces in the editor: the default
        /// description of an enum error is "The operation couldn't be
        /// completed", which tells the person nothing they can act on.
        public var errorDescription: String? {
            switch self {
            case .noSlides:
                "This deck has no slides to export."
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

        for (offset, slide) in deck.slides.enumerated() {
            let canvas = LampPresentationSlideCanvas(slide: slide, deck: deck, store: store)
                .frame(width: slideSize.width, height: slideSize.height)
            let renderer = ImageRenderer(content: canvas)

            if options.includesSpeakerNotes {
                writeNotesPages(
                    for: slide,
                    number: offset + 1,
                    renderer: renderer,
                    slideSize: slideSize,
                    into: context
                )
            } else {
                context.beginPDFPage(nil)
                renderer.render { _, draw in draw(context) }
                context.endPDFPage()
            }

            progress?(offset + 1, deck.slides.count)
            await Task.yield()
        }

        context.closePDF()
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
                context.saveGState()
                context.translateBy(x: slideRect.minX, y: slideRect.minY)
                context.scaleBy(
                    x: slideRect.width / slideSize.width,
                    y: slideRect.height / slideSize.height
                )
                renderer.render { _, draw in draw(context) }
                context.restoreGState()
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
