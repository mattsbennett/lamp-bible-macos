import AppKit
import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import LampBibleMacSupport

/// A folder of numbered frames, brought in as a video is. Every frame here is
/// small and few, and the suite runs one test at a time, as the video tests
/// do, for the same reason (`LampVideoPreparationTests`).
@MainActor
@Suite(.serialized)
struct LampVideoFramesTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return root
    }

    /// Writes a PNG of `width` by `height` filled with `colour`, at `alpha`.
    private func writeFrame(
        _ url: URL, width: Int = 160, height: Int = 90, colour: (UInt8, UInt8, UInt8), alpha: UInt8 = 255, as type: UTType = .png
    ) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            // Premultiplied.
            pixels[index * 4] = UInt8(Int(colour.0) * Int(alpha) / 255)
            pixels[index * 4 + 1] = UInt8(Int(colour.1) * Int(alpha) / 255)
            pixels[index * 4 + 2] = UInt8(Int(colour.2) * Int(alpha) / 255)
            pixels[index * 4 + 3] = alpha
        }
        let image = try #require(pixels.withUnsafeMutableBytes { bytes -> CGImage? in
            CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func frames(
        _ count: Int, in root: URL, folder: String = ".lamp-renders/scene", name: (Int) -> String = { String(format: "frame%04d.png", $0 + 1) },
        colour: (Int) -> (UInt8, UInt8, UInt8) = { $0 < 6 ? (255, 0, 0) : (0, 0, 255) }
    ) throws {
        for index in 0..<count {
            try writeFrame(root.appendingPathComponent("\(folder)/\(name(index))"), colour: colour(index))
        }
    }

    private func prepare(
        _ folder: String = ".lamp-renders/scene", fps: Double = 6, in root: URL, as purpose: LampVideoPreparation.Purpose = .loop
    ) async throws -> LampVideoPreparation.Result {
        try await LampVideoPreparation.prepare(from: .frames(folder: folder, framesPerSecond: fps), in: root, as: purpose)
    }

    private func assets(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path))
    }

    private func colour(_ jpeg: Data) throws -> NSColor {
        let rep = try #require(NSBitmapImageRep(data: jpeg))
        return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func refusal(_ root: URL, _ folder: String = ".lamp-renders/scene", fps: Double = 6) async -> String? {
        do {
            _ = try await prepare(folder, fps: fps, in: root)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func numberedFramesComeOutAsAVideoAtTheirRate() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Twelve frames at six a second, red then blue, numbered from 1.
        try frames(12, in: root)
        let result = try await prepare(in: root)

        let track = try #require(try await AVURLAsset(url: result.videoURL).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(abs(result.seconds - 2) < 0.01, "seconds \(result.seconds)")
        #expect(result.width == 160 && result.height == 90)
        #expect(result.videoURL.lastPathComponent.range(of: #"^scene-[0-9a-f]{8}\.mp4$"#, options: .regularExpression) != nil)
        #expect(!result.sourceHasSound && !result.keptSound && !result.flattenedTransparency)
        // Each frame where it was: red at the start, blue three quarters in.
        let first = try colour(result.samples[0].jpeg)
        #expect(first.redComponent > 0.8 && first.blueComponent < 0.2, "\(first)")
        let late = try colour(try #require(result.samples.first { abs($0.seconds - 1.5) < 0.01 }).jpeg)
        #expect(late.blueComponent > 0.8 && late.redComponent < 0.2, "\(late)")
        // The last frame shown is the twelfth, blue, and it jumps from the first.
        let seam = try #require(result.seam)
        #expect(abs(seam.lastAt - 11.0 / 6) < 0.01, "last at \(seam.lastAt)")
        #expect(seam.difference > LampVideoPreparation.seamThreshold)
    }

    @Test func framesNumberedFromZeroOrUnevenlyPaddedAreTaken() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // 8, 9, 10, 11: Blender's padding, wider past 9 as some tools write.
        try frames(4, in: root, name: { "shot_\($0 + 8).png" })
        // A hidden file beside them is left alone.
        try Data().write(to: root.appendingPathComponent(".lamp-renders/scene/.DS_Store"))
        let result = try await prepare(fps: 2, in: root)
        #expect(abs(result.seconds - 2) < 0.01)
    }

    @Test func aGapATwiceWrittenFrameOrAnythingElseInTheFolderIsRefusedWithNothingWritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try frames(6, in: root, name: { String(format: "frame%04d.png", $0 < 3 ? $0 + 1 : $0 + 2) })
        #expect(await refusal(root)?.contains("Frame 4 is missing") == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        try frames(3, in: root)
        try writeFrame(root.appendingPathComponent(".lamp-renders/scene/frame2.png"), colour: (0, 255, 0))
        #expect(await refusal(root)?.contains("Frame 2 is in") == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        try frames(3, in: root)
        try Data("notes".utf8).write(to: root.appendingPathComponent(".lamp-renders/scene/notes.txt"))
        #expect(await refusal(root)?.contains("notes.txt") == true)

        // Two runs in one folder.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        try frames(3, in: root)
        try frames(3, in: root, name: { String(format: "matte%04d.png", $0 + 1) })
        #expect(await refusal(root)?.contains("one run of numbered frames") == true)

        // One frame, or a rate out of range.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        try frames(1, in: root)
        #expect(await refusal(root)?.contains("at least two") == true)
        try frames(3, in: root)
        #expect(await refusal(root, fps: 0)?.contains("frame rate") == true)
        #expect(await refusal(root, fps: 500)?.contains("frame rate") == true)

        #expect(try assets(root).isEmpty)
    }

    @Test func aFrameOfAnotherSizeOrNotAPictureIsRefusedByName() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try frames(3, in: root)
        try writeFrame(root.appendingPathComponent(".lamp-renders/scene/frame0004.png"), width: 80, height: 90, colour: (0, 0, 0))
        let sized = await refusal(root)
        #expect(sized?.contains("frame0004.png is 80×90") == true, "\(sized ?? "taken")")

        try Data("not a picture".utf8).write(to: root.appendingPathComponent(".lamp-renders/scene/frame0004.png"))
        let broken = await refusal(root)
        #expect(broken?.contains("frame0004.png is not a picture") == true, "\(broken ?? "taken")")
        #expect(try assets(root).isEmpty)
    }

    @Test func aLinkedFolderOrALinkedFrameIsRefused() async throws {
        let root = try folder()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try frames(3, in: outside, folder: "elsewhere")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".lamp-renders"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".lamp-renders/scene"), withDestinationURL: outside.appendingPathComponent("elsewhere")
        )
        #expect(await refusal(root)?.contains("not a file Lamp can reach") == true)

        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders/scene"))
        try frames(2, in: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".lamp-renders/scene/frame0003.png"),
            withDestinationURL: outside.appendingPathComponent("elsewhere/frame0003.png")
        )
        #expect(await refusal(root)?.contains("frame0003.png") == true)
        // A path out of the workspace.
        #expect(await refusal(root, "../\(outside.lastPathComponent)/elsewhere")?.contains("not a file Lamp can reach") == true)
        #expect(try assets(root).isEmpty)
    }

    @Test func seeThroughFramesAreSaidToBeLaidOnBlackAndOpaqueOnesAreNot() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // PNGs with an alpha channel, all opaque: not see-through.
        try frames(3, in: root)
        #expect(!(try await prepare(in: root).flattenedTransparency))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        for name in try assets(root) { try FileManager.default.removeItem(at: root.appendingPathComponent("Assets/\(name)")) }
        // Half see-through green: laid on black, so darker green.
        for index in 0..<3 {
            try writeFrame(root.appendingPathComponent(String(format: ".lamp-renders/scene/frame%04d.png", index + 1)), colour: (0, 255, 0), alpha: 128)
        }
        let result = try await prepare(in: root)
        #expect(result.flattenedTransparency)
        let shown = try colour(result.samples[0].jpeg)
        #expect(shown.greenComponent > 0.3 && shown.greenComponent < 0.85 && shown.redComponent < 0.15, "\(shown)")
    }

    @Test func jpegFramesAreTaken() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<3 {
            try writeFrame(root.appendingPathComponent(String(format: ".lamp-renders/scene/f%03d.jpg", index)), colour: (255, 0, 0), as: .jpeg)
        }
        let result = try await prepare(fps: 30, in: root, as: .clip)
        #expect(abs(result.seconds - 0.1) < 0.01, "seconds \(result.seconds)")
        #expect(!result.keptSound)
    }

    /// A frame tagged to be turned is turned; one only partly written is
    /// refused by name; a frame an odd pixel off even is scaled, not padded.
    @Test func framesAreTurnedUprightAndMustBeWhole() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Stored 160 by 90, tagged to be shown turned a quarter: 90 by 160.
        for index in 0..<3 {
            let url = root.appendingPathComponent(String(format: ".lamp-renders/scene/f%03d.jpg", index))
            try writeFrame(url, colour: (255, 0, 0), as: .jpeg)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let data = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImagePropertyOrientation: 6] as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: url)
        }
        let turned = try await prepare(in: root)
        #expect(turned.width == 90 && turned.height == 160, "\(turned.width)×\(turned.height)")

        // Cut short, as one copied before its renderer finished: a busy
        // picture, so what is there still decodes, at full size.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".lamp-renders"))
        for index in 0..<3 {
            var g = SystemRandomNumberGenerator()
            let width = 320, height = 180
            var pixels = (0..<(width * height * 4)).map { $0 % 4 == 3 ? UInt8(255) : UInt8.random(in: 0...255, using: &g) }
            let image = try #require(pixels.withUnsafeMutableBytes { bytes -> CGImage? in
                CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
            })
            let url = root.appendingPathComponent(String(format: ".lamp-renders/scene/f%03d.jpg", index))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        let last = root.appendingPathComponent(".lamp-renders/scene/f002.jpg")
        let whole = try Data(contentsOf: last)
        try whole.prefix(whole.count * 7 / 10).write(to: last)
        let cut = await refusal(root)
        #expect(cut?.contains("f002.jpg is not whole") == true, "\(cut ?? "taken")")
    }

    @Test func aFrameAnOddPixelOffIsScaledToTheEvenSize() {
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1081))
        let made = LampVisuallyLosslessVideo.scaled(image, toWidth: 1920, height: 1082)
        #expect(made.extent.width.rounded() == 1920 && made.extent.height.rounded() == 1082, "\(made.extent)")
        let halved = LampVisuallyLosslessVideo.scaled(image, toWidth: 960, height: 540)
        #expect(halved.extent.width.rounded() == 960 && halved.extent.height.rounded() == 540, "\(halved.extent)")
    }
}
