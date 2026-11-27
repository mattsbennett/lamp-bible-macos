import AppKit
import AVFoundation
import Foundation
import Testing
@testable import LampBibleMacSupport

/// three.js's WebGPU renderer and its shading language on an animation page
/// (item 4 of the animation plan), every frame kept as drawn, and which
/// backend drew it said. Small pages: 256 pixels, a second at 12 frames.
@MainActor
@Suite(.serialized, .enabled(if: LampAnimationCaptureTests.hasWebGPU))
struct LampAnimationWebGPUTests {
    private let three = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LampBibleMacSupport/Resources/AnimationRuntime/three")

    private func render(_ html: String) async throws -> (LampAnimationRenderer.Result, [NSColor], URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        let page = root.appendingPathComponent("Assets/gpu.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        let result = try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/gpu.mp4"),
            stillURL: root.appendingPathComponent("Assets/gpu.jpg"),
            options: .init(width: 256, height: 256, framesPerSecond: 12)
        )
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: result.videoURL))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var colours: [NSColor] = []
        for index in 0..<result.frameCount {
            let (image, _) = try await generator.image(at: CMTime(value: CMTimeValue(index), timescale: 12))
            let rep = NSBitmapImageRep(cgImage: image)
            colours.append(try #require(rep.colorAt(x: rep.pixelsWide / 8, y: rep.pixelsHigh / 8)?.usingColorSpace(.sRGB)))
        }
        return (result, colours, root)
    }

    /// The frames whose corner is not their own colour from the palette.
    private func wrong(_ colours: [NSColor]) -> [Int] {
        colours.enumerated().compactMap { index, colour in
            let expected = LampAnimationCaptureTests.palette[index % LampAnimationCaptureTests.palette.count]
            let off = abs(colour.redComponent - expected.0) + abs(colour.greenComponent - expected.1) + abs(colour.blueComponent - expected.2)
            return off > 0.6 ? index : nil
        }
    }

    /// A WebGPURenderer page: a box on its frame's background colour.
    private func page(options: String = "", before: String = "") -> String {
        """
        <!doctype html><html><head></head><body style="margin:0">
        <script type="module">
        \(before)
        import * as THREE from "three/webgpu";
        const renderer = new THREE.WebGPURenderer({ \(options) });
        renderer.setSize(innerWidth, innerHeight);
        renderer.outputColorSpace = THREE.LinearSRGBColorSpace;
        document.body.appendChild(renderer.domElement);
        await renderer.init();
        const scene = new THREE.Scene();
        const camera = new THREE.PerspectiveCamera(40, 1, 0.1, 100);
        camera.position.z = 5;
        scene.add(new THREE.Mesh(new THREE.BoxGeometry(1, 1, 1), new THREE.MeshBasicNodeMaterial({ color: 0xffffff })));
        const palette = \(LampAnimationCaptureTests.paletteJS);
        window.lamp = { duration: 1, render(t) {
          scene.background = new THREE.Color().setRGB(...palette[Math.round(t * 12) % palette.length], THREE.LinearSRGBColorSpace);
          renderer.render(scene, camera);
        } };
        </script></body></html>
        """
    }

    @Test func aWebGPURendererPageIsKeptFrameByFrameAndSaysItDrewWithWebGPU() async throws {
        let (result, colours, root) = try await render(page())
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(wrong(colours).isEmpty, "frames kept wrong: \(wrong(colours))")
        #expect(result.drewWith == "webgpu")
    }

    @Test func forcedOntoWebGLItSaysSo() async throws {
        let (result, colours, root) = try await render(page(options: "forceWebGL: true"))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(wrong(colours).isEmpty, "frames kept wrong: \(wrong(colours))")
        #expect(result.drewWith == "webgl")
    }

    /// As on a Mac whose web views have no WebGPU (macOS 15 to 25): the same
    /// page falls back to WebGL, and draws the same.
    @Test func withNoWebGPUThePageFallsBackToWebGL() async throws {
        let hidden = #"Object.defineProperty(navigator, "gpu", { value: undefined, configurable: true });"#
        // Hidden before three is imported, in a module of its own.
        let html = page().replacingOccurrences(
            of: "<script type=\"module\">\n\n",
            with: "<script>\(hidden)</script>\n<script type=\"module\">\n"
        )
        let (result, colours, root) = try await render(html)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(wrong(colours).isEmpty, "frames kept wrong: \(wrong(colours))")
        #expect(result.drewWith == "webgl")
    }

    /// A RenderPipeline with TSL's bloom lights the dark beside a bright box.
    @Test func aRenderPipelineWithBloomLightsBesideABrightBox() async throws {
        let html = """
        <!doctype html><html><head></head><body style="margin:0;background:#000">
        <script type="module">
        import * as THREE from "three/webgpu";
        import { pass } from "three/tsl";
        import { bloom } from "three/addons/tsl/display/BloomNode.js";
        const renderer = new THREE.WebGPURenderer();
        renderer.setSize(innerWidth, innerHeight);
        document.body.appendChild(renderer.domElement);
        renderer.setClearColor(0x000000, 1);
        await renderer.init();
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x000000);
        const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
        camera.position.z = 5;
        scene.add(new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.5), new THREE.MeshBasicNodeMaterial({ color: 0xffffff })));
        const pipeline = new THREE.RenderPipeline(renderer);
        const scenePass = pass(scene, camera);
        const colour = scenePass.getTextureNode();
        pipeline.outputNode = colour.add(bloom(colour, 2.5, 0.6, 0));
        window.lamp = { duration: 1, render() { pipeline.render(); } };
        </script></body></html>
        """
        let (result, _, root) = try await render(html)
        defer { try? FileManager.default.removeItem(at: root) }
        // The still, which is the first frame: lit, not black.
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: result.stillURL)))
        let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(middle.brightnessComponent > 0.9)
        let beside = try #require(rep.colorAt(x: 176 * rep.pixelsWide / 256, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let corner = try #require(rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
        #expect(beside.brightnessComponent > corner.brightnessComponent + 0.1, "beside \(beside.brightnessComponent), corner \(corner.brightnessComponent)")
        #expect(result.drewWith == "webgpu")
    }

    /// Every TSL module Lamp has loads.
    @Test func everyTSLModuleLoads() async throws {
        let manifest = try #require(LampAnimationRuntime.manifest(in: three))
        let modules = manifest.files.keys.filter { $0.hasPrefix("examples/jsm/tsl/") && $0.hasSuffix(".js") }.sorted()
        #expect(modules.count > 30)
        let list = modules.map { "\"three/addons/\($0.dropFirst("examples/jsm/".count))\"" }.joined(separator: ",")
        let html = """
        <!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="64" height="64" style="width:100vw;height:100vh;display:block"></canvas>
        <script type="module">
        const loaded = await Promise.all([\(list)].map((p) => import(p)));
        const ok = loaded.length === \(modules.count);
        const gl = document.getElementById("c").getContext("webgl", { preserveDrawingBuffer: true });
        window.lamp = { duration: 1, render() { gl.clearColor(ok ? 0 : 1, ok ? 1 : 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); } };
        </script></body></html>
        """
        let (_, colours, root) = try await render(html)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(colours.first.map { $0.greenComponent > 0.8 } == true)
    }
}
