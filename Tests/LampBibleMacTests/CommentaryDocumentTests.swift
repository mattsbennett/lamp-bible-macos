import AppKit
import LampBibleMacSupport
import LampCore
import Testing
@testable import LampBibleMac

/// The commentary pane's text, as one string for a chapter. The scroll link
/// finds each passage by where its heading begins, so those places have to
/// be exact, and the links and order have to match what the pane drew when
/// it was a stack of views.
struct CommentaryDocumentTests {
    private let style = CommentaryTextStyle(fontSize: 15, lineSpacing: 4, typeface: .serif)

    private func unit(
        _ id: String,
        start: Int,
        end: Int? = nil,
        order: Int,
        title: String? = nil,
        commentary: String? = nil,
        footnotes: String? = nil,
        links: [LampScriptureLink] = []
    ) -> LampCommentaryUnit {
        LampCommentaryUnit(
            unitID: id, moduleID: "NIC", moduleName: "NIC", bookNumber: 45, chapterNumber: 8,
            startReference: start, endReference: end, unitType: "block", level: 2,
            title: title, commentary: commentary, footnotes: footnotes,
            scriptureLinks: links, orderIndex: order
        )
    }

    @Test func eachPassageIsFoundWhereItsHeadingBegins() {
        let units = [
            unit("c", start: 45_008_005, order: 3, commentary: "Flesh and Spirit."),
            unit("a", start: 45_008_001, end: 45_008_004, order: 1, title: "Opening discussion"),
            unit("b", start: 45_008_001, end: 45_008_004, order: 2, commentary: "No condemnation."),
        ]
        let document = CommentaryDocument.build(title: "Romans 8", units: units, style: style)
        let string = document.text.string as NSString

        #expect(document.anchors.map(\.reference) == [45_008_001, 45_008_005])
        #expect(document.anchors.first?.endReference == 45_008_004)
        let headings = document.anchorLocations.map {
            string.substring(with: string.paragraphRange(for: NSRange(location: $0, length: 0)))
                .trimmingCharacters(in: .newlines)
        }
        #expect(headings == ["ROMANS 8:1–4", "ROMANS 8:5"])
        // Units in their order, a heading with nothing under it as the outline.
        #expect(string.range(of: "Opening discussion").location < string.range(of: "No condemnation.").location)
        #expect(string.range(of: "No condemnation.").location < string.range(of: "Flesh and Spirit.").location)
        #expect(document.text.attribute(.lampCommentaryIcon, at: string.range(of: "Opening discussion").location, effectiveRange: nil) is CommentaryIcon)

        // The top of the pane, inside a passage's comment, is that passage.
        #expect(document.anchorIndex(containing: 0) == 0)
        #expect(document.anchorIndex(containing: string.range(of: "No condemnation.").location) == 0)
        #expect(document.anchorIndex(containing: string.range(of: "Flesh and Spirit.").location) == 1)
    }

    /// A reference is linked where its words appear and not where they are
    /// already a link; one whose words appear nowhere is set after the unit.
    @Test func referencesAreLinkedInTheTextOrAfterIt() throws {
        let inText = LampScriptureLink(text: "Rom 8:3", startReference: 45_008_003, endReference: nil)
        let again = LampScriptureLink(text: "gal 5:17", startReference: 48_005_017, endReference: nil)
        let nowhere = LampScriptureLink(text: "Gen 1:1", startReference: 1_001_001, endReference: nil)
        let document = CommentaryDocument.build(title: "Romans 8", units: [
            unit("a", start: 45_008_001, order: 1,
                 commentary: "See Rom 8:3, and Gal 5:17.", links: [inText, again, nowhere]),
        ], style: style)
        let string = document.text.string as NSString

        let first = string.range(of: "Rom 8:3")
        let link = try #require(document.text.attribute(.link, at: first.location, effectiveRange: nil) as? URL)
        #expect(LampScriptureLink(previewURL: link)?.startReference == 45_008_003)
        // Found again in any case, as the pane always matched.
        let second = string.range(of: "Gal 5:17")
        #expect(document.text.attribute(.link, at: second.location, effectiveRange: nil) != nil)
        // Not found in the text, so kept as a trailing link.
        let trailing = string.range(of: "(Gen 1:1)")
        #expect(trailing.location != NSNotFound)
        #expect(document.text.attribute(.link, at: trailing.location + 1, effectiveRange: nil) != nil)
    }

