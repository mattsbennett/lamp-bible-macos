import AppKit
import AVFoundation
import VideoToolbox
import CryptoKit
import Foundation
import LampCore
import WebKit

/// Turns an agent's animation, an HTML page drawing a scene with three.js,
/// into a looping video and its still, for a picture's `video` on a slide.
///
/// The page is drawn offline, a frame at a time, by a clock Lamp holds: it
/// sets `window.lamp = { duration, render(t) }`, and Lamp calls `render` for
/// each frame's time and keeps what it drew. So a frame is never dropped or
/// late, and the same page makes the same video on any Mac. Nothing of the
/// agent's runs while a deck is presented: the room sees a video.
///
/// The page can read only the files in its own folder and Lamp's copy of
/// three.js, which it imports as `three`. Every other address, on the
/// network or on disk, is refused, so a page never depends on a CDN or a
/// file elsewhere and draws the same each time. That is for the video's
/// sake, not a wall against the page's author: the agent that writes a page
/// can reach the network itself, so a browser feature that slipped past these
/// rules would give it nothing it lacks.
@MainActor
public enum LampAnimationRenderer {
    public struct Options: Sendable {
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        /// The loop's length when the page does not give one.
        public var duration: Double?
        /// Names the video and still after what was drawn, `name-1a2b3c4d`,
        /// so a changed animation arrives under new names: Lamp brings a
        /// deck's files in when the deck changes, and a deck naming the same
        /// files as before would keep the old video.
        public var fingerprintsNames: Bool

        public init(
            width: Int = 1_920,
            height: Int = 1_080,
            framesPerSecond: Int = 30,
            duration: Double? = nil,
            fingerprintsNames: Bool = false
        ) {
            self.fingerprintsNames = fingerprintsNames
            self.width = width
            self.height = height
            self.framesPerSecond = framesPerSecond
            self.duration = duration
        }
    }

    public struct Result: Sendable {
        public var videoURL: URL
        public var stillURL: URL
        public var duration: Double
        public var frameCount: Int
        public var videoBytes: Int64
        /// A few frames across the loop, as JPEG, for whoever made the page
        /// to look at: the first, and three more evenly through.
        public var samples: [(seconds: Double, jpeg: Data)]
    }

    public enum RenderError: LocalizedError, Equatable {
        case notAPage(String)
        case outsideFolder(String)
        case noScene(String)
        case badDuration(Double)
        case badSize(Int, Int)
        case script(String)
        case frameTimedOut(Double)
        case tooLarge(Int64)
        case writer(String)
        case busy(String)
        case timedOut(String)
        case offlineRulesUnavailable
        case outputMoved

        public var errorDescription: String? {
            switch self {
            case .notAPage(let path): "No HTML page at \(path)."
            case .outsideFolder(let path): "\(path) is outside the folder Lamp may write in."
            case .noScene(let detail):
                "The page never set window.lamp = { duration, render(t) }\(detail.isEmpty ? "" : ": \(detail)")."
            case .badDuration(let seconds):
                "A loop runs from 1 to \(Int(longestDuration)) seconds; this one asks for \(seconds)."
            case .badSize(let width, let height):
                "Width and height run from 128 to 3840 pixels, and even; asked for \(width) × \(height)."
            case .script(let message): "The page's script failed: \(message)"
            case .frameTimedOut(let seconds):
                "render(\(seconds)) took longer than \(Int(frameTimeout)) seconds; keep each frame quick to draw."
            case .tooLarge(let bytes):
                "The video came to \(ByteCountFormatter().string(fromByteCount: bytes)), over Lamp's "
                    + "\(ByteCountFormatter().string(fromByteCount: LampPresentationVideo.largestFileBytes)) "
                    + "for a deck's video. Make the loop shorter or smaller."
            case .writer(let message): "The video could not be written: \(message)"
            case .busy(let name): "\(name) is already being rendered; wait for that to finish."
            case .timedOut(let step): "The page took too long \(step)."
            case .offlineRulesUnavailable:
                "Lamp could not set up the rules that keep the page offline, so it was not drawn."
            case .outputMoved: "The folder the page was in moved while it was drawn, so nothing was written."
            }
        }
    }

