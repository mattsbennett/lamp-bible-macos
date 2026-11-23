import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import WebKit

/// What a click on a footnote's marker does while writing.
///
/// The page's own default is `jump`, which is what the phone wants and what
/// read mode has always done. Every editor says which it wants on attach
/// rather than only the one that differs: pages are pooled, so an editor
/// taking a page another has used would otherwise inherit its answer.
enum TipTapFootnoteClicks: String {
    /// The caret goes to the start of the note, where the note is on the page.
    case jump
    /// The note opens in a panel by its marker, to be written in there. A note
    /// that isn't on the page is reported to the host instead.
    case popover
}

/// The selection-dependent state reported by TipTap. Keeping this in Swift lets
/// the native toolbar show which formatting is active without interpreting HTML.
struct TipTapSelectionState: Equatable {
    var bold = false
    var italic = false
    var heading = 0
    var blockquote = false
    var bulletList = false
    var orderedList = false
    var link = false
    var table = false
}

enum TipTapTextStyle {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bold
    case italic
    case quote
    case bullet
    case numberedList
    case indent
    case outdent
}

/// A native macOS host for the same TipTap bundle used by the iOS devotional
/// editor. Markdown remains the persisted source of truth; the web editor only
/// provides a visual editing surface for it.
struct TipTapEditorView: NSViewRepresentable {
    @Binding var markdownContent: String
    let fontSize: Double
    /// Which media folder this document's relative image and audio links belong
    /// to. A devotional passes its own identifier; a document with no media of
    /// its own passes a scope that simply has no folder.
    let mediaScopeID: String
    /// Which media folder `mediaScopeID` names. Writing is the default
    /// because it had media to itself until notes gained it.
    var mediaScope: LampMediaScope = .devotional
    let libraryRootURL: URL
    let isVisible: Bool
    var mediaReferences: [LampDevotionalMediaReference] = []
    /// Sizes the page to its content instead of the viewport, for hosts that
    /// place the editor inside their own scrolling column rather than giving it
    /// a pane of its own. See `TipTapEditorCoordinator.applyCompactLayout`.
    var compactLayout = false
    /// What the page shows the writing as. A preview passes `.read`.
    var viewMode: TipTapViewMode = .edit
    /// What the empty editor says, when not the bundle's own.
    var placeholder: String?
    /// Whether a single line break is a line break rather than a space. Notes
    /// are plain lines as often as Markdown: typed on the phone, each line is
    /// its own, and read as Markdown they would run together on save.
    var lineBreaks = false
    /// What a click on a footnote's marker does here.
    var footnoteClicks: TipTapFootnoteClicks = .jump
    /// The face the writing is set in, when the host has one: the writing
    /// editor sets its prose as the preview does, so a writer sees the page
    /// their readers will. Nil keeps the bundle's own system sans.
    var proseTypeface: ProseTypeface?
    var onCoordinatorReady: (TipTapEditorCoordinator) -> Void

