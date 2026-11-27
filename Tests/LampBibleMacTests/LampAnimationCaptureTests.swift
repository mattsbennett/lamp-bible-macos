import AppKit
import AVFoundation
import Foundation
import Testing
@testable import LampBibleMacSupport

/// Every frame of a page kept as drawn, whatever it draws with
/// (`decisions/0025`). Each page clears to a colour named by its frame, so
/// a frame kept late, or one before it, reads as the wrong colour.
@MainActor
@Suite(.serialized)
struct LampAnimationCaptureTests {
    private let three = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LampBibleMacSupport/Resources/AnimationRuntime/three")

    /// The colour of frame `i`: one of six, so neighbours always differ.
    static let palette: [(Double, Double, Double)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (0, 1, 1), (1, 0, 1)]
    static let paletteJS = "[[1,0,0],[0,1,0],[0,0,1],[1,1,0],[0,1,1],[1,0,1]]"

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return root
    }

    /// Renders `html` at 12 frames a second for 1 second, and the index of
    /// each frame whose middle is not its own colour.
    private func wrongFrames(_ html: String, point: (Double, Double) = (0.5, 0.5)) async throws -> [Int] {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/frames.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/frames.mp4"),
            stillURL: root.appendingPathComponent("Assets/frames.jpg"),
            options: .init(width: 256, height: 256, framesPerSecond: 12)
        )
        let asset = AVURLAsset(url: result.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var wrong: [Int] = []
        for index in 0..<result.frameCount {
            let time = CMTime(value: CMTimeValue(index), timescale: 12)
            let (image, _) = try await generator.image(at: time)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let colour = rep.colorAt(x: Int(Double(rep.pixelsWide) * point.0), y: Int(Double(rep.pixelsHigh) * point.1))?
                .usingColorSpace(.sRGB) else { wrong.append(index); continue }
            let expected = Self.palette[index % Self.palette.count]
            let off = abs(colour.redComponent - expected.0) + abs(colour.greenComponent - expected.1) + abs(colour.blueComponent - expected.2)
            if off > 0.6 { wrong.append(index) }
        }
        return wrong
    }

    /// A raw WebGPU page: a canvas cleared to its frame's colour, submitted
    /// in the task `render` is called in.
    static func webGPUPage(beforeRender: String = "", afterSubmit: String = "", canvasSetup: String = "") -> String {
        """
        <!doctype html><html><head></head><body style="margin:0;background:#000">
        <canvas id="c" style="width:100vw;height:100vh;display:block"></canvas>
        <script type="module">
        const canvas = document.getElementById("c");
        canvas.width = 256; canvas.height = 256;
        \(canvasSetup)
        const adapter = await navigator.gpu.requestAdapter();
        const device = await adapter.requestDevice();
        const context = canvas.getContext("webgpu");
        const format = navigator.gpu.getPreferredCanvasFormat();
        context.configure({ device, format, alphaMode: "opaque" });
        const palette = \(paletteJS);
        window.lamp = { duration: 1, async render(t) {
          \(beforeRender)
          const [r, g, b] = palette[Math.round(t * 12) % palette.length];
          const encoder = device.createCommandEncoder();
          const pass = encoder.beginRenderPass({ colorAttachments: [{
            view: context.getCurrentTexture().createView(), clearValue: { r, g, b, a: 1 }, loadOp: "clear", storeOp: "store" }] });
          pass.end();
          device.queue.submit([encoder.finish()]);
          \(afterSubmit)
        } };
        </script></body></html>
        """
    }

    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func everyFrameOfARawWebGPUPageIsItsOwn() async throws {
        let wrong = try await wrongFrames(Self.webGPUPage())
        #expect(wrong.isEmpty, "frames kept wrong: \(wrong)")
    }

    /// A frame drawn, then waited past: kept as drawn.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aRenderThatWaitsAfterDrawingIsKept() async throws {
        let wrong = try await wrongFrames(Self.webGPUPage(afterSubmit: "await new Promise((r) => setTimeout(r, 40));"))
        #expect(wrong.isEmpty, "frames kept wrong: \(wrong)")
    }

    /// A frame drawn only after `render` waits: kept, since it asks for its
    /// texture and submits in one task.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aRenderThatWaitsBeforeDrawingIsKept() async throws {
        let wrong = try await wrongFrames(Self.webGPUPage(beforeRender: "await new Promise((r) => setTimeout(r, 40));"))
        #expect(wrong.isEmpty, "frames kept wrong: \(wrong)")
    }

    /// HTML over the canvas is in the frame, and the canvas under it is the
    /// frame's own.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func htmlOverAWebGPUCanvasIsInTheFrame() async throws {
        let html = Self.webGPUPage().replacingOccurrences(
            of: "<canvas id=\"c\"",
            with: "<div style=\"position:fixed;left:0;top:0;width:30vw;height:30vh;background:#fff;z-index:2\"></div><canvas id=\"c\""
        )
        #expect(try await wrongFrames(html).isEmpty)
        let corner = try await colours(html, at: (0.1, 0.1))
        #expect(corner.allSatisfy { $0.0 > 0.9 && $0.1 > 0.9 && $0.2 > 0.9 }, "\(corner)")
    }

    /// A see-through canvas shows what is behind it, as the page has it.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aSeeThroughCanvasShowsTheBackgroundBehindIt() async throws {
        let html = Self.webGPUPage()
            .replacingOccurrences(of: "background:#000", with: "background:#fff")
            .replacingOccurrences(of: "alphaMode: \"opaque\"", with: "alphaMode: \"premultiplied\"")
            .replacingOccurrences(of: "clearValue: { r, g, b, a: 1 }", with: "clearValue: { r: 0, g: 0, b: 0, a: 0 }")
        let middle = try await colours(html, at: (0.5, 0.5))
        #expect(middle.allSatisfy { $0.0 > 0.9 && $0.1 > 0.9 && $0.2 > 0.9 }, "\(middle)")
    }

    /// A canvas given a new size after its context draws at that size.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aCanvasSizedAfterItsContextIsKept() async throws {
        let html = Self.webGPUPage().replacingOccurrences(
            of: "const palette =", with: "canvas.width = 64; canvas.setAttribute(\"height\", \"64\");\n        const palette ="
        )
        #expect(try await wrongFrames(html).isEmpty)
    }

    /// WebGL needs nothing: its frames are right with the default drawing
    /// buffer, drawn at once or after a wait.
    @Test(arguments: ["", "await new Promise((r) => setTimeout(r, 40));"])
    func webGLWithoutAKeptBufferIsRight(_ wait: String) async throws {
        let html = """
        <!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="256" height="256" style="width:100vw;height:100vh;display:block"></canvas>
        <script type="module">
        const gl = document.getElementById("c").getContext("webgl");
        const palette = \(Self.paletteJS);
        window.lamp = { duration: 1, async render(t) {
          \(wait)
          const [r, g, b] = palette[Math.round(t * 12) % palette.length];
          gl.clearColor(r, g, b, 1); gl.clear(gl.COLOR_BUFFER_BIT);
        } };
        </script></body></html>
        """
        #expect(try await wrongFrames(html).isEmpty)
    }

    /// The canvas keeps the browser's rules: one kind of context, its
    /// context's canvas the page's, and none sent offscreen with WebGPU.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aWebGPUCanvasKeepsTheBrowsersRules() async throws {
        let checks = """
        const fail = (what) => { throw new Error("check failed: " + what); };
        if (canvas.getContext("2d") !== null) fail("a second kind was given");
        if (context.canvas !== canvas) fail("context.canvas is not the page's");
        if (canvas.getContext("webgpu") !== context) fail("a second WebGPU context");
        let refused = false;
        try { canvas.transferControlToOffscreen(); } catch { refused = true; }
        if (!refused) fail("a WebGPU canvas went offscreen");
        const gl = document.createElement("canvas");
        gl.getContext("webgl");
        if (gl.getContext("webgpu") !== null) fail("WebGPU after WebGL");
        const sent = document.createElement("canvas");
        sent.transferControlToOffscreen();
        let threw = false;
        try { sent.getContext("webgpu"); } catch { threw = true; }
        if (!threw) fail("WebGPU on a canvas sent offscreen");
        """
        let html = Self.webGPUPage().replacingOccurrences(of: "const palette =", with: checks + "\n        const palette =")
        #expect(try await wrongFrames(html).isEmpty)
    }

    /// A frame that uploads a material's texture after asking for its own
    /// and before drawing is kept as drawn, not as it was before.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func anUploadBeforeTheDrawDoesNotKeepTheFrameEarly() async throws {
        let html = Self.webGPUPage(
            beforeRender: """
            const view = context.getCurrentTexture();
            const material = device.createTexture({ size: [4, 4], format: "rgba8unorm", usage: GPUTextureUsage.COPY_DST | GPUTextureUsage.TEXTURE_BINDING });
            device.queue.writeTexture({ texture: material }, new Uint8Array(64), { bytesPerRow: 16 }, [4, 4]);
            const upload = device.createCommandEncoder();
            device.queue.submit([upload.finish()]);
            """
        )
        let wrong = try await wrongFrames(html)
        #expect(wrong.isEmpty, "frames kept wrong: \(wrong)")
    }

    /// A canvas configured again and not drawn on is empty, as the spec has
    /// it, not the frame before.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func aCanvasConfiguredAgainIsEmptyUntilDrawn() async throws {
        let html = Self.webGPUPage()
            .replacingOccurrences(of: "background:#000", with: "background:#fff")
            .replacingOccurrences(of: "alphaMode: \"opaque\"", with: "alphaMode: \"premultiplied\"")
            .replacingOccurrences(
                of: "const [r, g, b] = palette",
                with: "if (Math.round(t * 12) % 2 === 1) { context.configure({ device, format, alphaMode: \"premultiplied\" }); return; }\n          const [r, g, b] = palette"
            )
        let shown = try await colours(html, at: (0.5, 0.5))
        for (index, colour) in shown.enumerated() where index % 2 == 1 {
            #expect(colour.0 > 0.9 && colour.1 > 0.9 && colour.2 > 0.9, "frame \(index): \(colour)")
        }
    }

    /// WebGPU on an offscreen canvas reaches no snapshot, so it is refused
    /// by name.
    @Test(.enabled(if: LampAnimationCaptureTests.hasWebGPU))
    func webGPUOnAnOffscreenCanvasIsRefused() async throws {
        let html = Self.webGPUPage().replacingOccurrences(
            of: "const palette =", with: "new OffscreenCanvas(64, 64).getContext(\"webgpu\");\n        const palette ="
        )
        do {
            _ = try await wrongFrames(html)
            Issue.record("rendered with WebGPU on an offscreen canvas")
        } catch {
            #expect(error.localizedDescription.contains("OffscreenCanvas"), "\(error.localizedDescription)")
        }
    }

    /// A 2D page is drawn once a frame, never twice: one painting over its
    /// last frame would show the first one twice.
    @Test func a2DPageIsDrawnOnceAFrame() async throws {
        let html = """
        <!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="256" height="256" style="width:100vw;height:100vh;display:block"></canvas>
        <script type="module">
        const flat = document.getElementById("c").getContext("2d");
        const palette = \(Self.paletteJS);
        let calls = 0;
        window.lamp = { duration: 1, render(t) {
          calls += 1;
          const index = Math.round(t * 12);
          const [r, g, b] = calls === index + 1 ? palette[index % palette.length] : [0.5, 0.5, 0.5];
          flat.fillStyle = `rgb(${r * 255}, ${g * 255}, ${b * 255})`;
          flat.fillRect(0, 0, 256, 256);
        } };
        </script></body></html>
        """
        #expect(try await wrongFrames(html).isEmpty)
    }

    /// The colour at `point` of each frame, as 0 to 1.
    private func colours(_ html: String, at point: (Double, Double)) async throws -> [(Double, Double, Double)] {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = root.appendingPathComponent("Assets/frames.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/frames.mp4"),
            stillURL: root.appendingPathComponent("Assets/frames.jpg"),
            options: .init(width: 256, height: 256, framesPerSecond: 12)
        )
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.videoURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var found: [(Double, Double, Double)] = []
        for index in 0..<result.frameCount {
            let (image, _) = try await generator.image(at: CMTime(value: CMTimeValue(index), timescale: 12))
            let rep = NSBitmapImageRep(cgImage: image)
            let c = try #require(rep.colorAt(x: Int(Double(rep.pixelsWide) * point.0), y: Int(Double(rep.pixelsHigh) * point.1))?.usingColorSpace(.sRGB))
            found.append((c.redComponent, c.greenComponent, c.blueComponent))
        }
        return found
    }

    /// Whether this Mac's web views have WebGPU (from macOS 26).
    nonisolated static var hasWebGPU: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
}
