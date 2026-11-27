import AppKit
import CryptoKit
import Foundation
import Testing
@testable import LampBibleMacSupport

/// Lamp's copy of three.js and its addons, as an animation page imports them
/// (`decisions/0027`). Every page here is small: a few frames at 256 pixels.
@MainActor
@Suite(.serialized)
struct LampAnimationThreeTests {
    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/LampBibleMacSupport/Resources")
    private let three = Self.sources.appendingPathComponent("AnimationRuntime/three")

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return root
    }

    private func render(_ html: String, in root: URL, name: String = "page") async throws -> LampAnimationRenderer.Result {
        let page = root.appendingPathComponent("Assets/\(name).html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        return try await LampAnimationRenderer.render(
            page: page, three: three,
            videoURL: root.appendingPathComponent("Assets/\(name).mp4"),
            stillURL: root.appendingPathComponent("Assets/\(name).jpg"),
            options: .init(width: 256, height: 256, framesPerSecond: 12)
        )
    }

    private func colour(at point: (x: Int, y: Int), of url: URL) throws -> NSColor {
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: url)))
        return try #require(rep.colorAt(x: point.x, y: point.y)?.usingColorSpace(.sRGB))
    }

    /// A page drawing green when `check` is true of what it imported, red
    /// otherwise, so a still says which.
    private func page(imports: String, check: String) -> String {
        """
        <!doctype html><html><head></head><body style="margin:0">
        <canvas id="c" width="64" height="64" style="width:100vw;height:100vh;display:block"></canvas>
        <script type="module">
        \(imports)
        const ok = \(check);
        const gl = document.getElementById("c").getContext("webgl", { preserveDrawingBuffer: true });
        window.lamp = { duration: 1, render() { gl.clearColor(ok ? 0 : 1, ok ? 1 : 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT); } };
        </script></body></html>
        """
    }

    @Test func theManifestIsTheFolderFileForFile() throws {
        let manifest = try #require(LampAnimationRuntime.manifest(in: three))
        #expect(manifest.version == "0.187.0")
        var present: Set<String> = []
        let walk = try #require(FileManager.default.enumerator(at: three, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walk where (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true {
            present.insert(String(url.standardizedFileURL.path.dropFirst(three.standardizedFileURL.path.count + 1)))
        }
        #expect(present == Set(manifest.files.keys).union(["LICENSE", "MANIFEST.json"]))
        for (path, digest) in manifest.files {
            let bytes = try Data(contentsOf: three.appendingPathComponent(path))
            #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == digest, "\(path)")
        }
        // Nothing needing a decoder from libs/, and none of what was left out.
        #expect(!manifest.files.keys.contains { $0.contains("/libs/") || $0.contains("/controls/") || $0.hasSuffix("TTFLoader.js") })
    }

    /// Every addon Lamp has, but the WebGPU ones that wait for item 4,
    /// imports without a missing file or an error.
    @Test func everyAddonThatNeedsNoWebGPUImports() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try #require(LampAnimationRuntime.manifest(in: three))
        let addons = manifest.files.keys.filter { path in
            guard path.hasPrefix("examples/jsm/"), path.hasSuffix(".js") else { return false }
            let text = (try? String(contentsOf: three.appendingPathComponent(path), encoding: .utf8)) ?? ""
            return !text.contains("'three/webgpu'") && !text.contains("'three/tsl'") && !text.contains("\"three/webgpu\"") && !text.contains("\"three/tsl\"")
                && !Self.importsWebGPUOnly(path, manifest: manifest)
        }.sorted()
        #expect(addons.count > 100, "\(addons.count)")
        let list = addons.map { "\"three/addons/\($0.dropFirst("examples/jsm/".count))\"" }.joined(separator: ",")
        let result = try await render(page(
            imports: "const loaded = await Promise.all([\(list)].map((p) => import(p)));",
            check: "loaded.length === \(addons.count)"
        ), in: root)
        #expect(try colour(at: (128, 128), of: result.stillURL).greenComponent > 0.8)
    }

    /// Whether `path` imports, however indirectly, a module that imports
    /// three's WebGPU or TSL builds, which the import map gives only later.
    private static func importsWebGPUOnly(_ path: String, manifest: LampAnimationRuntime.Manifest, seen: inout Set<String>) -> Bool {
        guard seen.insert(path).inserted else { return false }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LampBibleMacSupport/Resources/AnimationRuntime/three")
        guard let text = try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8) else { return false }
        if text.contains("'three/webgpu'") || text.contains("'three/tsl'") { return true }
        let relative = try! NSRegularExpression(pattern: #"(?m)^\s*(?:import|export)\b[^;'"]*?from\s*'(\.{1,2}/[^']+)'"#)
        let directory = (path as NSString).deletingLastPathComponent
        for match in relative.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let specifier = String(text[Range(match.range(at: 1), in: text)!])
            let target = ((directory as NSString).appendingPathComponent(specifier) as NSString).standardizingPath
            if importsWebGPUOnly(target, manifest: manifest, seen: &seen) { return true }
        }
        return false
    }

    private static func importsWebGPUOnly(_ path: String, manifest: LampAnimationRuntime.Manifest) -> Bool {
        var seen: Set<String> = []
        return importsWebGPUOnly(path, manifest: manifest, seen: &seen)
    }

    /// Bloom through `EffectComposer` lights the dark beside a bright box.
    @Test func bloomLightsThePixelsBesideABrightBox() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        func scene(bloom: Bool) -> String {
            """
            <!doctype html><html><head></head><body style="margin:0">
            <script type="module">
            import * as THREE from "three";
            import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
            import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
            import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
            import { OutputPass } from "three/addons/postprocessing/OutputPass.js";
            const renderer = new THREE.WebGLRenderer({ preserveDrawingBuffer: true });
            renderer.setSize(innerWidth, innerHeight);
            document.body.appendChild(renderer.domElement);
            const scene = new THREE.Scene();
            scene.background = new THREE.Color(0x000000);
            const camera = new THREE.OrthographicCamera(-1, 1, 1, -1, 0.1, 10);
            camera.position.z = 5;
            scene.add(new THREE.Mesh(new THREE.PlaneGeometry(0.5, 0.5), new THREE.MeshBasicMaterial({ color: 0xffffff })));
            const composer = new EffectComposer(renderer);
            composer.addPass(new RenderPass(scene, camera));
            \(bloom ? "composer.addPass(new UnrealBloomPass(new THREE.Vector2(innerWidth, innerHeight), 2.5, 0.6, 0));" : "")
            composer.addPass(new OutputPass());
            window.lamp = { duration: 1, render() { composer.render(); } };
            </script></body></html>
            """
        }
        // 128 is the middle; the box reaches 32 either side, so 176 is dark.
        let plain = try await render(scene(bloom: false), in: root, name: "plain")
        let bloomed = try await render(scene(bloom: true), in: root, name: "bloomed")
        let dark = try colour(at: (176, 128), of: plain.stillURL).brightnessComponent
        let lit = try colour(at: (176, 128), of: bloomed.stillURL).brightnessComponent
        #expect(dark < 0.05 && lit > dark + 0.15, "dark \(dark), lit \(lit)")
        #expect(try colour(at: (128, 128), of: bloomed.stillURL).brightnessComponent > 0.9)
    }

    /// A page written for the old address gets the same three as `three`.
    @Test func theOldAddressIsTheSameThree() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await render(page(
            imports: """
            import * as A from "/lamp/three.module.min.js";
            import * as B from "three";
            import { Line2 } from "three/examples/jsm/lines/Line2.js";
            """,
            check: "A.Vector3 === B.Vector3 && typeof Line2 === 'function' && B.REVISION === '187'"
        ), in: root)
        #expect(try colour(at: (128, 128), of: result.stillURL).greenComponent > 0.8)
    }

    /// An addon Lamp lacks stops the render, by its name.
    @Test func anAddonLampLacksFailsByName() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await render(page(
                imports: #"import { OrbitControls } from "three/addons/controls/OrbitControls.js";"#, check: "true"
            ), in: root)
            Issue.record("rendered with an addon Lamp lacks")
        } catch {
            #expect(error.localizedDescription.contains("OrbitControls.js"), "\(error.localizedDescription)")
        }
    }

    /// GLTFLoader reads a model from the page's folder.
    @Test func gltfLoaderReadsAModelFromThePagesFolder() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // One triangle, its points in a .bin beside it.
        let points: [Float] = [-1, -1, 0, 1, -1, 0, 0, 1, 0]
        try points.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: root.appendingPathComponent("Assets/tri.bin"))
        try """
        {"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[{"mesh":0}],
         "meshes":[{"primitives":[{"attributes":{"POSITION":0},"material":0}]}],
         "materials":[{"pbrMetallicRoughness":{"baseColorFactor":[0,1,0,1]},"extensions":{"KHR_materials_unlit":{}}}],
         "extensionsUsed":["KHR_materials_unlit"],
         "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[-1,-1,0],"max":[1,1,0]}],
         "bufferViews":[{"buffer":0,"byteLength":36}],"buffers":[{"uri":"tri.bin","byteLength":36}]}
        """.write(to: root.appendingPathComponent("Assets/tri.gltf"), atomically: true, encoding: .utf8)
        let result = try await render("""
        <!doctype html><html><head></head><body style="margin:0">
        <script type="module">
        import * as THREE from "three";
        import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
        const renderer = new THREE.WebGLRenderer({ preserveDrawingBuffer: true });
        renderer.setSize(innerWidth, innerHeight);
        document.body.appendChild(renderer.domElement);
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0xff0000);
        const camera = new THREE.OrthographicCamera(-1.2, 1.2, 1.2, -1.2, 0.1, 10);
        camera.position.z = 5;
        const ready = new GLTFLoader().loadAsync("tri.gltf").then((g) => scene.add(g.scene));
        window.lamp = { duration: 1, ready, render() { renderer.render(scene, camera); } };
        </script></body></html>
        """, in: root)
        let middle = try colour(at: (128, 150), of: result.stillURL)
        #expect(middle.greenComponent > 0.8 && middle.redComponent < 0.3, "\(middle)")
    }

    /// The deck format's example page renders as written.
    @Test func theDeckFormatsExampleRenders() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let guide = try String(
            contentsOf: Self.sources.appendingPathComponent("AgentSkills/build-lamp-deck/references/deck-format.md"), encoding: .utf8
        )
        let start = try #require(guide.range(of: "### An animation: `render_animation`"))
        let rest = guide[start.upperBound...]
        let open = try #require(rest.range(of: "```html\n"))
        let close = try #require(rest[open.upperBound...].range(of: "```"))
        let html = String(rest[open.upperBound..<close.lowerBound])
        let result = try await render(html, in: root, name: "example")
        #expect(result.duration == 12)
    }

    /// The deck skill an agent is given no longer carries three.js; Lamp
    /// serves it.
    @Test func theDeckSkillHasNoCopyOfThree() {
        let skill = Self.sources.appendingPathComponent("AgentSkills/build-lamp-deck")
        #expect(FileManager.default.fileExists(atPath: skill.appendingPathComponent("SKILL.md").path))
        #expect(!FileManager.default.fileExists(atPath: skill.appendingPathComponent("scene").path))
        // And the copy is found where the package keeps it.
        #expect(LampAnimationRuntime.threeFolderURL.flatMap(LampAnimationRuntime.manifest(in:))?.version == "0.187.0")
    }
}