    nonisolated public static let longestDuration = 20.0
    nonisolated static let frameTimeout = 10.0
    nonisolated static let readyTimeout = 15.0
    /// The largest file a page may read from its folder: a model or texture,
    /// not anything that would fill the helper's memory.
    nonisolated static let largestPageFile = 64 * 1_024 * 1_024
    /// Pages being drawn, by the video they write, so two calls for one page
    /// cannot write over each other.
    private static var rendering: Set<String> = []
    /// The address the page and its files are served from.
    nonisolated static let scheme = "lamp-scene"
    nonisolated static let threePath = "/lamp/three.module.min.js"

    /// Renders `page` to `videoURL` and its first frame to `stillURL`.
    ///
    /// `three` is Lamp's copy of three.js's module build.
    public static func render(
        page: URL,
        three: URL,
        videoURL: URL,
        stillURL: URL,
        options: Options = Options()
    ) async throws -> Result {
        guard page.pathExtension.lowercased() == "html" || page.pathExtension.lowercased() == "htm",
              FileManager.default.fileExists(atPath: page.path)
        else { throw RenderError.notAPage(page.lastPathComponent) }
        guard (128...3_840).contains(options.width), (128...3_840).contains(options.height),
              options.width % 2 == 0, options.height % 2 == 0
        else { throw RenderError.badSize(options.width, options.height) }
        let framesPerSecond = min(max(options.framesPerSecond, 12), 60)

        let key = videoURL.standardizedFileURL.path
        guard rendering.insert(key).inserted else { throw RenderError.busy(page.lastPathComponent) }
        defer { rendering.remove(key) }
        // Written somewhere of Lamp's own and moved beside the page only when
        // whole, so a failed or abandoned render leaves nothing there, and
        // nothing is written through a folder swapped for a link meanwhile.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-animation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let finalVideo = videoURL
        let finalStill = stillURL
        let videoURL = scratch.appendingPathComponent("video.mp4")
        let stillURL = scratch.appendingPathComponent("still.jpg")

        let folder = page.deletingLastPathComponent()
        // The page's folder, held open from the start: the video and still
        // are put there through this handle, so a folder renamed or swapped
        // for a link meanwhile cannot send them anywhere else.
        let folderAtStart = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let folderHandle = open(folderAtStart, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard folderHandle >= 0 else { throw RenderError.outputMoved }
        defer { close(folderHandle) }
        let server = SceneFiles(folder: folder, three: three)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(server, forURLScheme: scheme)
        configuration.userContentController.add(server, name: "lampError")
        // Peer connections open their own sockets, past the rules below, so
        // the page and every frame in it go without them.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel",
                                "RTCSessionDescription", "RTCIceCandidate", "WebTransport"]) {
              try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch {}
            }
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        // Errors the page throws or rejects, reported rather than lost.
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
            addEventListener("error", e => webkit.messageHandlers.lampError.postMessage(String(e.message)));
            addEventListener("unhandledrejection", e => webkit.messageHandlers.lampError.postMessage(String(e.reason)));
            // A script, picture or stylesheet that fails to load fires its
            // error on the element, without bubbling: caught on the way down.
            addEventListener("error", e => {
              const target = e.target;
              const source = target && target !== window
                && (target.currentSrc || target.src || target.srcset || target.href);
              if (source) webkit.messageHandlers.lampError.postMessage("Could not load " + source);
            }, true);
            // An address off the page's own folder is blocked below, and a
            // blocked load never reaches Lamp to be counted: one asked for by
            // a picture never put on the page, as three loads a texture,
            // reports nothing. So asking for one is reported here. This is
            // for a page that means well; the rules below do the blocking.
            // A stylesheet's url() is not seen here, and draws nothing; the
            // deck skill tells the agent so, and to look at the frames.
            (() => {
              const offline = url => {
                try {
                  const scheme = new URL(String(url), document.baseURI).protocol;
                  return scheme === "lamp-scene:" || scheme === "data:" || scheme === "blob:";
                } catch { return true; }
              };
              const report = url => webkit.messageHandlers.lampError.postMessage(
                "Could not load " + url + ": Lamp loads nothing from the network or outside the page's folder");
              // A link loads only for these; one naming a licence or an
              // author loads nothing.
              const fetches = element => element.tagName !== "LINK"
                || /\\b(stylesheet|preload|modulepreload|prefetch|icon|manifest)\\b/i.test(element.rel || "");
              const check = (element, name, value) => {
                if (!fetches(element)) return;
                // A srcset lists several, each an address and a size.
                const urls = /^srcset$/i.test(name)
                  ? String(value).split(",").map(part => part.trim().split(/\\s+/)[0]).filter(Boolean)
                  : [value];
                for (const url of urls) if (!offline(url)) report(url);
              };
              const watch = (type, property) => {
                const field = Object.getOwnPropertyDescriptor(type.prototype, property);
                if (!field || !field.set) return;
                Object.defineProperty(type.prototype, property, { ...field, set(value) {
                  check(this, property, value);
                  return field.set.call(this, value);
                } });
              };
              watch(HTMLImageElement, "src");
              watch(HTMLImageElement, "srcset");
              watch(HTMLSourceElement, "srcset");
              watch(HTMLScriptElement, "src");
              watch(HTMLLinkElement, "href");
              watch(HTMLSourceElement, "src");
              // Only on elements that load what they name: a link to a
              // picture's source, in a credit, loads nothing.
              const loads = /^(IMG|SCRIPT|LINK|SOURCE|IFRAME|VIDEO|AUDIO|EMBED|TRACK)$/;
              const setAttribute = Element.prototype.setAttribute;
              Element.prototype.setAttribute = function (name, value) {
                if (loads.test(this.tagName) && /^(src|href|srcset)$/i.test(name)) check(this, name, value);
                return setAttribute.call(this, name, value);
              };
              const fetchFrom = window.fetch;
              window.fetch = function (input, init) {
                const url = typeof input === "string" || input instanceof URL ? input : input?.url;
                if (!offline(url)) report(url);
                return fetchFrom.apply(this, arguments);
              };
              const open = XMLHttpRequest.prototype.open;
              XMLHttpRequest.prototype.open = function (method, url) {
                if (!offline(url)) report(url);
                return open.apply(this, arguments);
              };
            })();
            """,
            injectionTime: .atDocumentStart,
            // Every frame: a part of the scene drawn in a frame of its own
            // that fails is a failed scene.
            forMainFrameOnly: false
        ))
        // Without its rules the page could reach the network, so a failure to
        // set them up stops the render rather than going on without them.
        guard let rules = try? await blockEverythingElse() else { throw RenderError.offlineRulesUnavailable }
        configuration.userContentController.add(rules)

        // Laid out at the video's size in points; the snapshot comes back at
        // the screen's scale and is drawn down to the video's pixels.
        let view = WKWebView(
            frame: NSRect(x: 0, y: 0, width: options.width, height: options.height),
            configuration: configuration
        )
        let navigation = Navigation()
        view.navigationDelegate = navigation
        let relative = page.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? page.lastPathComponent
        // A page that never answers is given up on, and unloaded, which ends
        // its script and settles any call still waiting on it.
        defer {
            view.stopLoading()
            navigation.cancel()
            view.navigationDelegate = nil
            view.loadHTMLString("", baseURL: nil)
            configuration.userContentController.removeAllUserScripts()
            configuration.userContentController.removeScriptMessageHandler(forName: "lampError")
        }
        try await within(readyTimeout, "to load") {
            try await navigation.load(URL(string: "\(scheme)://scene/\(relative)")!, in: view)
        }

        // The page's modules load after the document does.
        let deadline = Date().addingTimeInterval(readyTimeout)
        while try await within(readyTimeout, "to set up its scene", {
            (try? await view.evaluateJavaScript("typeof window.lamp?.render === 'function'")) as? Bool
        }) != true {
            if let error = server.pageErrors.first { throw RenderError.script(error) }
            guard Date() < deadline else { throw RenderError.noScene(server.pageErrors.first ?? "") }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Textures and models load before the first frame.
        _ = try await within(readyTimeout, "for window.lamp.ready") {
            try await script(view, "await (window.lamp.ready ?? null); return true;", server: server)
        }
        // An error the page threw anywhere, even after setting up its scene,
        // means the scene is not what it meant: no video is made of it.
        if let error = server.pageErrors.first { throw RenderError.script(error) }

        // The page's own length wins: its motion is timed to it, and a loop
        // cut to another length would jump where it closes.
        let pageDuration = try await within(frameTimeout, "to say its duration") {
            (try? await view.evaluateJavaScript(
                "typeof window.lamp.duration === 'number' ? window.lamp.duration : null"
            )) as? Double
        }
        let duration = pageDuration ?? options.duration ?? 10
        guard duration.isFinite, duration >= 1, duration <= longestDuration else {
            throw RenderError.badDuration(duration)
        }
        let frameCount = Int((duration * Double(framesPerSecond)).rounded())

        // One encode at a time on this Mac (`LampVideoEncodeGate`).
        let ticket = await LampVideoEncodeGate.acquire()
        defer { ticket.release() }
        try? FileManager.default.removeItem(at: videoURL)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4) } catch {
            throw RenderError.writer(error.localizedDescription)
        }
        // HEVC in ten bits: about half H.264's size for the same picture,
        // decoded in hardware on every Mac, iPhone and iPad Lamp runs on,
        // and with the depth a soft gradient of sky or glow needs not to
        // band.
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                // By quality, as every video Lamp saves: no one can tell it
                // from the page as drawn (LampVisuallyLosslessVideo).
                AVVideoQualityKey: LampVisuallyLosslessVideo.quality,
                AVVideoMaxKeyFrameIntervalKey: framesPerSecond,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw RenderError.writer(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let sampleFrames = Set([0, frameCount / 4, frameCount / 2, frameCount * 3 / 4])
        var samples: [(Double, Data)] = []
        do {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                // Never `duration` itself: that is frame 0 again, and the
                // loop would hold it twice.
                let seconds = Double(index) / Double(framesPerSecond)
                do {
                    _ = try await within(frameTimeout, "to draw a frame") {
                        try await script(view, "await window.lamp.render(t); return true;", arguments: ["t": seconds], server: server)
                    }
                } catch RenderError.timedOut {
                    throw RenderError.frameTimedOut(seconds)
                } catch RenderError.script(let message) where message.contains("no longer reachable") {
                    // WebKit's word for a promise that can never settle,
                    // seen as soon as nothing holds it: a frame never drawn.
                    throw RenderError.frameTimedOut(seconds)
                }
                if let error = server.pageErrors.first { throw RenderError.script(error) }
                let snapshot = WKSnapshotConfiguration()
                snapshot.afterScreenUpdates = true
                let picture = try await within(frameTimeout, "to show a frame") {
                    try await view.takeSnapshot(configuration: snapshot)
                }
                guard let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw RenderError.writer("a frame could not be read")
                }
                // Waits for the encoder, unless it has failed, which it says
                // only through its status.
                let waitedSince = Date()
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed || Date().timeIntervalSince(waitedSince) > frameTimeout {
                        throw RenderError.writer(writer.error?.localizedDescription ?? "the encoder stopped taking frames")
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard let pool = adaptor.pixelBufferPool,
                      let buffer = pixelBuffer(from: image, pool: pool, width: options.width, height: options.height),
                      adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(framesPerSecond)))
                else { throw RenderError.writer(writer.error?.localizedDescription ?? "a frame could not be added") }
                if index == 0 {
                    let still = try jpeg(image, width: options.width, height: options.height, quality: 0.9)
                    try still.write(to: stillURL, options: .atomic)
                }
                if sampleFrames.contains(index) {
                    samples.append((seconds, try jpeg(image, width: 640, height: 640 * options.height / options.width, quality: 0.8)))
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw RenderError.writer(writer.error?.localizedDescription ?? "unknown")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            throw error
        }

        let bytes = ((try? videoURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        guard bytes <= LampPresentationVideo.largestFileBytes else { throw RenderError.tooLarge(bytes) }

        // A render given up on by whoever asked writes nothing.
        try Task.checkCancellation()
        if let error = server.pageErrors.first { throw RenderError.script(error) }
        var publishedVideo = finalVideo
        var publishedStill = finalStill
        if options.fingerprintsNames {
            let mark = try fingerprint(of: videoURL)
            let videoStem = finalVideo.deletingPathExtension()
            publishedVideo = videoStem.deletingLastPathComponent()
                .appendingPathComponent("\(videoStem.lastPathComponent)-\(mark).mp4")
            let stillStem = finalStill.deletingPathExtension()
            publishedStill = stillStem.deletingLastPathComponent()
                .appendingPathComponent("\(stillStem.lastPathComponent)-\(mark).jpg")
        }
        // Beside the page, through the folder held open since the start, and
        // only while that folder is still the one at the page's path, so
        // what is reported is where the files are.
        var held = stat()
        var atPath = stat()
        guard publishedVideo.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == folderAtStart,
              publishedStill.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == folderAtStart,
              fstat(folderHandle, &held) == 0, lstat(folderAtStart, &atPath) == 0,
              held.st_dev == atPath.st_dev, held.st_ino == atPath.st_ino
        else { throw RenderError.outputMoved }
        try publish(
            [(videoURL, publishedVideo.lastPathComponent), (stillURL, publishedStill.lastPathComponent)],
            in: folderHandle
        )
        return Result(
            videoURL: publishedVideo, stillURL: publishedStill, duration: duration, frameCount: frameCount,
            videoBytes: bytes, samples: samples.map { (seconds: $0.0, jpeg: $0.1) }
        )
    }

    /// The first eight hex digits of `file`'s SHA-256, read a piece at a time.
    static func fingerprint(of file: URL) throws -> String {
        let reading = try FileHandle(forReadingFrom: file)
        defer { try? reading.close() }
        var hash = SHA256()
        while let chunk = try reading.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `body` in the page, failing with the page's own error where it
    /// threw one.
    private static func script(
        _ view: WKWebView,
        _ body: String,
        arguments: [String: Any] = [:],
        server: SceneFiles
    ) async throws -> Any? {
        do {
            return try await view.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            throw RenderError.script(String((message ?? server.pageErrors.first ?? error.localizedDescription).prefix(500)))
        }
    }

    /// Puts each file into the folder open as `folder` under its name, all
    /// or none: each is copied in under a temporary name first, what it
    /// replaces is set aside, and if any rename fails the earlier ones are
    /// put back. Every step goes by the folder's handle, so no link on the way
    /// is followed, and only a plain file is ever replaced.
    static func publish(_ files: [(file: URL, name: String)], in folder: Int32) throws {
        for (_, name) in files {
            guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw RenderError.outputMoved }
            var existing = stat()
            if fstatat(folder, name, &existing, AT_SYMLINK_NOFOLLOW) == 0, (existing.st_mode & S_IFMT) != S_IFREG {
                throw RenderError.writer("\(name) is in the way and is not a file")
            }
        }
        let stamp = UUID().uuidString
        var staged: [String] = []
        var setAside: [(name: String, backup: String)] = []
        var placed: [String] = []
        func undo() {
            for name in placed { unlinkat(folder, name, 0) }
            for (name, backup) in setAside { renameat(folder, backup, folder, name) }
            for temporary in staged { unlinkat(folder, temporary, 0) }
        }
        do {
            for (file, name) in files {
                let temporary = ".\(name).\(stamp)"
                let output = openat(folder, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard output >= 0 else { throw RenderError.writer(String(cString: strerror(errno))) }
                staged.append(temporary)
                let writing = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                defer { try? writing.close() }
                let reading = try FileHandle(forReadingFrom: file)
                defer { try? reading.close() }
                while let chunk = try reading.read(upToCount: 4 * 1_024 * 1_024), !chunk.isEmpty {
                    try writing.write(contentsOf: chunk)
                }
            }
            // The copies take a while; a render given up on meanwhile replaces
            // nothing.
            try Task.checkCancellation()
            for (index, (_, name)) in files.enumerated() {
                let backup = ".\(name).\(stamp).old"
                if renameat(folder, name, folder, backup) == 0 {
                    setAside.append((name, backup))
                } else if errno != ENOENT {
                    throw RenderError.writer(String(cString: strerror(errno)))
                }
                guard renameat(folder, staged[index], folder, name) == 0 else {
                    throw RenderError.writer(String(cString: strerror(errno)))
                }
                placed.append(name)
            }
        } catch {
            undo()
            throw error
        }
        for (_, backup) in setAside { unlinkat(folder, backup, 0) }
    }

    /// `work`'s answer, or `RenderError.timedOut` after `seconds` without
    /// waiting on it further: a promise the page never settles leaves its
    /// call pending for good, and a task group would wait for it.
    private static func within<Value: Sendable>(
        _ seconds: Double,
        _ step: String,
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        var tasks: [Task<Void, Never>] = []
        defer { tasks.forEach { $0.cancel() } }
        let box = ResumeOnceBox<Value>()
        // A caller that gives up is answered at once, as a timeout is.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                box.set(once)
                // Already given up on: answered, and the work never started.
                if Task.isCancelled {
                    once.finish(.failure(CancellationError()))
                    return
                }
                tasks.append(Task { @MainActor in
                    do { once.finish(.success(try await work())) } catch { once.finish(.failure(error)) }
                })
                tasks.append(Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    once.finish(.failure(RenderError.timedOut(step)))
                })
            }
        } onCancel: {
            box.finish(.failure(CancellationError()))
        }
    }

    /// Refuses every load but the page's own address, and the data and blob
    /// addresses a page makes for itself.
    private static func blockEverythingElse() async throws -> WKContentRuleList? {
        // One rule a scheme: a content rule's pattern has no alternation.
        let allowed = [scheme, "data", "blob", "about"].map {
            #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"#
        }
        let rules = "[" + ([#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#] + allowed)
            .joined(separator: ",") + "]"
        return try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "lamp-animation-offline", encodedContentRuleList: rules
        )
    }

    private static func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func jpeg(_ image: CGImage, width: Int, height: Int, quality: Double) throws -> Data {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw RenderError.writer("a still could not be drawn") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { throw RenderError.writer("a still could not be written") }
        return data
    }

    /// Waits for a load to finish, and refuses to go anywhere else.
    private final class Navigation: NSObject, WKNavigationDelegate {
        private var waiting: CheckedContinuation<Void, Error>?

        @MainActor func load(_ url: URL, in view: WKWebView) async throws {
            try await withCheckedThrowingContinuation { continuation in
                waiting = continuation
                view.load(URLRequest(url: url))
            }
        }

        /// Ends a load still being waited for, as given up on.
        func cancel() {
            waiting?.resume(throwing: RenderError.timedOut("to load"))
            waiting = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            navigationAction.request.url?.scheme == LampAnimationRenderer.scheme ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            waiting?.resume()
            waiting = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            waiting?.resume(throwing: RenderError.script(error.localizedDescription))
            waiting = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            waiting?.resume(throwing: RenderError.script(error.localizedDescription))
            waiting = nil
        }
    }

    /// Serves the page's folder and Lamp's three.js, and nothing else; and
    /// keeps what the page reports going wrong.
    private final class SceneFiles: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
        let folder: URL
        let three: URL
        private(set) var pageErrors: [String] = []

        init(folder: URL, three: URL) {
            self.folder = folder.standardizedFileURL.resolvingSymlinksInPath()
            self.three = three
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            record(String(describing: message.body))
        }

        /// The first few problems, shortened: enough to say what went wrong,
        /// and never a store a page could fill.
        private func record(_ problem: String) {
            guard pageErrors.count < 10 else { return }
            pageErrors.append(String(problem.prefix(500)))
        }

        /// Refuses `task`, and counts it against the page: a file the scene
        /// asked for and did not get, by whatever route (a texture loaded
        /// off the page included), leaves the scene not as meant.
        private func refuse(_ task: any WKURLSchemeTask, _ path: String, _ code: URLError.Code, _ why: String) {
            record("Could not load \(path): \(why)")
            task.didFailWithError(URLError(code))
        }

        func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
            guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
            let path = url.path
            let file: URL
            if path == LampAnimationRenderer.threePath {
                file = three
            } else {
                let relative = String(path.drop { $0 == "/" })
                let candidate = folder.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                // Only within the page's folder, however the path is spelled
                // and wherever a link inside it points.
                guard LampPresentationDeckValidator.isSafeAssetPath(relative),
                      candidate.path.hasPrefix(folder.path + "/")
                else { return refuse(task, path, .noPermissionsToReadFile, "outside the page's folder") }
                file = candidate
            }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= LampAnimationRenderer.largestPageFile else {
                return refuse(task, path, .dataLengthExceedsMaximum, "over 64 MB")
            }
            guard var data = try? Data(contentsOf: file) else {
                return refuse(task, path, .fileDoesNotExist, "no such file in the page's folder")
            }
            let type = Self.mimeType(file.pathExtension)
            if type.hasPrefix("text/html") {
                // `import * as THREE from "three"` finds Lamp's copy.
                let map = "<script type=\"importmap\">{\"imports\":{\"three\":\"\(LampAnimationRenderer.threePath)\"}}</script>"
                data = Data(Self.withImportMap(String(decoding: data, as: UTF8.self), map).utf8)
            }
            task.didReceive(HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"]
            )!)
            task.didReceive(data)
            task.didFinish()
        }

        func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

        /// `html` with `map` first in it: straight after its doctype where it
        /// opens with one, which keeps the page out of quirks mode, else at
        /// the very start. Never searched for a tag, which could be inside a
        /// comment or a string; the parser puts it in the head either way.
        static func withImportMap(_ html: String, _ map: String) -> String {
            // Past a byte-order mark, whitespace and comments, which may come
            // before a doctype without costing the page standards mode.
            var rest = html[...]
            while true {
                rest = rest.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
                guard rest.hasPrefix("<!--"), let end = rest.range(of: "-->") else { break }
                rest = rest[end.upperBound...]
            }
            guard rest.lowercased().hasPrefix("<!doctype"), let close = rest.firstIndex(of: ">") else {
                return map + html
            }
            let after = html.index(after: close)
            return String(html[..<after]) + map + String(html[after...])
        }

        private static func mimeType(_ fileExtension: String) -> String {
            switch fileExtension.lowercased() {
            case "html", "htm": "text/html; charset=utf-8"
            case "js", "mjs": "text/javascript"
            case "json": "application/json"
            case "css": "text/css"
            case "png": "image/png"
            case "jpg", "jpeg": "image/jpeg"
            case "webp": "image/webp"
            case "svg": "image/svg+xml"
            case "glb": "model/gltf-binary"
            case "gltf": "model/gltf+json"
            default: "application/octet-stream"
            }
        }
    }
}

/// A continuation resumed by whichever of two tasks finishes first.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<Value, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

/// Holds the `ResumeOnce` a cancellation handler must reach, which exists
/// only once the continuation does.
private final class ResumeOnceBox<Value: Sendable>: @unchecked Sendable {
    private var once: ResumeOnce<Value>?
    private var early: Result<Value, Error>?
    private let lock = NSLock()

    func set(_ once: ResumeOnce<Value>) {
        lock.lock()
        self.once = once
        let pending = early
        lock.unlock()
        if let pending { once.finish(pending) }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let target = once
        if target == nil { early = result }
        lock.unlock()
        target?.finish(result)
    }
}