    /// Commentary quoting Hebrew at a paragraph's start would otherwise take
    /// a right-to-left base direction and turn its references round.
    @Test func everyParagraphIsLeftToRight() {
        let document = CommentaryDocument.build(title: "Psalms 22", units: [
            unit("a", start: 19_022_001, order: 1, commentary: "אֵלִי (Ps 22:1)\nMy God."),
        ], style: style)
        var directions = Set<NSWritingDirection>()
        document.text.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.text.length)) { value, _, _ in
            if let paragraph = value as? NSParagraphStyle { directions.insert(paragraph.baseWritingDirection) }
        }
        #expect(directions == [.leftToRight])
    }

    /// An outline path is cut short to one line; its full path is its
    /// tooltip, which a TextKit 2 view does not show by itself.
    @Test @MainActor func anOutlinePathShowsItsFullPathOnHover() throws {
        let document = CommentaryDocument.build(title: "Matthew 1", units: [
            unit("a", start: 40_001_001, order: 1, title: "Opening discussion"),
            unit("b", start: 40_001_001, order: 2, title: "Text, Exposition, and Notes"),
            unit("c", start: 40_001_001, order: 3, commentary: "The prominent repetition of the title."),
        ], style: style)
        let textView = CommentaryTextView(usingTextLayoutManager: true)
        textView.frame = NSRect(x: 0, y: 0, width: 360, height: 600)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textStorage?.setAttributedString(document.text)
        let layoutManager = try #require(textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        func point(over words: String) throws -> NSPoint {
            let range = (document.text.string as NSString).range(of: words)
            let start = try #require(layoutManager.location(layoutManager.documentRange.location, offsetBy: range.location))
            let end = try #require(layoutManager.location(start, offsetBy: range.length))
            var frame = CGRect.zero
            layoutManager.enumerateTextSegments(in: try #require(NSTextRange(location: start, end: end)), type: .standard, options: []) { _, segment, _, _ in
                frame = segment
                return false
            }
            return NSPoint(x: frame.midX + textView.textContainerOrigin.x, y: frame.midY + textView.textContainerOrigin.y)
        }
        #expect(textView.toolTip(at: try point(over: "Opening discussion")) == "Opening discussion › Text, Exposition, and Notes")
        #expect(textView.toolTip(at: try point(over: "prominent")) == nil)

        // Through the pointer's own path: a mouse move sets the view's tooltip.
        let window = NSWindow(contentRect: textView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        func move(over words: String) throws {
            let location = textView.convert(try point(over: words), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
            ))
            textView.mouseMoved(with: event)
        }
        try move(over: "Opening discussion")
        #expect(textView.toolTip == "Opening discussion › Text, Exposition, and Notes")
        try move(over: "prominent")
        #expect(textView.toolTip == nil)
        #expect(textView.textLayoutManager != nil)
    }

    /// A click anywhere over the text reaches the text view, so links open
    /// their previews and text can be selected. A bottom content inset on the
    /// scroll view, once the room under the last passage, laid a view over
    /// it all that took every click.
    @Test @MainActor func clicksOverTheTextReachTheTextView() throws {
        let document = CommentaryDocument.build(title: "Romans 8", units: [
            unit("a", start: 45_008_001, order: 1, commentary: String(repeating: "No condemnation in Christ Jesus. ", count: 200)),
        ], style: style)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let coordinator = CommentaryTextPane.Coordinator()
        let scrollView = CommentaryScrollView(frame: try #require(window.contentView).bounds)
        window.contentView?.addSubview(scrollView)
        coordinator.attach(to: scrollView)
        coordinator.show(document)
        scrollView.tile()
        window.contentView?.layoutSubtreeIfNeeded()
        for y in [40.0, 320, 600] {
            let hit = window.contentView?.hitTest(NSPoint(x: 200, y: y))
            #expect(hit is CommentaryTextView, "at \(y): \(hit.map { String(describing: type(of: $0)) } ?? "nil")")
        }
        // The room under the last passage is still there, as text.
        let storage = try #require((scrollView.documentView as? NSTextView)?.textStorage)
        #expect(storage.attribute(.lampCommentaryTail, at: storage.length - 1, effectiveRange: nil) != nil)
        #expect(scrollView.contentInsets.bottom == 0)
        // Select All copies the commentary, not the empty paragraph after it,
        // and a caret starts inside the commentary, not after that paragraph.
        let textView = try #require(scrollView.documentView as? CommentaryTextView)
        #expect(NSMaxRange(textView.selectedRange()) <= document.text.length)
        textView.selectAll(nil)
        #expect(textView.selectedRange() == NSRange(location: 0, length: document.text.length))
        // A heading's level is drawn, so it is part of what the cache keys on.
        let level1 = LampCommentaryUnit(unitID: "a", moduleID: "NIC", moduleName: "NIC", bookNumber: 45, chapterNumber: 8,
                                        startReference: 45_008_001, endReference: nil, unitType: "block", level: 1, title: "T", orderIndex: 1)
        let level2 = LampCommentaryUnit(unitID: "a", moduleID: "NIC", moduleName: "NIC", bookNumber: 45, chapterNumber: 8,
                                        startReference: 45_008_001, endReference: nil, unitType: "block", level: 2, title: "T", orderIndex: 1)
        #expect(CommentaryDocument.contentFingerprint(of: [level1]) != CommentaryDocument.contentFingerprint(of: [level2]))
        // The pane's own scroller keeps the system's style, so an overlay
        // scroller takes no width from the text.
        #expect(scrollView.verticalScroller is CommentaryScroller)
        #expect(scrollView.scrollerStyle == NSScroller.preferredScrollerStyle)
        #expect(scrollView.verticalScroller?.scrollerStyle == NSScroller.preferredScrollerStyle)
        coordinator.detach()
    }

    /// Scrolling the commentary leads the reader, so while a person scrolls
    /// it the reader's report of where it now is must not pull the pane back
    /// to a passage's start. Once the scroll is over, the reader leads again.
    @Test @MainActor func aPaneBeingScrolledIsNotPulledBackByTheReader() throws {
        let long = String(repeating: "Paul now contrasts the situation he has just described. ", count: 300)
        let document = CommentaryDocument.build(title: "Romans 8", units: [
            unit("a", start: 45_008_001, order: 1, commentary: long),
            unit("b", start: 45_008_010, order: 2, commentary: long),
        ], style: style)
        let defaults = try #require(UserDefaults(suiteName: "CommentaryPaneTests-\(UUID().uuidString)"))
        let scrollLink = ReaderScrollLink(defaults: defaults)
        scrollLink.isLinked = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 410, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        let coordinator = CommentaryTextPane.Coordinator()
        let scrollView = CommentaryScrollView(frame: try #require(window.contentView).bounds)
        window.contentView?.addSubview(scrollView)
        coordinator.attach(to: scrollView)
        coordinator.scrollLink = scrollLink
        coordinator.show(document)
        scrollView.tile()
        window.contentView?.layoutSubtreeIfNeeded()

        // A person scrolls the pane down into the first passage: the wheel
        // event marks it as theirs (a test has no event loop to animate it),
        // and the view moves as the scroll would move it.
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        scrollView.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1_000))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let scrolled = scrollView.contentView.bounds.minY
        #expect(scrolled > 100)

        // The reader, moved by the pane, reports the passage's first verse.
        scrollLink.readerAnchors.send(45_008_001)
        #expect(scrollView.contentView.bounds.minY == scrolled)

        // Once the scroll is over, the reader leads again.
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        Thread.sleep(forTimeInterval: 0.35)
        scrollLink.readerAnchors.send(45_008_010)
        #expect(scrollView.contentView.bounds.minY > scrolled)
        coordinator.detach()
    }
}