    func makeCoordinator() -> TipTapEditorCoordinator {
        TipTapEditorCoordinator(
            mediaScopeID: mediaScopeID,
            richMediaIDs: Set(mediaReferences.map(\.id))
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        // A page already loaded and waiting, when the pool has one: making a
        // web view costs tens of milliseconds and tens of megabytes, and a
        // note inspector made one every time a verse was selected.
        let page = TipTapEditorPool.shared.page(libraryRootURL: libraryRootURL, compact: compactLayout)
        let webView = page.webView
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        coordinator.hostWantsVisible = isVisible
        coordinator.updateMediaScopeID(mediaScopeID)
        coordinator.updateRichMediaIDs(Set(mediaReferences.map(\.id)))
        coordinator.onContentChanged = bindingUpdater
        coordinator.usesCompactLayout = compactLayout
        coordinator.setViewMode(viewMode)
        coordinator.usesLineBreaks = lineBreaks
        coordinator.setFootnoteClicks(footnoteClicks)
        coordinator.setMediaMap(coordinator.mediaMap(
            scopeID: mediaScopeID,
            scope: mediaScope,
            references: mediaReferences,
            libraryRootURL: libraryRootURL
        ))
        coordinator.setContent(markdownContent)
        coordinator.setFontSize(fontSize)
        coordinator.setTheme(isDark: context.environment.colorScheme == .dark)
        coordinator.setProseTypeface(proseTypeface)
        coordinator.setPlaceholder(placeholder)
        coordinator.onReady = { [weak coordinator] in coordinator.map(onCoordinatorReady) }
        // Last: a page that is already ready takes everything above at once.
        coordinator.attach(page)
        applyBackgroundColor(to: webView, coordinator: coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.hostWantsVisible = isVisible
        // A pooled page comes back in whatever mode its last host left it.
        coordinator.setViewMode(viewMode)
        coordinator.updateMediaScopeID(mediaScopeID)
        coordinator.updateRichMediaIDs(Set(mediaReferences.map(\.id)))
        coordinator.onContentChanged = bindingUpdater
        coordinator.setFootnoteClicks(footnoteClicks)
        coordinator.setMediaMap(coordinator.mediaMap(
            scopeID: mediaScopeID,
            scope: mediaScope,
            references: mediaReferences,
            libraryRootURL: libraryRootURL
        ))
        coordinator.setFontSize(fontSize)
        coordinator.setTheme(isDark: context.environment.colorScheme == .dark)
        coordinator.setProseTypeface(proseTypeface)
        applyBackgroundColor(to: webView, coordinator: coordinator)

        // Changes made by TipTap have already updated lastKnownMarkdown. A
        // different value here therefore came from loading a devotional or from
        // the Markdown editor and needs to be pushed into the visual editor.
        if markdownContent != coordinator.lastKnownMarkdown {
            coordinator.setContent(markdownContent)
        }
    }

    static func dismantleNSView(
        _ webView: WKWebView,
        coordinator: TipTapEditorCoordinator
    ) {
        coordinator.detach()
    }

    /// The page paints no colour of its own and lets the window's ground show
    /// through, which is how it matches the reader and every other surface.
    ///
    /// It used to resolve `NSColor.windowBackgroundColor` and hand that to the
    /// web view, on the reasoning that the Markdown text view draws nothing
    /// and so "shows the window colour straight through". The second half is
    /// right and the first is not: what the window shows is not that colour.
    /// Measured in one capture, the window's ground came out 0.1863 while
    /// `windowBackgroundColor` came out 0.1569, so the writing page sat a step
    /// darker than the reader's page and the writing list beside it. Showing
    /// the ground rather than naming a colour cannot drift that way again.
    private func applyBackgroundColor(
        to webView: WKWebView,
        coordinator: TipTapEditorCoordinator
    ) {
        if Self.webViewCanBeTransparent {
            webView.underPageBackgroundColor = .clear
            webView.setValue(false, forKey: "drawsBackground")
            coordinator.setBackgroundColor("transparent")
        } else {
            let color = NSColor.windowBackgroundColor
            webView.underPageBackgroundColor = color
            coordinator.setBackgroundColor(cssColor(for: color, in: webView.effectiveAppearance))
        }
    }

    /// Whether this WebKit still lets a web view draw no background of its own.
    ///
    /// `drawsBackground` is not public API, so it is asked for rather than
    /// assumed: if a future WebKit drops it, the editor paints
    /// `windowBackgroundColor` as it did before, which is a shade off the
    /// window's ground rather than a white page.
    ///
    /// Nothing public reaches this. `underPageBackgroundColor` covers only the
    /// rubber-band area, and clearing the view's layer does not survive — both
    /// were tried, and each left the page flat white over the window.
    ///
    /// **Revisit this if the Mac app is ever submitted to the App Store.** It
    /// ships as a notarized disk image updated through Sparkle, so an
    /// undocumented key is a maintenance risk and not a review one; under App
    /// Review it would be neither, and the page would need a colour again.
    /// Asked of the class, not of an instance: a `static let` is initialised
    /// on whichever thread first reads it, and a `WKWebView` has to be built
    /// on the main one, so constructing a throwaway here to ask put a
    /// main-thread requirement on an innocent-looking property access.
    fileprivate static let webViewCanBeTransparent: Bool =
        WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:"))

    private func cssColor(for color: NSColor, in appearance: NSAppearance) -> String {
        Self.cssColor(for: color, in: appearance)
    }

    /// Dynamic system colours have no fixed value until they are resolved against
    /// an appearance, and CSS needs a literal.
    fileprivate static func cssColor(for color: NSColor, in appearance: NSAppearance) -> String {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private var bindingUpdater: (String) -> Void {
        let binding = $markdownContent
        return { markdown in
            DispatchQueue.main.async {
                binding.wrappedValue = markdown
            }
        }
    }

    /// WKWebView grants local-file access relative to the loaded document. Cache
    /// the bundled single-file editor under the library root so it can also render
    /// devotional media without granting access to unrelated folders.
    fileprivate static func cachedEditorURL(in libraryRootURL: URL) throws -> URL {
        #if SWIFT_PACKAGE
        let resourceBundle = Bundle.module
        #else
        let resourceBundle = Bundle.main
        #endif

        guard let bundledURL = resourceBundle.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "TipTapEditor"
        ) else {
            throw TipTapEditorError.missingBundle
        }

        let cacheDirectory = libraryRootURL
            .appendingPathComponent(".TipTapEditor", isDirectory: true)
        let cachedURL = cacheDirectory.appendingPathComponent("index.html")
        let bundledData = try Data(contentsOf: bundledURL)
        let cachedData = try? Data(contentsOf: cachedURL)
        if cachedData != bundledData {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
            try bundledData.write(to: cachedURL, options: .atomic)
        }
        return cachedURL
    }
}

private enum TipTapEditorError: LocalizedError {
    case missingBundle

    var errorDescription: String? {
        "The bundled TipTap editor could not be found."
    }
}

final class TipTapEditorCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: WKWebView?
    /// The pooled page this editor is showing, while it holds one.
    private(set) var page: TipTapEditorPage?
    /// Whether the page shows this editor's text yet: set when the read-back
    /// after the first text it gave the page returns. A pooled page holds the
    /// last document until then, and the editor serialises what is on the
    /// page, so before this nothing is read from the page — content comes from
    /// Swift's own copy instead, and a change the page reports is not this
    /// editor's.
    private var hasLoadedContent = false
    /// The first text after taking a page starts a fresh undo history, so
    /// nothing of the page's last document can be undone back into.
    private var needsFreshHistory = true

    var onContentChanged: ((String) -> Void)?
    var onSelectionChanged: ((TipTapSelectionState) -> Void)?
    /// Called once the editor can take commands, on a later turn of the run
    /// loop than the one that made it ready. See `reportReady`.
    var onReady: (() -> Void)?
    /// Called once the editor has given its page back, also on a later turn,
    /// so a host can let go of it. Another editor may have reported ready
    /// first, so a host clears only the editor it still holds.
    var onDetached: (() -> Void)?
    /// Reported by the compact layout only, so a host that lets the editor grow
    /// can size it to its text.
    var onContentHeightChanged: ((Double) -> Void)?
    /// The web view is opaque to `@FocusState`, so caret focus is reported out.
    var onFocusChanged: ((Bool) -> Void)?
    /// A footnote's marker was clicked while writing and its note is not on
    /// the page, so the page has done nothing and left it to the host. Carries
    /// the writing's own label for the note, not the number a reader sees.
    var onFootnoteNotInPage: ((String) -> Void)?
    var onFindStatusChanged: ((WritingFindStatus) -> Void)?
    /// The writer cleared marks from the page, by its ✓ button: the writing's
    /// Markdown with a marker at each edge of what was cleared
    /// (`LampWritingReview.markedRange(in:of:)` reads it).
    /// The ✓ pressed: the writing's Markdown with markers round what to
    /// clear, and the page's own Markdown of the same document, unmarked,
    /// where the page sends it.
    var onReviewClear: ((TipTapReviewClear) -> Void)?
    /// The page asking for passages to be put back as the assistant found
    /// them, named by the id it was given with the marks. Sent before it
    /// changes anything: the host works out the writing that results and
    /// hands it back through `restoreWording`.
    var onReviewRestore: ((TipTapReviewRestore) -> Void)?
    /// Each of these answers is given what the marks it answers were sent
    /// for (`setReviewMarks(_:changes:askedIn:)`), not what the host is
    /// showing when it arrives: the page answers after a turn of its own,
    /// and the writer can have moved to another document meanwhile.
    ///
    /// The page could not place the marks it was sent — its text was a
    /// moment ahead of the host's — so the host sends them again.
    var onReviewMarksRejected: ((AnyHashable?) -> Void)?
    /// The page took the marks and drew them.
    var onReviewMarksDrawn: ((AnyHashable?) -> Void)?
    /// The page holds this text and could not draw every mark: one mark's
    /// markers made the document another where they fell, so it placed the
    /// rest without them. With how many it drew, which may be none.
    var onReviewMarksPartlyDrawn: ((AnyHashable?, Int) -> Void)?
    /// What the review marks last sent were sent for.
    private var reviewMarksAskedIn: AnyHashable?
    /// Whether the page has cleared a block since it was last sent marks:
    /// the next marks go to it then, though they match the last.
    private var pageClearedSinceMarks = false
    /// The review marks shown, as the writing's Markdown with markers, kept
    /// so every load puts them back: a document loaded into the page starts
    /// with none.
    private var reviewMarks: String?
    private var reviewChanges: [LampWritingReview.Change?] = []
    var usesCompactLayout = false
    /// Set before the first text, since it decides how that text is read.
    var usesLineBreaks = false

    private(set) var lastKnownMarkdown = ""
    private var mediaScopeID: String
    private var richMediaIDs: Set<String>
    private var isReady = false
    /// What the page is showing the writing as. The page is editable only in
    /// `edit`; in `read` it draws the same writing, with its own marks,
    /// footnotes and media, and refuses to be typed into.
    private(set) var viewMode: TipTapViewMode = .edit
    private var pendingContent: String?
    /// The editor's own Markdown for the text it was last given, before any edit.
    private var markdownAsLoaded: String?
    /// Whether the text has been edited since the editor was last given text.
    private var hasEdits = false
    private var pendingMediaMap: [String: String]?
    private var loadAttempts = 0
    /// What the page should show besides its text, kept so a page started
    /// again after a failed load is given it again.
    private var shownMediaMap: [String: String]?
    private var shownFontSize: Double?
    private var shownPlaceholder: String?
    private var shownTheme: Bool?
    private var shownBackgroundColor: String?
    /// Which text the last read-back answers for: one from an earlier text
    /// arriving after a newer one went in says nothing about the page now.
    private var loadGeneration = 0
    /// The token this editor's last `load` gave its document, which the page
    /// returns on every message about it. Unique across editors, so a message
    /// still in flight from a page's last document never matches the next.
    private var documentToken: Int?
    private static var nextDocumentToken = 0
    private var pendingFontSize: Double?
    private var pendingPlaceholder: String?
    private var pendingTheme: Bool?
    private var pendingBackgroundColor: String?
    private var appliedBackgroundColor: String?
    private var shownProseTypeface: ProseTypeface??
    private var pendingProseTypeface: ProseTypeface??
    private var appliedProseTypeface: ProseTypeface??
    private var appliedTheme: Bool?
    private var appliedMediaMap: [String: String]?
    private var appliedFontSize: Double?
    private var shownFootnoteClicks: TipTapFootnoteClicks?
    private var pendingFootnoteClicks: TipTapFootnoteClicks?
    private var appliedFootnoteClicks: TipTapFootnoteClicks?
    /// The media listing and what it was listed from, so the folder is read
    /// again only when it could have changed.
    private var listedMedia: (source: MediaSource, map: [String: String])?

    /// Whether the host wants the editor on screen at all. Kept apart from
    /// `hasPainted` so switching surfaces never re-exposes an unpainted view.
    var hostWantsVisible = true {
        didSet {
            guard hostWantsVisible != oldValue else { return }
            updateVisibility()
        }
    }
    private var hasPainted = false

    init(mediaScopeID: String, richMediaIDs: Set<String> = []) {
        self.mediaScopeID = mediaScopeID
        self.richMediaIDs = richMediaIDs
    }

    func updateMediaScopeID(_ mediaScopeID: String) {
        self.mediaScopeID = mediaScopeID
    }

    func updateRichMediaIDs(_ ids: Set<String>) {
        richMediaIDs = ids
    }

    /// What the document's media folder holds, as the page addresses it: a map
    /// from each filename, and from each reference's identifier, to a URL the
    /// web view may load.
    ///
    /// Remembered against what it was listed from, because the host asks for
    /// this on every update — which in the writing editor is several times a
    /// second while the writer types, and again on every change anywhere in the
    /// library. Reading the folder each of those times put the filesystem on
    /// the keystroke path for an answer that almost never differs. The folder's
    /// own change time is part of what is remembered, so a file put there by
    /// anything other than Lamp still appears.
    func mediaMap(
        scopeID: String,
        scope: LampMediaScope,
        references: [LampMediaReference],
        libraryRootURL: URL
    ) -> [String: String] {
        // The scope's own folder. This was the third place `Media/Devotionals`
        // was written out, and the one that decided whether a picture is
        // found: a note's file is under Media/Notes, so a note reopened after
        // a save showed a broken image while the two core copies were right.
        let directory = LampPortableDevotionalMedia.folderURL(
            rootURL: libraryRootURL, scope: scope, ownerID: scopeID
        ) ?? libraryRootURL
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(scope.folder, isDirectory: true)
            .appendingPathComponent(scopeID, isDirectory: true)
        let source = MediaSource(
            directory: directory,
            references: references,
            changedAt: LampFileModification.date(of: directory)
        )
        if let listedMedia, listedMedia.source == source { return listedMedia.map }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        var map = Dictionary(uniqueKeysWithValues: files.map {
            ($0.lastPathComponent, $0.absoluteString)
        })
        for reference in references where
            LampPortableDevotionalMedia.isSafePathComponent(reference.filename) {
            let url = directory.appendingPathComponent(reference.filename)
            if FileManager.default.fileExists(atPath: url.path) {
                map[reference.id] = url.absoluteString
            }
        }
        listedMedia = (source, map)
        return map
    }

    /// Everything a media listing is drawn from.
    struct MediaSource: Equatable {
        let directory: URL
        let references: [LampDevotionalMediaReference]
        let changedAt: Date?
    }

    /// Driven by the page reporting that it has produced a frame. Neither `ready`
    /// nor `didFinish` is that moment — both fire while the web view is still
    /// showing its blank white backing, and revealing on either put the flash back.
    private func markPainted() {
        guard !hasPainted else { return }
        hasPainted = true
        updateVisibility()
    }

    /// A page that never reports painting — a failed load showing the error HTML,
    /// or a bundle whose script did not run — must still be shown, or the editor
    /// is a permanently blank pane.
    private func scheduleRevealFallback() {
        guard !hasPainted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.markPainted()
        }
    }

