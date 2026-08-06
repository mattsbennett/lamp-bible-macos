import Foundation
import SwiftUI
import WebKit

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
    let libraryRootURL: URL
    let isVisible: Bool
    /// Sizes the page to its content instead of the viewport, for hosts that
    /// place the editor inside their own scrolling column rather than giving it
    /// a pane of its own. See `TipTapEditorCoordinator.applyCompactLayout`.
    var compactLayout = false
    var onCoordinatorReady: (TipTapEditorCoordinator) -> Void

    func makeCoordinator() -> TipTapEditorCoordinator {
        TipTapEditorCoordinator(mediaScopeID: mediaScopeID)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let coordinator = context.coordinator

        configuration.userContentController.add(coordinator, name: "tiptapBridge")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        webView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        webView.isHidden = !isVisible

        coordinator.webView = webView
        coordinator.updateMediaScopeID(mediaScopeID)
        coordinator.onContentChanged = bindingUpdater
        coordinator.usesCompactLayout = compactLayout
        coordinator.setMediaMap(mediaMap)
        coordinator.setContent(markdownContent)
        coordinator.setFontSize(fontSize)
        coordinator.setTheme(isDark: context.environment.colorScheme == .dark)
        coordinator.onReady = { onCoordinatorReady(coordinator) }

        do {
            let editorURL = try Self.cachedEditorURL(in: libraryRootURL)
            webView.loadFileURL(editorURL, allowingReadAccessTo: libraryRootURL)
        } catch {
            let message = error.localizedDescription
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            webView.loadHTMLString(
                "<body style='font: 14px -apple-system; padding: 24px'>Visual editor unavailable.<br><small>\(message)</small></body>",
                baseURL: nil
            )
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let shouldHide = !isVisible
        if webView.isHidden != shouldHide {
            webView.isHidden = shouldHide
        }
        let coordinator = context.coordinator
        coordinator.updateMediaScopeID(mediaScopeID)
        coordinator.onContentChanged = bindingUpdater
        coordinator.setMediaMap(mediaMap)
        coordinator.setFontSize(fontSize)
        coordinator.setTheme(isDark: context.environment.colorScheme == .dark)

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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tiptapBridge")
        webView.navigationDelegate = nil
        coordinator.webView = nil
    }

    private var bindingUpdater: (String) -> Void {
        let binding = $markdownContent
        return { markdown in
            DispatchQueue.main.async {
                binding.wrappedValue = markdown
            }
        }
    }

    private var mediaMap: [String: String] {
        let directory = libraryRootURL
            .appendingPathComponent("Media/Devotionals", isDirectory: true)
            .appendingPathComponent(mediaScopeID, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, $0.absoluteString) })
    }

    /// WKWebView grants local-file access relative to the loaded document. Cache
    /// the bundled single-file editor under the library root so it can also render
    /// devotional media without granting access to unrelated folders.
    private static func cachedEditorURL(in libraryRootURL: URL) throws -> URL {
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

    var onContentChanged: ((String) -> Void)?
    var onSelectionChanged: ((TipTapSelectionState) -> Void)?
    var onReady: (() -> Void)?
    /// Reported by the compact layout only, so a host that lets the editor grow
    /// can size it to its text.
    var onContentHeightChanged: ((Double) -> Void)?
    /// The web view is opaque to `@FocusState`, so caret focus is reported out.
    var onFocusChanged: ((Bool) -> Void)?
    var usesCompactLayout = false

    private(set) var lastKnownMarkdown = ""
    private var mediaScopeID: String
    private var isReady = false
    private var pendingContent: String?
    private var pendingMediaMap: [String: String]?
    private var pendingFontSize: Double?
    private var pendingTheme: Bool?

    init(mediaScopeID: String) {
        self.mediaScopeID = mediaScopeID
    }

    func updateMediaScopeID(_ mediaScopeID: String) {
        self.mediaScopeID = mediaScopeID
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        switch type {
        case "ready":
            isReady = true
            if usesCompactLayout { applyCompactLayout() }
            if let mediaMap = pendingMediaMap {
                pendingMediaMap = nil
                setMediaMap(mediaMap)
            }
            if let content = pendingContent {
                pendingContent = nil
                setContent(content)
            }
            if let fontSize = pendingFontSize {
                pendingFontSize = nil
                setFontSize(fontSize)
            }
            if let isDark = pendingTheme {
                pendingTheme = nil
                setTheme(isDark: isDark)
            }
            onReady?()

        case "contentChanged":
            guard let editorMarkdown = body["markdown"] as? String else { return }
            let markdown = portableMarkdown(from: editorMarkdown)
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

        default:
            break
        }
    }

    /// Frees the page from viewport-sized layout so the editor is exactly as tall
    /// as what has been written, then reports that height and caret focus back.
    ///
    /// The bundle sizes itself for a full pane — `100vh` minimums and a deep
    /// bottom padding for the on-screen keyboard — which inside a host's own
    /// scrolling column would leave an empty webview swallowing scroll events.
    private func applyCompactLayout() {
        evaluate("""
            (function () {
                if (window.__lampCompactLayout) { return; }
                window.__lampCompactLayout = true;
                var root = document.getElementById('tiptap-editor');
                if (!root) { return; }
                root.style.setProperty('min-height', '0', 'important');
                root.style.setProperty('padding', '10px 12px', 'important');
                document.documentElement.style.height = 'auto';
                document.body.style.height = 'auto';
                var post = function (type, payload) {
                    try {
                        window.webkit.messageHandlers.tiptapBridge.postMessage(
                            Object.assign({ type: type }, payload)
                        );
                    } catch (error) {}
                };
                var content = root.querySelector('.tiptap');
                if (content) {
                    content.style.setProperty('min-height', '0', 'important');
                }
                var measure = function () {
                    // Measured to the document top, so any margin above the editor
                    // is counted rather than clipped.
                    var bottom = root.getBoundingClientRect().bottom + window.scrollY;
                    post('contentHeight', { height: Math.ceil(bottom) });
                };
                new ResizeObserver(measure).observe(root);
                document.addEventListener('focusin', function () {
                    post('focusChanged', { focused: true });
                });
                document.addEventListener('focusout', function () {
                    post('focusChanged', { focused: false });
                });
                measure();
            })();
            """)
    }

    func setContent(_ markdown: String) {
        lastKnownMarkdown = markdown
        guard isReady else {
            pendingContent = markdown
            return
        }
        evaluate("window.editorAPI.setContent(\(Self.javascriptString(editorMarkdown(from: markdown))))")
    }

    func getContent(completion: @escaping (String) -> Void) {
        guard webView != nil else {
            completion(lastKnownMarkdown)
            return
        }
        evaluate("window.editorAPI.getContent()") { [weak self] result in
            guard let self else {
                completion("")
                return
            }
            let markdown = self.portableMarkdown(from: result as? String ?? "")
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
        guard isReady else {
            pendingMediaMap = map
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: map),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("window.editorAPI.setMediaMap(\(json))")
    }

    func setFontSize(_ size: Double) {
        guard isReady else {
            pendingFontSize = size
            return
        }
        evaluate("window.editorAPI.setFontSize(\(Int(size)))")
    }

    func setTheme(isDark: Bool) {
        guard isReady else {
            pendingTheme = isDark
            return
        }
        evaluate("window.editorAPI.setTheme(\(isDark))")
    }

    private func editorMarkdown(from portableMarkdown: String) -> String {
        portableMarkdown.replacingOccurrences(
            of: #"lamp-media://[^/)\s]+/"#,
            with: "media/",
            options: .regularExpression
        )
    }

    private func portableMarkdown(from editorMarkdown: String) -> String {
        editorMarkdown.replacingOccurrences(
            of: "](media/",
            with: "](lamp-media://\(mediaScopeID)/"
        )
    }

    private func evaluate(_ script: String, completion: ((Any?) -> Void)? = nil) {
        webView?.evaluateJavaScript(script) { result, error in
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
}
