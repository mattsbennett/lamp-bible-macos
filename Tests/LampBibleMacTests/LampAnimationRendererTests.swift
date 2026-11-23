import AppKit
import AVFoundation
import Foundation
import Network
import Testing
@testable import LampBibleMacSupport

/// An agent's animation page drawn to a looping video, a frame at a time,
/// with Lamp's three.js and nothing from outside its own folder.
@MainActor
struct LampAnimationRendererTests {
    private let three = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LampBibleMacSupport/Resources/AgentSkills/build-lamp-deck/scene/three.module.min.js")

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return root
    }

    /// The colour at the middle of a JPEG, as 0 to 1.
    private func middle(of url: URL) throws -> (red: Double, green: Double, blue: Double) {
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    @Test func aThreeSceneBecomesALoopingVideoAndItsStill() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/cube.html")
        // A head named in a comment first, where an import map must not go.
        try """
        <!doctype html><!-- copied from a template: <head> --><html><head></head><body style="margin:0">
        <script type="module">
        import * as THREE from "three";
        const renderer = new THREE.WebGLRenderer({ preserveDrawingBuffer: true });
        renderer.setSize(innerWidth, innerHeight);
        document.body.appendChild(renderer.domElement);
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x0000ff);
        const camera = new THREE.PerspectiveCamera(40, innerWidth / innerHeight, 0.1, 100);
        camera.position.z = 5;
        const box = new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshBasicMaterial({ color: 0xff0000 }));
        scene.add(box);
        window.lamp = { duration: 2, render(t) { box.rotation.y = t * Math.PI; renderer.render(scene, camera); } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)

        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/cube.mp4"),
            stillURL: root.appendingPathComponent("Assets/cube.jpg"),
            options: .init(width: 320, height: 180, framesPerSecond: 12)
        )
        #expect(result.duration == 2)
        #expect(result.frameCount == 24)
        #expect(result.samples.count == 4)
        let asset = AVURLAsset(url: result.videoURL)
        #expect(abs(try await asset.load(.duration).seconds - 2) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 320, height: 180))
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        // The cube, red, in the middle of the blue.
        let centre = try middle(of: result.stillURL)
        #expect(centre.red > 0.8 && centre.blue < 0.3)
        // And turning: face on at the start, its silhouette wider a quarter
        // of a turn on, read from the video itself.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func redShare(at seconds: Double) async throws -> Double {
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: image)
            var red = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.6, c.blueComponent < 0.4 { red += 1 }
                }
            }
            return Double(red) / Double((rep.pixelsHigh / 2) * (rep.pixelsWide / 2))
        }
        let faceOn = try await redShare(at: 0)
        let turned = try await redShare(at: 0.25)
        #expect(turned > faceOn * 1.15, "the video does not show the cube turning")
    }

    @Test func aPageCannotOpenAPeerConnection() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/probe.html")
        // Green when no connection could be made; red when one could.
        try """
        <!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="64" height="64"></canvas>
        <script type="module">
        let leaked = false;
        try { new RTCPeerConnection({ iceServers: [{ urls: "stun:stun.example.com" }] }); leaked = true; } catch {}
        const gl = document.getElementById("c").getContext("webgl", { preserveDrawingBuffer: true });
        window.lamp = { duration: 1, render() {
            const bad = leaked;
            gl.clearColor(bad ? 1 : 0, bad ? 0 : 1, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT);
        } };
        document.body.style.background = "black";
        document.getElementById("c").style.cssText = "width:100vw;height:100vh;display:block";
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)

        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/probe.mp4"),
            stillURL: root.appendingPathComponent("Assets/probe.jpg"),
            options: .init(width: 256, height: 256, framesPerSecond: 12)
        )
        let centre = try middle(of: result.stillURL)
        #expect(centre.green > 0.8 && centre.red < 0.2, "the page opened a peer connection")
    }

    @Test func aPageThatNeverSetsUpASceneSaysSo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/empty.html")
        try "<!doctype html><html><body><script>throw new Error('broken scene')</script></body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        await #expect(throws: LampAnimationRenderer.RenderError.script("Error: broken scene")) {
            try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/empty.mp4"),
                stillURL: root.appendingPathComponent("Assets/empty.jpg"),
                options: .init(width: 256, height: 256)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/empty.mp4").path))
    }

    @Test func aFrameThatNeverFinishesIsGivenUpOnAndLeavesNothing() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/stuck.html")
        try """
        <!doctype html><html><body><script>
        // Held, so WebKit cannot see that it will never settle.
        window.pending = new Promise(() => {});
        window.lamp = { duration: 1, render(t) { return t > 0.2 ? window.pending : null; } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let started = Date()
        // At 12 frames a second, 0.25 s is the first frame past 0.2.
        await #expect(throws: LampAnimationRenderer.RenderError.frameTimedOut(0.25)) {
            try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/stuck.mp4"),
                stillURL: root.appendingPathComponent("Assets/stuck.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
        }
        let waited = Date().timeIntervalSince(started)
        #expect(waited >= LampAnimationRenderer.frameTimeout && waited < LampAnimationRenderer.frameTimeout + 10)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/stuck.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/stuck.jpg").path))
    }

    @Test func thePagesOwnLengthWinsOverTheFallback() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/length.html")
        try """
        <!doctype html><html><body><canvas id="c" width="8" height="8"></canvas><script>
        const g = document.getElementById("c").getContext("2d");
        window.lamp = { duration: 2, render(t) { g.fillStyle = "#336699"; g.fillRect(0, 0, 8, 8); } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/length.mp4"),
            stillURL: root.appendingPathComponent("Assets/length.jpg"),
            options: .init(width: 128, height: 128, framesPerSecond: 12, duration: 5)
        )
        #expect(result.duration == 2)
        #expect(result.frameCount == 24)
        // Rendered again, the new video and still replace the old, and
        // nothing else is left in the folder.
        try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/length.mp4"),
            stillURL: root.appendingPathComponent("Assets/length.jpg"),
            options: .init(width: 128, height: 128, framesPerSecond: 12)
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path)
        #expect(Set(files) == ["length.html", "length.mp4", "length.jpg"])
    }

    @Test func aStillThatCannotBeReplacedLeavesTheOldVideoToo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/pair.html")
        try """
        <!doctype html><html><body><canvas id="c" width="8" height="8"></canvas><script>
        const g = document.getElementById("c").getContext("2d");
        window.lamp = { duration: 1, render(t) { g.fillStyle = "#336699"; g.fillRect(0, 0, 8, 8); } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let video = root.appendingPathComponent("Assets/pair.mp4")
        try Data("old video".utf8).write(to: video)
        // A folder where the still would go.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets/pair.jpg"), withIntermediateDirectories: true)
        await #expect(throws: LampAnimationRenderer.RenderError.self) {
            try await LampAnimationRenderer.render(
                page: page, three: three, videoURL: video,
                stillURL: root.appendingPathComponent("Assets/pair.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
        }
        #expect(try Data(contentsOf: video) == Data("old video".utf8))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path)
        #expect(Set(files) == ["pair.html", "pair.mp4", "pair.jpg"])
    }

    @Test func aPageOpeningWithACommentKeepsStandardsMode() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/mode.html")
        // Green in standards mode, red if the import map cost it.
        try """
        <!-- Licence: CC0 --><!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="8" height="8" style="width:100vw;height:100vh;display:block"></canvas><script>
        const g = document.getElementById("c").getContext("2d");
        const standards = document.compatMode === "CSS1Compat";
        window.lamp = { duration: 1, render() { g.fillStyle = standards ? "#00ff00" : "#ff0000"; g.fillRect(0, 0, 8, 8); } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/mode.mp4"),
            stillURL: root.appendingPathComponent("Assets/mode.jpg"),
            options: .init(width: 128, height: 128, framesPerSecond: 12)
        )
        let centre = try middle(of: result.stillURL)
        #expect(centre.green > 0.8 && centre.red < 0.2)
    }

    @Test func theVideoHoldsEachFrameAsDrawn() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/halves.html")
        // Red for the first half second, blue for the second.
        try """
        <!doctype html><html><body style="margin:0">
        <canvas id="c" width="8" height="8" style="width:100vw;height:100vh;display:block"></canvas><script>
        const g = document.getElementById("c").getContext("2d");
        window.lamp = { duration: 1, render(t) { g.fillStyle = t < 0.5 ? "#ff0000" : "#0000ff"; g.fillRect(0, 0, 8, 8); } };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/halves.mp4"),
            stillURL: root.appendingPathComponent("Assets/halves.jpg"),
            options: .init(width: 128, height: 128, framesPerSecond: 12)
        )
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.videoURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func colour(at seconds: Double) async throws -> NSColor {
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let rep = NSBitmapImageRep(cgImage: image)
            return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let early = try await colour(at: 0.1)
        let late = try await colour(at: 0.8)
        #expect(early.redComponent > 0.8 && early.blueComponent < 0.3)
        #expect(late.blueComponent > 0.8 && late.redComponent < 0.3)
    }

    @Test func nothingReachesAListenerOnThisMac() async throws {
        // A listener the page is pointed at: any request, socket or fetch,
        // that got out would arrive here.
        final class Arrivals: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func add() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let arrivals = Arrivals()
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            arrivals.add()
            connection.cancel()
        }
        let ready = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.yield(listener.port?.rawValue ?? 0); continuation.finish() }
            }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16 = 0
        for await value in ready { port = value }
        #expect(port != 0)

        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/listener.html")
        try """
        <!doctype html><html><body><script type="module">
        try { await fetch("http://127.0.0.1:\(port)/", { mode: "no-cors" }); } catch {}
        try { new WebSocket("ws://127.0.0.1:\(port)/"); } catch {}
        try { const i = new Image(); i.src = "http://127.0.0.1:\(port)/i.png"; document.body.append(i); } catch {}
        await new Promise(r => setTimeout(r, 500));
        window.lamp = { duration: 1, render() {} };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        // Asking for the listener is reported, which fails the render and
        // shows the probes ran; what matters is that nothing arrived.
        do {
            _ = try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/listener.mp4"),
                stillURL: root.appendingPathComponent("Assets/listener.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("the page's requests went unreported")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("127.0.0.1:\(port)"))
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(arrivals.value == 0, "the page reached a listener on this Mac")
    }

    @Test func anErrorAfterTheSceneIsSetUpStillStopsTheRender() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/late.html")
        try """
        <!doctype html><html><body><script>
        window.lamp = { duration: 1, render() {} };
        throw new Error("scene setup failed");
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        await #expect(throws: LampAnimationRenderer.RenderError.script("Error: scene setup failed")) {
            try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/late.mp4"),
                stillURL: root.appendingPathComponent("Assets/late.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/late.mp4").path))
    }

    @Test func aScriptThatFailsToLoadStopsTheRender() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/missing.html")
        try """
        <!doctype html><html><body><script>
        window.lamp = { duration: 1, render() {} };
        </script><script src="details.js"></script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        do {
            _ = try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/missing.mp4"),
                stillURL: root.appendingPathComponent("Assets/missing.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("a page missing a script it loads was made into a video")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("details.js"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Assets/missing.mp4").path))
    }

    @Test func aFileOutsideThePagesFolderOrMissingFromItStopsTheRender() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try "window.escaped = true;".write(to: root.appendingPathComponent("outside.js"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Assets/link.js"),
            withDestinationURL: root.appendingPathComponent("outside.js")
        )
        // A module through a link out of the folder, one climbing out of it,
        // and a texture that is not there, as three loads one: off the page.
        for (name, body, named) in [
            ("link", "await import('./link.js');", "link.js"),
            ("parent", "await import('../outside.js');", "outside.js"),
            ("texture", """
            const THREE = await import("three");
            const manager = new THREE.LoadingManager();
            const loaded = new Promise(r => { manager.onLoad = r; manager.onError = r; });
            new THREE.TextureLoader(manager).load("missing.png");
            """, "missing.png"),
        ] {
            let page = root.appendingPathComponent("Assets/\(name).html")
            try """
            <!doctype html><html><body><script type="module">
            window.lamp = { duration: 1, render() {} };
            try { \(body) } catch {}
            await new Promise(r => setTimeout(r, 200));
            </script></body></html>
            """.write(to: page, atomically: true, encoding: .utf8)
            do {
                _ = try await LampAnimationRenderer.render(
                    page: page, three: three,
                    videoURL: root.appendingPathComponent("Assets/\(name).mp4"),
                    stillURL: root.appendingPathComponent("Assets/\(name).jpg"),
                    options: .init(width: 128, height: 128, framesPerSecond: 12)
                )
                Issue.record("\(name): a scene missing \(named) was made into a video")
            } catch LampAnimationRenderer.RenderError.script(let message) {
                #expect(message.contains(named), "\(name): \(message)")
            }
        }
    }

    @Test func aTextureAskedForFromTheNetworkStopsTheRender() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/remote.html")
        // As three's TextureLoader does: a picture never put on the page,
        // its failure handled.
        try """
        <!doctype html><html><body><script type="module">
        const THREE = await import("three");
        await new Promise(r => new THREE.TextureLoader().load("https://example.com/stone.jpg", r, undefined, r));
        window.lamp = { duration: 1, render() {} };
        </script></body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        do {
            _ = try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/remote.mp4"),
                stillURL: root.appendingPathComponent("Assets/remote.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("a scene missing its network texture was made into a video")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("stone.jpg"))
        }
    }

    @Test func aCreditsLinkIsNoLoadButABaseOnlineIs() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let credit = root.appendingPathComponent("Assets/credit.html")
        try """
        <!doctype html><html><body><script>
        const a = document.createElement("a");
        a.setAttribute("href", "https://example.com/source");
        a.textContent = "Model after a drawing";
        document.body.append(a);
        const licence = document.createElement("link");
        licence.rel = "license";
        licence.setAttribute("href", "https://creativecommons.org/publicdomain/zero/1.0/");
        document.head.append(licence);
        window.lamp = { duration: 1, render() {} };
        </script></body></html>
        """.write(to: credit, atomically: true, encoding: .utf8)
        _ = try await LampAnimationRenderer.render(
            page: credit, three: three,
            videoURL: root.appendingPathComponent("Assets/credit.mp4"),
            stillURL: root.appendingPathComponent("Assets/credit.jpg"),
            options: .init(width: 128, height: 128, framesPerSecond: 12)
        )

        let based = root.appendingPathComponent("Assets/based.html")
        try """
        <!doctype html><html><head><base href="https://example.com/"></head><body><script>
        new Promise(r => { const i = new Image(); i.onload = r; i.onerror = r; i.src = "stone.jpg"; });
        window.lamp = { duration: 1, render() {} };
        </script></body></html>
        """.write(to: based, atomically: true, encoding: .utf8)
        let sized = root.appendingPathComponent("Assets/sized.html")
        try """
        <!doctype html><html><body><script>
        const i = new Image(); i.onerror = () => {};
        i.srcset = "stone.png 1x, https://example.com/stone@2x.png 2x";
        window.lamp = { duration: 1, render() {} };
        </script></body></html>
        """.write(to: sized, atomically: true, encoding: .utf8)
        do {
            _ = try await LampAnimationRenderer.render(
                page: sized, three: three,
                videoURL: root.appendingPathComponent("Assets/sized.mp4"),
                stillURL: root.appendingPathComponent("Assets/sized.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("a srcset's online candidate went unreported")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("stone@2x.png") || message.contains("stone.png"))
        }
        do {
            _ = try await LampAnimationRenderer.render(
                page: based, three: three,
                videoURL: root.appendingPathComponent("Assets/based.mp4"),
                stillURL: root.appendingPathComponent("Assets/based.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("a picture asked for online through the page's base went unreported")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("stone.jpg"))
        }
    }

    @Test func aPictureInTheMarkupAskedForOnlineStopsTheRender() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/markup.html")
        // Written into the page, not set from a script: the parser bypasses
        // every setter.
        try """
        <!doctype html><html><body>
        <img srcset="https://example.com/stone.png 1x" alt="">
        <script>window.lamp = { duration: 1, render() {} };</script>
        </body></html>
        """.write(to: page, atomically: true, encoding: .utf8)
        do {
            _ = try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/markup.mp4"),
                stillURL: root.appendingPathComponent("Assets/markup.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12)
            )
            Issue.record("a picture the markup asked for online went unreported")
        } catch LampAnimationRenderer.RenderError.script(let message) {
            #expect(message.contains("stone.png"))
        }
    }

    @Test func aChangedAnimationArrivesUnderNewNames() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/scene.html")
        func draw(_ colour: String) throws {
            try """
            <!doctype html><html><body style="margin:0">
            <canvas id="c" width="8" height="8" style="width:100vw;height:100vh;display:block"></canvas><script>
            const g = document.getElementById("c").getContext("2d");
            window.lamp = { duration: 1, render() { g.fillStyle = "\(colour)"; g.fillRect(0, 0, 8, 8); } };
            </script></body></html>
            """.write(to: page, atomically: true, encoding: .utf8)
        }
        func render() async throws -> LampAnimationRenderer.Result {
            try await LampAnimationRenderer.render(
                page: page, three: three,
                videoURL: root.appendingPathComponent("Assets/scene.mp4"),
                stillURL: root.appendingPathComponent("Assets/scene.jpg"),
                options: .init(width: 128, height: 128, framesPerSecond: 12, fingerprintsNames: true)
            )
        }
        try draw("#ff0000")
        let first = try await render()
        try draw("#0000ff")
        let second = try await render()
        #expect(first.videoURL.lastPathComponent.range(of: #"^scene-[0-9a-f]{8}\.mp4$"#, options: .regularExpression) != nil)
        #expect(first.stillURL.deletingPathExtension().lastPathComponent == first.videoURL.deletingPathExtension().lastPathComponent)
        #expect(first.videoURL != second.videoURL)
        #expect(FileManager.default.fileExists(atPath: second.videoURL.path))
        #expect(FileManager.default.fileExists(atPath: second.stillURL.path))
    }
}