    /// Hidden until the page shows this editor's own text: a pooled page holds
    /// the last document until then, and nothing should be typed into that.
    private func updateVisibility() {
        webView?.isHidden = !(hostWantsVisible && hasPainted && hasLoadedContent)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        scheduleRevealFallback()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        scheduleRevealFallback()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        scheduleRevealFallback()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            becomeReady()

        case "painted":
            markPainted()

        default:
            receiveFromReadyPage(type: type, body: body)
        }
    }

    /// Shows this editor in a pooled page, which may already be loaded.
    @MainActor
    func attach(_ page: TipTapEditorPage) {
        self.page = page
        webView = page.webView
        needsFreshHistory = true
        page.owner = self
        if page.isReady { becomeReady() }
        if page.hasPainted {
            markPainted()
        } else if page.hasFinishedLoading {
            scheduleRevealFallback()
        }
        updateVisibility()
    }

    /// Gives the page back to the pool. Nothing this editor sent the page is
    /// read after this, and nothing the page reports reaches this editor.
    @MainActor
    func detach() {
        guard let page else { return }
        page.owner = nil
        self.page = nil
        webView = nil
        hasLoadedContent = false
        // Not ready for anything any more: the host lets go of this editor a
        // turn later, and a command in that turn should be answered as one
        // to an editor that isn't ready, not sent to a page it no longer has.
        isReady = false
        TipTapEditorPool.shared.giveBack(page)
        // Detaching happens as SwiftUI takes the view down, inside a view
        // update, where state a host sets is dropped.
        let report = onDetached
        DispatchQueue.main.async { report?() }
    }

    private func becomeReady() {
        guard !isReady else { return }
        isReady = true
        if usesCompactLayout { applyCompactLayout() }
        applyViewMode()
        evaluate("window.editorAPI.setLineBreaks(\(usesLineBreaks))")
        if let mediaMap = pendingMediaMap {
            pendingMediaMap = nil
            setMediaMap(mediaMap)
        }
        if let content = pendingContent {
            pendingContent = nil
            setContent(content)
        }
        if let behaviour = pendingFootnoteClicks {
            pendingFootnoteClicks = nil
            setFootnoteClicks(behaviour)
        }
        if let fontSize = pendingFontSize {
            pendingFontSize = nil
            setFontSize(fontSize)
        }
        if let placeholder = pendingPlaceholder {
            pendingPlaceholder = nil
            setPlaceholder(placeholder)
        }
        if let isDark = pendingTheme {
            pendingTheme = nil
            setTheme(isDark: isDark)
        }
        if let color = pendingBackgroundColor {
            pendingBackgroundColor = nil
            setBackgroundColor(color)
        }
        if let typeface = pendingProseTypeface {
            pendingProseTypeface = nil
            setProseTypeface(typeface)
        }
        reportReady()
    }

    /// A pooled page is ready as it is attached, which is inside SwiftUI's view
    /// update, and a host told then sets state that SwiftUI drops: its toolbar
    /// stays disabled and its commands go nowhere. So the host is told on the
    /// next turn, and not at all if the editor has given its page back by then.
    private func reportReady() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.page != nil, self.isReady else { return }
            self.onReady?()
        }
    }

    private func receiveFromReadyPage(type: String, body: [String: Any]) {
        // About another document: one this page held before, still in flight.
        if let token = body["token"] as? Int, token != documentToken { return }
        switch type {
        case "contentChanged":
            // Before this editor's own text is on the page, a change is the last
            // document's, never an edit to this one.
            guard hasLoadedContent, let editorMarkdown = body["markdown"] as? String else { return }
            let markdown = portableMarkdown(from: editorMarkdown)
            // Soon after it is given text, the editor reports its own restyling
            // of it — list markers, escapes, spacing — as a change. Until
            // something is edited, that isn't one, and taking it would rewrite
            // a document that was only opened.
            if !hasEdits, markdown == markdownAsLoaded { return }
            hasEdits = true
            lastKnownMarkdown = markdown
            onContentChanged?(markdown)

        case "selectionChanged":
            onSelectionChanged?(TipTapSelectionState(
                bold: body["bold"] as? Bool ?? false,
                italic: body["italic"] as? Bool ?? false,
                heading: body["heading"] as? Int ?? 0,
                blockquote: body["blockquote"] as? Bool ?? false,
                bulletList: body["bulletList"] as? Bool ?? false,
                orderedList: body["orderedList"] as? Bool ?? false,
                link: body["link"] as? Bool ?? false,
                table: body["table"] as? Bool ?? false
            ))

        case "contentHeight":
            guard let height = body["height"] as? Double else { return }
            onContentHeightChanged?(height)

        case "focusChanged":
            onFocusChanged?(body["focused"] as? Bool ?? false)

        case "footnoteTapped":
            // Only the writing case is the host's: reading a devotional, the
            // page takes a tap to the note itself.
            guard body["editing"] as? Bool == true,
                  let id = body["id"] as? String
            else { return }
            onFootnoteNotInPage?(id)

        case "searchChanged":
            onFindStatusChanged?(Self.findStatus(from: body))

        case "reviewClear":
            // The page has taken the block's marks off already, so the
            // marks sent next go to it even if they are the ones it was
            // last sent: they may be what puts back a mark it took off.
            pageClearedSinceMarks = true
            guard let clear = reviewClear(from: body) else { return }
            onReviewClear?(clear)

        // An undo or a redo can bring back words a passage could be put
        // back from, or a mark that was deleted, so what the page was told
        // no longer describes it.
        case "reviewMarksStale":
            onReviewMarksRejected?(reviewMarksAskedIn)


        case "reviewRestore":
            guard let id = body["id"] as? String else { return }
            onReviewRestore?(TipTapReviewRestore(
                id: id, pageText: (body["plain"] as? String).map(portableMarkdown(from:))
            ))

        default:
            break
        }
    }

    /// Frees the page from viewport-sized layout so the editor is exactly as tall
    /// as what has been written, and has it report that height and caret focus.
    ///
    /// The bundle sizes itself for a full pane — `100vh` minimums and a deep
    /// bottom padding for the on-screen keyboard — which inside a host's own
    /// scrolling column would leave an empty webview swallowing scroll events.
    /// `load` reports the height of the text it puts in, even when unchanged, so
    /// an editor given a pooled page learns its height.
    private func applyCompactLayout() {
        evaluate("window.editorAPI.setReportsHeight(true)")
    }

    func setContent(_ markdown: String) {
        lastKnownMarkdown = markdown
        markdownAsLoaded = nil
        hasEdits = false
        loadGeneration += 1
        // Only the first text in a page waits to be shown and read: before it,
        // the page may hold another document. Later text replaces this
        // editor's own — from the Markdown editor, say — and reads after it are
        // ordered after it, so hiding the editor then would only flicker.
        if needsFreshHistory {
            hasLoadedContent = false
            updateVisibility()
        }
        guard isReady else {
            pendingContent = markdown
            return
        }
        let generation = loadGeneration
        // The first text an editor gives its page starts a fresh undo history
        // where the bundle can, so neither the page's last document nor an empty
        // page is one undo away. Later text replaces in place, as an edit would.
        let content = Self.javascriptString(editorMarkdown(from: markdown))
        let replace: String
        if needsFreshHistory {
            Self.nextDocumentToken += 1
            documentToken = Self.nextDocumentToken
            replace = "if (window.editorAPI.load) { window.editorAPI.load(\(content), \(Self.nextDocumentToken)); } else { window.editorAPI.setContent(\(content)); }"
        } else {
            replace = "window.editorAPI.setContent(\(content));"
        }
        needsFreshHistory = false
        // Text and read-back in one script, so no keystroke can fall between
        // them and be taken for the text as it was given.
        evaluate("""
            \(replace)
            window.editorAPI.getContent();
            """) { [weak self] result in
            guard let self, self.loadGeneration == generation else { return }
            guard let editorMarkdown = result as? String else {
                self.recoverFromFailedLoad()
                return
            }
            self.markdownAsLoaded = self.portableMarkdown(from: editorMarkdown)
            self.hasLoadedContent = true
            self.loadAttempts = 0
            self.applyReviewMarks()
            self.updateVisibility()
        }
    }

    /// The text did not go in, or the page's process died: start the page again
    /// and give it the text once more. A fresh page holds no other document, so
    /// if the second attempt fails too its text is still only ever this
    /// editor's, and it is shown rather than held back for ever.
    private func recoverFromFailedLoad() {
        guard let webView else { return }
        loadAttempts += 1
        page?.markUnfitForReuse()
        guard loadAttempts <= 1 else {
            hasLoadedContent = true
            updateVisibility()
            return
        }
        isReady = false
        hasPainted = false
        appliedTheme = nil
        appliedBackgroundColor = nil
        appliedProseTypeface = nil
        appliedMediaMap = nil
        appliedFontSize = nil
        appliedFootnoteClicks = nil
        needsFreshHistory = true
        pendingContent = lastKnownMarkdown
        pendingMediaMap = shownMediaMap
        pendingFontSize = shownFontSize
        pendingFootnoteClicks = shownFootnoteClicks
        pendingPlaceholder = shownPlaceholder
        pendingTheme = shownTheme
        pendingBackgroundColor = shownBackgroundColor
        pendingProseTypeface = shownProseTypeface
        page?.prepareForReload()
        webView.reload()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recoverFromFailedLoad()
    }

    func getContent(completion: @escaping (String) -> Void) {
        guard webView != nil, isReady, hasLoadedContent else {
            completion(lastKnownMarkdown)
            return
        }
        evaluate("window.editorAPI.getContent()") { [weak self] result in
            guard let self else {
                completion("")
                return
            }
            // A script that failed has no answer, which is not an empty document.
            guard let editorMarkdown = result as? String else {
                completion(self.lastKnownMarkdown)
                return
            }
            let markdown = self.portableMarkdown(from: editorMarkdown)
            self.lastKnownMarkdown = markdown
            completion(markdown)
        }
    }

    /// The editor's text if it has been edited since it was last given text,
    /// or nil if not. The editor writes Markdown in its own style, so its text
    /// differing from what it was given doesn't by itself mean an edit; this
    /// lets a document that was only looked at stay exactly as it was written.
    func getEditedContent(completion: @escaping (String?) -> Void) {
        guard webView != nil, isReady, hasLoadedContent else {
            completion(hasEdits ? lastKnownMarkdown : nil)
            return
        }
        evaluate("window.editorAPI.getContent()") { [weak self] result in
            guard let self else {
                completion(nil)
                return
            }
            guard let editorMarkdown = result as? String else {
                completion(self.hasEdits ? self.lastKnownMarkdown : nil)
                return
            }
            let markdown = self.portableMarkdown(from: editorMarkdown)
            if !self.hasEdits, markdown == self.markdownAsLoaded {
                completion(nil)
                return
            }
            // Typed since the editor last reported, which it does after a pause.
            self.hasEdits = true
            self.lastKnownMarkdown = markdown
            completion(markdown)
        }
    }

    func applyStyle(_ style: TipTapTextStyle) {
        guard isReady else { return }
        let command = switch style {
        case .paragraph: "setParagraph()"
        case .heading1: "setHeading(1)"
        case .heading2: "setHeading(2)"
        case .heading3: "setHeading(3)"
        case .bold: "toggleBold()"
        case .italic: "toggleItalic()"
        case .quote: "toggleBlockquote()"
        case .bullet: "toggleBulletList()"
        case .numberedList: "toggleOrderedList()"
        case .indent: "indent()"
        case .outdent: "outdent()"
        }
        evaluate("window.editorAPI.\(command)")
    }

    func insertLink(url: String) {
        guard isReady else { return }
        evaluate("window.editorAPI.insertLink(\(Self.javascriptString(url)))")
    }

    /// TipTap's link command formats a selection. For an empty selection, set a
    /// link mark, type the friendly scripture label through WebKit, then clear the
    /// mark so subsequent typing is ordinary text.
    func insertTextLink(label: String, url: String) {
        guard isReady else { return }
        evaluate("""
            window.editorAPI.insertLink(\(Self.javascriptString(url)));
            document.execCommand('insertText', false, \(Self.javascriptString(label)));
            window.editorAPI.insertLink('');
            """)
    }

    func getSelectedText(completion: @escaping (String) -> Void) {
        guard isReady else {
            completion("")
            return
        }
        evaluate("window.editorAPI.getSelectedText()") { result in
            completion(result as? String ?? "")
        }
    }

    func insertImage(mediaID: String, caption: String, localURL: URL) {
        guard isReady else { return }
        evaluate("window.editorAPI.insertImage(\(Self.javascriptString(mediaID)), \(Self.javascriptString(caption)), \(Self.javascriptString(localURL.absoluteString)))")
    }

    func insertAudio(mediaID: String, caption: String) {
        guard isReady else { return }
        evaluate("window.editorAPI.insertAudioBlock(\(Self.javascriptString(mediaID)), \(Self.javascriptString(caption)))")
    }

    /// Puts a footnote's marker where the caret is, and its definition with
    /// the writing's others beneath the prose. An empty note is the ordinary
    /// case: the panel opens on the new marker for it to be written in.
    func insertFootnote(id: String, content: String = "") {
        guard isReady else { return }
        evaluate("window.editorAPI.insertFootnote(\(Self.javascriptString(id)), \(Self.javascriptString(content)))")
    }

    // MARK: - Review marks

    /// Shows the writing's review marks: its Markdown with a marker at each
    /// edge of what is still marked (`LampWritingReview.markedMarkdown`), or
    /// nil for none, and what a restore of each would come to. Kept, and
    /// put back after each load.
    func setReviewMarks(_ marked: String?, changes: [LampWritingReview.Change?] = [], askedIn: AnyHashable? = nil) {
        reviewMarksAskedIn = askedIn
        guard marked != reviewMarks || changes != reviewChanges || pageClearedSinceMarks else { return }
        reviewMarks = marked
        reviewChanges = changes
        applyReviewMarks()
    }

    private func applyReviewMarks() {
        guard isReady, hasLoadedContent else { return }
        pageClearedSinceMarks = false
        // Marks are drawn while a writing is being written, never while it
        // is being read, and the count follows them. Owner's decision,
        // 2026-11-22. Refused here rather than left to each caller not to
        // ask: a page shows a writing in both modes, and the preview takes
        // its page from the same pool the editor does.
        let marks = viewMode == .edit ? reviewMarks : nil
        let argument = marks.map { Self.javascriptString(editorMarkdown(from: $0)) } ?? "null"
        // One to each marked passage, in the order the page finds them. A
        // page from before this takes the marks and ignores the rest.
        let changes = (try? JSONEncoder().encode(reviewChanges))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let askedIn = reviewMarksAskedIn
        evaluate(
            "window.editorAPI.setReviewMarks ? window.editorAPI.setReviewMarks(\(argument), \(changes)) : true"
        ) { [weak self] placed in
            // Both answers, not only the refusal. Whether the marks are
            // drawn is what the writer is told about, and that is this
            // one fact — not whether there are ranges to send, which
            // there are in exactly the cases the page turns down.
            if placed as? Bool == false {
                self?.onReviewMarksRejected?(askedIn)
            } else if placed as? Bool == true {
                self?.onReviewMarksDrawn?(askedIn)
            } else if let partly = placed as? [String: Any], (partly["unshown"] as? Int ?? 0) > 0 {
                self?.onReviewMarksPartlyDrawn?(askedIn, partly["drawn"] as? Int ?? 0)
            }
        }
    }

    /// Hands the page the writing a restore makes, for it to put in place
    /// as one undoable edit of its own, and says what it holds afterwards.
    ///
    /// `expected` is the text the restore was worked out in: the page
    /// refuses unless that is what it is showing, so a press that raced the
    /// writer's typing changes nothing. Nil where it refused, or where the
    /// page is older than this.
    func restoreWording(
        _ markdown: String, expected: String, completion: @escaping (TipTapRestore) -> Void
    ) {
        guard isReady else { return completion(.unsupported) }
        let wanted = Self.javascriptString(editorMarkdown(from: markdown))
        let base = Self.javascriptString(editorMarkdown(from: expected))
        // Whether the page can do this at all is answered apart from
        // whether it would: a page older than this cannot, and the writing
        // is then put in place the way a turn's draft is, while a page that
        // refuses has seen the text move, and nothing should go anywhere.
        let script = "window.editorAPI.restoreWording"
            + " ? { known: true, held: window.editorAPI.restoreWording(\(wanted), \(base)) }"
            + " : { known: false }"
        evaluate(script) { [weak self] answer in
            guard let self, let answer = answer as? [String: Any],
                  answer["known"] as? Bool == true else { return completion(.unsupported) }
            guard let held = answer["held"] as? String else { return completion(.refused) }
            completion(.done(self.portableMarkdown(from: held)))
        }
    }

    /// What the page's own selection stands in, for a restore asked for
    /// from the menu rather than from a passage's own button.
    ///
    /// The ids are the page's, given to it with the marks. A selection
    /// that touches a passage the page was told nothing about is reported
    /// as `unnamed`, and is then asked about by its text instead — the
    /// record refuses the lot, with the reason, rather than quietly
    /// putting back the half it can.
    func reviewChangesForSelection(completion: @escaping (TipTapReviewSelection?) -> Void) {
        guard isReady else { return completion(nil) }
        evaluate(
            "window.editorAPI.reviewChangesForSelection ? window.editorAPI.reviewChangesForSelection() : null"
        ) { [weak self] result in
            guard let self, let body = result as? [String: Any] else { return completion(nil) }
            // One string, comma separated, as the page names a passage
            // everywhere else. Read as a list it was always empty, and
            // the menu's restore said nothing was selected.
            let ids: [String]
            if let named = body["ids"] as? String {
                ids = named.split(separator: ",").map(String.init)
            } else {
                ids = (body["ids"] as? [String]) ?? []
            }
            completion(TipTapReviewSelection(
                ids: ids,
                unnamed: body["unnamed"] as? Bool ?? false,
                isCaret: body["caret"] as? Bool ?? false,
                marked: (body["markdown"] as? String).map(self.portableMarkdown(from:)),
                pageText: (body["plain"] as? String).map(self.portableMarkdown(from:))
            ))
        }
    }

    /// Shows the next marked passage after the selection, or the one
    /// before it, wrapping at either end; false where there are none or
    /// the page is older than this.
    func goToReviewMark(forward: Bool, completion: ((Bool) -> Void)? = nil) {
        guard isReady else { return completion?(false) ?? () }
        evaluate(
            "window.editorAPI.goToReviewMark ? window.editorAPI.goToReviewMark(\(forward)) : false"
        ) { moved in
            completion?(moved as? Bool ?? false)
        }
    }

    /// The selection as the writing's Markdown with markers at its edges,
    /// for clearing what of the marks it covers; nil outside the visual
    /// page or before it is ready.
    func reviewMarkdownForSelection(completion: @escaping (TipTapReviewClear?) -> Void) {
        guard isReady else { return completion(nil) }
        evaluate("window.editorAPI.reviewMarkdownForSelection ? window.editorAPI.reviewMarkdownForSelection() : null") { [weak self] result in
            guard let self else { return completion(nil) }
            if let marked = result as? String {
                return completion(TipTapReviewClear(marked: self.portableMarkdown(from: marked), pageText: nil))
            }
            completion((result as? [String: Any]).flatMap(self.reviewClear(from:)))
        }
    }

    /// A clear as the page sends it: `markdown`, marked, and `plain`, the
    /// same document unmarked, both made portable as the page's reported
    /// text is. A page from before `plain` sends the marked text alone.
    private func reviewClear(from body: [String: Any]) -> TipTapReviewClear? {
        guard let marked = body["markdown"] as? String else { return nil }
        return TipTapReviewClear(
            marked: portableMarkdown(from: marked),
            pageText: (body["plain"] as? String).map(portableMarkdown(from:))
        )
    }

    func insertHorizontalRule() {
        guard isReady else { return }
        evaluate("window.editorAPI.insertHorizontalRule()")
    }

    func insertTable(rows: Int, columns: Int) {
        guard isReady else { return }
        evaluate("window.editorAPI.insertTable(\(rows), \(columns), true)")
    }

    func removeLink() {
        guard isReady else { return }
        evaluate("window.editorAPI.removeLink()")
    }

    func setMediaMap(_ map: [String: String]) {
        shownMediaMap = map
        guard isReady else {
            pendingMediaMap = map
            return
        }
        // Every host update calls this; only a real change is worth a round
        // trip into the page.
        guard appliedMediaMap != map else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8) else { return }
        appliedMediaMap = map
        evaluate("window.editorAPI.setMediaMap(\(json))")
    }

    /// Pages are pooled per kind of editor, and every editor of one kind says
    /// the same thing, so one without its own leaves the bundle's default.
    func setPlaceholder(_ text: String?) {
        guard let text else { return }
        shownPlaceholder = text
        guard isReady else {
            pendingPlaceholder = text
            return
        }
        evaluate("window.editorAPI.setPlaceholder(\(Self.javascriptString(text)))")
    }

    func setFootnoteClicks(_ behaviour: TipTapFootnoteClicks) {
        shownFootnoteClicks = behaviour
        guard isReady else {
            pendingFootnoteClicks = behaviour
            return
        }
        guard appliedFootnoteClicks != behaviour else { return }
        appliedFootnoteClicks = behaviour
        evaluate("window.editorAPI.setFootnoteClicks('\(behaviour.rawValue)')")
    }

    func setFontSize(_ size: Double) {
        shownFontSize = size
        guard isReady else {
            pendingFontSize = size
            return
        }
        guard appliedFontSize != size else { return }
        appliedFontSize = size
        evaluate("window.editorAPI.setFontSize(\(Int(size)))")
    }

    func setTheme(isDark: Bool) {
        shownTheme = isDark
        guard isReady else {
            pendingTheme = isDark
            return
        }
        // Every host update calls this; only a real change is worth a round trip
        // into the page.
        guard appliedTheme != isDark else { return }
        appliedTheme = isDark
        evaluate("window.editorAPI.setTheme(\(isDark))")
    }

    /// Paints the page the colour the surrounding window is painted, so the visual
    /// editor sits in the window rather than as a black rectangle inside it. The
    /// bundled stylesheet hardcodes pure black for its dark theme, which is far
    /// darker than any native surface beside it.
    ///
    /// Only needed when the appearance changes after load; the same style is
    /// already injected at document start so the first paint never flashes.
    func setBackgroundColor(_ cssColor: String) {
        shownBackgroundColor = cssColor
        guard isReady else {
            pendingBackgroundColor = cssColor
            return
        }
        guard appliedBackgroundColor != cssColor else { return }
        appliedBackgroundColor = cssColor
        evaluate("window.editorAPI.setBackgroundColor(\(Self.javascriptString(cssColor)))")
    }

    /// Sets the writing in the face the host reads it in. Only the writing
    /// page's own stylesheet (`writingPageStyleScript`) gives the class a
    /// meaning, so a compact note editor is never restyled by it.
    func setProseTypeface(_ typeface: ProseTypeface?) {
        shownProseTypeface = .some(typeface)
        guard isReady else {
            pendingProseTypeface = .some(typeface)
            return
        }
        guard appliedProseTypeface != .some(typeface) else { return }
        appliedProseTypeface = .some(typeface)
        evaluate("document.documentElement.classList.toggle('lamp-serif', \(typeface == .serif))")
    }

    /// The writing editor's page, set as a page rather than a form.
    ///
    /// The bundle is built for a phone: prose runs edge to edge inside a 16pt
    /// margin, which on a Mac window made lines of 150 characters. Here the
    /// text sits in a centred column of about 70 characters, with the leading
    /// and list spacing of the preview, so writing and reading look alike.
    /// The column is in `em`s, so it keeps its measure as the size changes.
    /// Every rule leads with `html`: this sheet goes in at document start,
    /// before the bundle's, which would otherwise win each tie.
    ///
    /// The editor's size setting is shared with the Markdown surface, which
    /// starts smaller because monospaced text reads larger; the visual page
    /// is scaled back up by that difference (15 → 17) so it opens at the
    /// size the writing is read at.
    static let writingPageStyleScript = """
    (function () {
      var style = document.createElement('style');
      style.id = 'lamp-writing-page';
      style.textContent = [
        'html #tiptap-editor { font-size: calc(var(--font-size) * 1.13); max-width: calc(35em + 112px);',
        '  margin: 0 auto; padding: 48px 56px 160px; }',
        'html.lamp-serif .tiptap { font-family: ui-serif, "New York", "Iowan Old Style", Georgia, serif; }',
        'body:not(.dark) { --text-color: #1f1f21 !important; }',
        'body.dark { --text-color: rgba(255, 255, 255, 0.88) !important; }',
        'html .tiptap p { line-height: 1.7; margin-bottom: 0.85em; }',
        'html .tiptap ul, html .tiptap ol { padding-left: 1.35em; margin-bottom: 0.9em; }',
        'html .tiptap li { line-height: 1.65; margin-bottom: 0.4em; padding-left: 0.15em; }',
        'html .tiptap li > ul, html .tiptap li > ol { margin-top: 0.4em; }',
        'html .tiptap li::marker { color: color-mix(in srgb, var(--text-color) 62%, transparent); }',
        'html .tiptap h1, html .tiptap h2, html .tiptap h3 { letter-spacing: -0.01em; }',
        'html .tiptap h1 { font-size: 1.95em; line-height: 1.2; margin-top: 1.3em; margin-bottom: 0.5em; }',
        'html .tiptap h2 { font-size: 1.5em; line-height: 1.25; margin-top: 1.3em; margin-bottom: 0.45em; }',
        'html .tiptap h3 { font-size: 1.22em; margin-top: 1.15em; }',
        'html .tiptap > :first-child { margin-top: 0; }',
        'html .tiptap blockquote { padding: 10px 16px; border-left-width: 3px; }',
        // What the writing assistant changed that the writer has not yet
        // read (the bundle's review-marks.js): a wash and a dotted rule,
        // a check in the margin to clear a paragraph, none while presenting.
        'html .review-mark { background: rgba(232, 176, 44, 0.22); border-bottom: 1px dotted rgba(178, 120, 0, 0.7); }',
        'html .review-point { display: inline-block; width: 0; height: 1.1em; vertical-align: text-bottom; border-left: 2px solid rgba(178, 120, 0, 0.7); margin: 0 1px; }',
        // In a block of text, inline at its first line's start, and taking
        // no room in the line: no width, its margins giving back what its
        // box takes (the ✓ alone, -30 + 22 + 8; with the ↺ beside it,
        // -56 + 22 + 4 and 0 + 22 + 8), and no height, so a line shorter
        // than the circle (small type, a note's) keeps its height, and the
        // first line is laid out as it is once the marks are cleared.
        // Inline so that `vertical-align: middle` sets it on the middle of
        // the line's lower-case letters: centred on the line's box instead,
        // in a serif whose letters sit low in their line, the buttons rode
        // high of the words. The circle and its glyph are drawn about that
        // point by the `::before`, which the button's clicks include.
        'html .ProseMirror .review-clear, html .ProseMirror .review-restore { display: inline-block; position: relative; vertical-align: middle; width: 22px; height: 0; padding: 0; border: none; background: transparent; color: rgba(178, 120, 0, 0.8); font: inherit; cursor: pointer; user-select: none; }',
        'html .ProseMirror .review-clear { margin: 0 8px 0 -30px; }',
        'html .ProseMirror .review-restore { margin: 0 8px 0 0; }',
        // With a ↺ beside it, which is shown only while editing, further out.
        'html body.mode-edit .ProseMirror .review-clear:has(~ .review-restore) { margin: 0 4px 0 -56px; }',
        // In the system's face whatever the writing's is, so each glyph sits
        // the same in its circle in serif and sans alike; lifted two points
        // by the padding, where its ink stands at the middle of the line's
        // lower-case letters rather than low of it (measured in both faces).
        'html .ProseMirror .review-clear::before, html .ProseMirror .review-restore::before { position: absolute; left: 0; top: -11px; box-sizing: border-box; width: 22px; height: 22px; padding-bottom: 4px; display: flex; align-items: center; justify-content: center; border-radius: 11px; font: 14px/1 -apple-system, system-ui, sans-serif; }',
        'html .ProseMirror .review-clear::before { content: "\\u2713"; }',
        'html .ProseMirror .review-clear:hover::before, html .ProseMirror .review-restore:hover::before { background: rgba(232, 176, 44, 0.22); }',
        // A list item's buttons sit past its bullet, not on it: the list's
        // indent (1.35em) and the item's (0.15em) further into the margin,
        // in the item's own em, taken where the item is and handed down
        // as a length: in the button's em, a heading in the item, its
        // type twice the size, moved them off the window's edge. Still
        // taking no width: what goes out on the left comes back on the
        // right.
        '@property --lamp-review-item-em { syntax: "<length>"; inherits: true; initial-value: 0px; }',
        'html .tiptap li { --lamp-review-item-em: 1em; }',
        'html .ProseMirror li .review-clear { margin-left: calc(-30px - 1.5 * var(--lamp-review-item-em)); margin-right: calc(8px + 1.5 * var(--lamp-review-item-em)); }',
        'html body.mode-edit .ProseMirror li .review-clear:has(~ .review-restore) { margin-left: calc(-56px - 1.5 * var(--lamp-review-item-em)); margin-right: 4px; }',
        'html .ProseMirror li .review-restore { margin-right: calc(8px + 1.5 * var(--lamp-review-item-em)); }',
        // Beside a rule, a picture or an audio block, which has no line to
        // stand in, at the top of the page or in a quote, a list item or a
        // cell: out of the flow there, where the block starts, or inline
        // they took a line of their own above it, which went when they did.
        // Centred on the first line's box.
        'html body :is(.ProseMirror, blockquote, li, td, th) > .review-clear, html body :is(.ProseMirror, blockquote, li, td, th) > .review-restore { position: absolute; float: none; height: 0; margin: calc(1lh / 2) 0 0 -30px; }',
        'html body.mode-edit :is(.ProseMirror, blockquote, li, td, th) > .review-clear:has(~ .review-restore) { margin: calc(1lh / 2) 0 0 -56px; }',
        'html body li > .review-clear, html body li > .review-restore { margin-left: calc(-30px - 1.5 * var(--lamp-review-item-em)); }',
        'html body.mode-edit li > .review-clear:has(~ .review-restore) { margin-left: calc(-56px - 1.5 * var(--lamp-review-item-em)); }',
        // A table's cell has no margin of its own to hold them, so there
        // they go at the right of its first line, as the phone has them,
        // and its words wrap a little sooner: in the margin, a cell's
        // buttons sat over the cell before it. A float needs its height for
        // the words to wrap round it, so here the circle is the box.
        'html .ProseMirror :is(td, th) .review-clear, html .ProseMirror :is(td, th) .review-restore { float: right; height: 22px; margin: calc((1lh - 22px) / 2) 0 0 4px; }',
        'html body.mode-edit .ProseMirror :is(td, th) .review-clear:has(~ .review-restore) { margin: calc((1lh - 22px) / 2) 0 0 4px; }',
        'html .ProseMirror :is(td, th) .review-clear::before, html .ProseMirror :is(td, th) .review-restore::before { top: 0; }',
        // A rule, an image or an audio block the assistant changed, which has
        // no words to wash: the block itself.
        'html .review-mark-block { background: rgba(232, 176, 44, 0.22); outline: 1px dotted rgba(178, 120, 0, 0.7); outline-offset: 4px; }',
        'html body.dark .review-mark-block { background: rgba(240, 190, 70, 0.2); outline-color: rgba(240, 190, 70, 0.75); }',
        'html body.mode-present .review-mark-block { background: none; outline: none; }',
        'html body.dark .review-mark { background: rgba(240, 190, 70, 0.2); border-bottom-color: rgba(240, 190, 70, 0.75); }',
        'html body.dark .review-point { border-left-color: rgba(240, 190, 70, 0.75); }',
        'html body.dark .ProseMirror .review-clear { color: rgba(240, 190, 70, 0.85); }',
        // Putting the assistant's wording back: a ↺ beside the ✓, the
        // passage it would change shown stronger while its offer is open,
        // and what it would do written out — for a passage the assistant
        // only took words out of, that is the one way to see it.
        // Its glyph; drawn as the tick's is, above.
        'html .ProseMirror .review-restore::before { content: "\\u21BA"; }',
        'html .review-mark.review-current { background: rgba(232, 176, 44, 0.42); border-bottom-style: solid; }',
        'html .review-point.review-current { border-left-width: 3px; box-shadow: 0 0 0 2px rgba(232, 176, 44, 0.35); }',
        // Placed by the page, which measures it and sets left and top
        // against the document: absolute, and no transform or padding on
        // anything it hangs from, or it lands somewhere else.
        'html .review-popover { position: absolute; z-index: 20; max-width: 22em; padding: 10px 12px; border: 1px solid rgba(0, 0, 0, 0.14); border-radius: 10px; background: #FFFFFF; box-shadow: 0 6px 22px rgba(0, 0, 0, 0.18); font-size: 0.86em; line-height: 1.45; overflow-y: auto; }',
        'html .review-popover-item + .review-popover-item { margin-top: 10px; padding-top: 10px; border-top: 1px solid rgba(0, 0, 0, 0.09); }',
        'html .review-popover-label { font-size: 0.82em; letter-spacing: 0.04em; text-transform: uppercase; color: rgba(0, 0, 0, 0.5); }',
        // The two sides hold real blocks — the previewed paragraphs, list
        // items and quotations, serialised — so they are flattened to read
        // as lines of a panel rather than as a document inside one.
        'html .review-popover-text > * { margin: 0; font-size: inherit; line-height: inherit; padding-left: 0; border: none; }',
        'html .review-popover-text > * + * { margin-top: 0.4em; }',
        'html .review-popover-text.is-marked:not(.is-empty) > * { background: rgba(232, 176, 44, 0.22); }',
        'html .review-popover-text.is-empty, html .review-popover-reason { font-style: italic; color: rgba(0, 0, 0, 0.55); }',
        'html .review-popover-restore { margin-top: 8px; padding: 4px 12px; border: none; border-radius: 12px; background: rgba(232, 176, 44, 0.3); color: inherit; font: inherit; font-size: 0.95em; cursor: pointer; }',
        'html .review-popover-restore:hover { background: rgba(232, 176, 44, 0.45); }',
        'html body.dark .ProseMirror .review-restore { color: rgba(240, 190, 70, 0.85); }',
        'html body.dark .review-mark.review-current { background: rgba(240, 190, 70, 0.38); }',
        'html body.dark .review-popover { border-color: rgba(255, 255, 255, 0.16); background: #2A2A2C; box-shadow: 0 6px 22px rgba(0, 0, 0, 0.5); }',
        'html body.dark .review-popover-item + .review-popover-item { border-top-color: rgba(255, 255, 255, 0.12); }',
        'html body.dark .review-popover-label { color: rgba(255, 255, 255, 0.55); }',
        'html body.dark .review-popover-text.is-marked:not(.is-empty) > * { background: rgba(240, 190, 70, 0.2); }',
        'html body.dark .review-point.review-current { box-shadow: 0 0 0 2px rgba(240, 190, 70, 0.3); }',
        'html body.dark .review-popover-text.is-empty, html body.dark .review-popover-reason { color: rgba(255, 255, 255, 0.6); }',
        'html body.dark .review-popover-restore { background: rgba(240, 190, 70, 0.26); }',
        'html body.dark .review-popover-restore:hover { background: rgba(240, 190, 70, 0.4); }',
        'html body.mode-present .review-mark { background: none; border-bottom: none; }',
        'html body.mode-present .review-mark.review-current { background: none; }',
        'html body.mode-present .review-point, html body.mode-present .review-clear { display: none; }',
        // Read mode saves nothing, so nothing there may change the writing.
        'html body.mode-present .review-restore, html body:not(.mode-edit) .review-restore { display: none; }',
        'html body.mode-present .review-popover, html body:not(.mode-edit) .review-popover { display: none; }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Overrides the stylesheet's `--bg-color` from a `<style>` element the host
    /// owns, at document start, before the bundle's own `setBackgroundColor` can
    /// run. It writes the same element. `!important` is what lets one rule
    /// survive the theme class being toggled underneath it.
    static func backgroundStyleScript(cssColor: String) -> String {
        """
        (function () {
          var id = 'lamp-host-background';
          var style = document.getElementById(id);
          if (!style) {
            style = document.createElement('style');
            style.id = id;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent =
            'body, body.dark { --bg-color: \(cssColor) !important; }';
        })();
        """
    }

    /// Reports the first frame the page actually produces.
    ///
    /// Two nested animation frames is the reliable "we have painted" signal: the
    /// first is scheduled before the upcoming paint, the second runs after it.
    /// Waiting for the document to parse first means that paint includes the
    /// styled background rather than an empty viewport.
    static let firstPaintScript = """
    (function () {
      function signalPainted() {
        requestAnimationFrame(function () {
          requestAnimationFrame(function () {
            try {
              window.webkit.messageHandlers.tiptapBridge.postMessage({
                type: 'painted'
              });
            } catch (error) {}
          });
        });
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', signalPainted);
      } else {
        signalPainted();
      }
    })();
    """

    private func editorMarkdown(from portableMarkdown: String) -> String {
        LampPortableDevotionalMedia.editorMarkdown(from: portableMarkdown)
    }

    private func portableMarkdown(from editorMarkdown: String) -> String {
        LampPortableDevotionalMedia.portableMarkdown(
            from: editorMarkdown,
            devotionalID: mediaScopeID,
            richMediaIDs: richMediaIDs
        )
    }

    /// Runs `script` in the page. Without a page there is no result, and the
    /// completion is still called, with none: a caller waiting on an answer
    /// must always get one.
    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        guard let webView else {
            completion?(nil)
            return
        }
        webView.evaluateJavaScript(script) { result, error in
            if let error {
                NSLog("TipTap JavaScript error: %@", error.localizedDescription)
            }
            completion?(result)
        }
    }

    private static func javascriptString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let result = String(data: data, encoding: .utf8) else { return "\"\"" }
        return result
    }

    /// The page's `{ count, current }`. Anything else, such as a script that
    /// failed, finds nothing.
    fileprivate static func findStatus(from result: Any?) -> WritingFindStatus {
        guard let result = result as? [String: Any] else { return .noMatches }
        return WritingFindStatus(
            count: (result["count"] as? Int) ?? 0,
            current: (result["current"] as? Int) ?? 0
        )
    }
}

/// The bundle searches the document as it is shown, a block at a time, so
/// what the find bar finds in the visual editor is the text a reader sees.
extension TipTapEditorCoordinator {
    /// Shows the writing as `mode` does.
    ///
    /// The page has had this all along — our bundle is the phone's build,
    /// and the phone has read a writing in the page since it had modes. The
    /// Mac simply never called it, and drew a reader of its own instead.
    func setViewMode(_ mode: TipTapViewMode) {
        guard viewMode != mode else { return }
        viewMode = mode
        guard isReady else { return }
        applyViewMode()
    }

    fileprivate func applyViewMode() {
        evaluate("window.editorAPI.setMode(\"\(viewMode.rawValue)\")")
        // The page leaves 200 points above a writing it is reading, for the
        // phone, where a floating header lies over the page. Here the
        // writing's own header is a band above it with a rule under it, so
        // that much space read as the page having failed to draw.
        let top = viewMode == .read ? 24 : 0
        evaluate(
            "document.documentElement.style.setProperty('--read-top-padding', '\(top)px')"
        )
        // Going into read takes the marks off, and coming out puts back
        // whatever this page was holding.
        applyReviewMarks()
    }
}

/// What the page shows a writing as.
enum TipTapViewMode: String {
    /// Read-only, as the writing reads.
    case read
    /// Written in.
    case edit
    /// Shown to a room.
    case present
}

extension TipTapEditorCoordinator: WritingReplaceTarget {
    /// The page refuses to replace unless it is editable, which it is only
    /// in `edit`. Said here so the find bar does not draw a Replace field
    /// that would do nothing.
    var canReplaceNow: Bool { viewMode == .edit }

    func setSearch(
        _ query: String,
        options: WritingFindOptions,
        completion: @escaping (WritingFindStatus) -> Void
    ) {
        guard isReady else { return completion(.noMatches) }
        let options = "{ caseSensitive: \(options.matchesCase), wholeWord: \(options.wholeWords) }"
        evaluate("window.editorAPI.setSearch(\(Self.javascriptString(query)), \(options))") {
            completion(Self.findStatus(from: $0))
        }
    }

    func findNext(completion: @escaping (WritingFindStatus) -> Void) {
        guard isReady else { return completion(.noMatches) }
        evaluate("window.editorAPI.findNext()") { completion(Self.findStatus(from: $0)) }
    }

    func findPrevious(completion: @escaping (WritingFindStatus) -> Void) {
        guard isReady else { return completion(.noMatches) }
        evaluate("window.editorAPI.findPrevious()") { completion(Self.findStatus(from: $0)) }
    }

    func replaceCurrent(with replacement: String, completion: @escaping (WritingFindStatus) -> Void) {
        guard isReady else { return completion(.noMatches) }
        evaluate("window.editorAPI.replaceCurrent(\(Self.javascriptString(replacement)))") {
            completion(Self.findStatus(from: $0))
        }
    }

    func replaceAll(with replacement: String, completion: @escaping (Int) -> Void) {
        guard isReady else { return completion(0) }
        evaluate("window.editorAPI.replaceAll(\(Self.javascriptString(replacement)))") {
            completion(($0 as? Int) ?? 0)
        }
    }

    func endSearch(selectingCurrent: Bool) {
        guard isReady else { return }
        if selectingCurrent, let webView {
            webView.window?.makeFirstResponder(webView)
            evaluate("window.editorAPI.selectCurrentMatch(); window.editorAPI.clearSearch()")
        } else {
            evaluate("window.editorAPI.clearSearch()")
        }
    }
}

/// One loaded editor page, kept apart from the view showing it, so a pool can
/// hand it from one note to the next instead of making a web view each time.
///
/// It receives the page's messages and navigation and passes them to whichever
/// coordinator holds it now, and remembers what the page has already said —
/// ready, painted, finished loading — for a coordinator that takes it later.
final class TipTapEditorPage: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let webView: WKWebView
    let key: TipTapEditorPool.Key
    weak var owner: TipTapEditorCoordinator?
    private(set) var isReady = false
    private(set) var hasPainted = false
    private(set) var hasFinishedLoading = false
    /// Whether the bundle can replace its document with a fresh undo history,
    /// which giving the page to another document needs.
    private(set) var canLoad = false
    /// Set once a load in this page failed or its process died; such a page is
    /// never handed to another document.
    private(set) var isUnfitForReuse = false

    init(webView: WKWebView, key: TipTapEditorPool.Key) {
        self.webView = webView
        self.key = key
    }

    func markUnfitForReuse() { isUnfitForReuse = true }

    func prepareForReload() {
        isReady = false
        hasPainted = false
        hasFinishedLoading = false
    }

    /// Breaks the cycle the content controller's handler makes with this page.
    func tearDown() {
        owner = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tiptapBridge")
        webView.navigationDelegate = nil
        webView.stopLoading()
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let body = message.body as? [String: Any], let type = body["type"] as? String {
            switch type {
            case "ready":
                isReady = true
                webView.evaluateJavaScript("typeof window.editorAPI.load === 'function'") { [weak self] result, _ in
                    self?.canLoad = (result as? Bool) == true
                }
            case "painted":
                hasPainted = true
            default:
                break
            }
        }
        owner?.userContentController(userContentController, didReceive: message)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        hasFinishedLoading = true
        owner?.webView(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        hasFinishedLoading = true
        owner?.webView(webView, didFail: navigation, withError: error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        hasFinishedLoading = true
        owner?.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isUnfitForReuse = true
        owner?.webViewWebContentProcessDidTerminate(webView)
    }
}

/// Editor pages kept loaded and ready, so opening a note or switching to the
/// next one does not wait for a web view.
///
/// Measured on a Mac: a new editor page is ready in 60–76 ms, 314 ms for the
/// first in a launch, and holds about 48 MB; giving a loaded page new text
/// takes about a millisecond. So one page is kept warm for each kind of editor
/// that has asked to be, and the page a closed editor gives back is kept in
/// its place when the bundle can start it on a fresh undo history.
@MainActor
final class TipTapEditorPool {
    static let shared = TipTapEditorPool()

    struct Key: Hashable {
        let libraryRootURL: URL
        let compact: Bool
        /// Whether Writing Tools are offered, which a web view takes at its
        /// making: a spare made under the other setting is never handed out.
        var writingTools = AIFeatures.isEnabledNow
    }

    private var spares: [Key: TipTapEditorPage] = [:]
    /// Kinds of editor someone asked to have warm, so the pool replaces the
    /// spare each time one is taken.
    private var warmKeys: Set<Key> = []

    /// Starts a page loading for this kind of editor, if none is waiting, so
    /// the next one opened is ready at once. Deferred to the next turn of the
    /// run loop: it is never worth delaying what is being drawn now.
    func prewarm(libraryRootURL: URL, compact: Bool) {
        let key = Key(libraryRootURL: libraryRootURL, compact: compact)
        warmKeys.insert(key)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.spares[key] == nil else { return }
            self.spares[key] = self.makePage(for: key)
        }
    }

    /// A page for one editor: the one waiting, or a new one loading.
    func page(libraryRootURL: URL, compact: Bool) -> TipTapEditorPage {
        let key = Key(libraryRootURL: libraryRootURL, compact: compact)
        let page = spares.removeValue(forKey: key) ?? makePage(for: key)
        if warmKeys.contains(key) { prewarm(libraryRootURL: libraryRootURL, compact: compact) }
        return page
    }

    /// Takes back a page its editor no longer shows. Kept only when the bundle
    /// can give it the next document on a fresh undo history and nothing is
    /// waiting already; emptied first, so no note's text sits in a spare, and
    /// its search ended, since a search lasts from one document to the next.
    func giveBack(_ page: TipTapEditorPage) {
        page.owner = nil
        guard page.canLoad, page.isReady, !page.isUnfitForReuse, spares[page.key] == nil else {
            page.tearDown()
            return
        }
        page.webView.evaluateJavaScript("window.editorAPI.clearSearch?.(); window.editorAPI.load('')")
        spares[page.key] = page
    }

    private func makePage(for key: Key) -> TipTapEditorPage {
        let configuration = WKWebViewConfiguration()
        // The system's Writing Tools only while AI features are on.
        configuration.writingToolsBehavior = key.writingTools ? .default : .none
        // The page's own stylesheet paints pure black before any host message can
        // reach it, which reads as a flash of black as the editor opens. Injecting
        // the host colour at document start means the very first paint is already
        // the right one — waiting for `ready` is far too late.
        let initialBackground = TipTapEditorView.webViewCanBeTransparent
            ? "transparent"
            : TipTapEditorView.cssColor(
                for: .windowBackgroundColor,
                in: NSApp?.effectiveAppearance ?? .currentDrawing()
            )
        configuration.userContentController.addUserScript(WKUserScript(
            source: TipTapEditorCoordinator.backgroundStyleScript(cssColor: initialBackground),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        if !key.compact {
            // The writing editor is the only full-pane host; a note's compact
            // editor keeps the bundle's own layout.
            configuration.userContentController.addUserScript(WKUserScript(
                source: TipTapEditorCoordinator.writingPageStyleScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: TipTapEditorCoordinator.firstPaintScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let page = TipTapEditorPage(webView: webView, key: key)
        configuration.userContentController.add(page, name: "tiptapBridge")
        webView.navigationDelegate = page
        webView.allowsBackForwardNavigationGestures = false
        // A web view is opaque white until its first paint, and no amount of page
        // styling reaches that frame — the page has not started drawing yet. Stay
        // hidden until there is something to show; the host's own background sits
        // behind and is already the right colour.
        webView.isHidden = true
        webView.underPageBackgroundColor = .windowBackgroundColor

        do {
            let editorURL = try TipTapEditorView.cachedEditorURL(in: key.libraryRootURL)
            webView.loadFileURL(editorURL, allowingReadAccessTo: key.libraryRootURL)
        } catch {
            page.markUnfitForReuse()
            let message = error.localizedDescription
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            webView.loadHTMLString(
                "<body style='font: 14px -apple-system; padding: 24px'>Visual editor unavailable.<br><small>\(message)</small></body>",
                baseURL: nil
            )
        }
        return page
    }
}

/// A review clear from the visual editor's page: the writing's Markdown
/// with markers round what to clear, and the page's Markdown of the same
/// document without them, which is the text it was made in. Nil from a
/// page that does not send it.
/// What the page did with a restore: made it, and what it holds now;
/// would not, because what it is showing is not what the restore was
/// worked out in; or does not know how, being older than that API.
enum TipTapRestore: Sendable {
    case done(String)
    case refused
    case unsupported
}

/// What the page's selection stands in: the ids of the passages it
/// touches, whether it also touches one the page was told nothing about,
/// whether it is a caret rather than a selection, and its text.
struct TipTapReviewSelection: Sendable {
    let ids: [String]
    let unnamed: Bool
    let isCaret: Bool
    let marked: String?
    let pageText: String?
}

/// Passages the page asks to be put back, named by the id it was given
/// with the marks, and its own text to work them out in.
struct TipTapReviewRestore: Sendable {
    let id: String
    let pageText: String?
}

struct TipTapReviewClear: Sendable {
    let marked: String
    let pageText: String?
}
