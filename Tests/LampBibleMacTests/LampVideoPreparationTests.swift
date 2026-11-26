import AppKit
import AVFoundation
import Foundation
import Testing
@testable import LampBibleMacSupport

/// A video an agent made by any means, brought in as a deck can carry it.
///
/// Every video here is small, short, plain and at an ordinary bit rate, and
/// the suite runs one test at a time: test videos of 4K noise at 200 Mbps,
/// encoded several at once, once brought this Mac's hardware encoder down
/// with the whole machine (a kernel panic, 2026-11-26). The 1080p step is
/// tested by asking for a smaller size, not by making a larger video.
@MainActor
@Suite(.serialized)
struct LampVideoPreparationTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        return root
    }

    /// Writes a small H.264 video (ProRes 4444, part see-through, where
    /// `seeThrough`) of `frames` frames, each filled with `colour(i)`, or with
    /// a checkerboard moving a square a frame where `pattern`.
    private func makeVideo(
        at url: URL, width: Int = 160, height: Int = 90, fps: Int = 12, frames: Int = 12,
        pattern: Bool = false, seeThrough: Bool = false, times: [CMTime]? = nil, end: CMTime? = nil,
        colour: (Int) -> (UInt8, UInt8, UInt8) = { _ in (255, 0, 0) }
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: seeThrough ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: seeThrough ? [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ] : [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        try #require(writer.startWriting(), "the test video could not be started: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            // Never waits on a writer that has failed.
            while !input.isReadyForMoreMediaData {
                try #require(writer.status == .writing, "the test video stopped: \(String(describing: writer.error))")
                try await Task.sleep(for: .milliseconds(2))
            }
            let pool = try #require(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let (r, g, b) = colour(index)
            for y in 0..<height {
                for x in 0..<width {
                    let p = base + y * row + x * 4
                    p[0] = seeThrough && x < width / 2 ? 0 : 255
                    if pattern {
                        let on: UInt8 = ((x + index * 8) / 8 + y / 8) % 2 == 0 ? 230 : 25
                        p[1] = on; p[2] = on; p[3] = 255 - on
                    } else {
                        p[1] = r; p[2] = g; p[3] = b
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let time = times?[index] ?? CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
            try #require(adaptor.append(pixels, withPresentationTime: time))
        }
        input.markAsFinished()
        if let end { writer.endSession(atSourceTime: end) }
        await writer.finishWriting()
        try #require(writer.status == .completed, "the test video did not finish: \(String(describing: writer.error))")
    }

    /// The video at `url` with its length of tone laid under it, as a .mov,
    /// both tracks copied as they are.
    private func withSound(_ url: URL, volume: Float = 1) async throws -> URL {
        let tone = url.deletingLastPathComponent().appendingPathComponent("tone.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: tone, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000) * 0.3) }
        try file.write(from: buffer)
        // Closed, so its length is written before it is read.
        file.close()

        // An export session fails here, run from a test, so the tracks are
        // copied by hand.
        let output = url.deletingPathExtension().appendingPathExtension("mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var pairs: [(AVAssetReader, AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (file, kind) in [(url, AVMediaType.video), (tone, AVMediaType.audio)] {
            let asset = AVURLAsset(url: file)
            let track = try #require(try await asset.loadTracks(withMediaType: kind).first)
            let hint = try await track.load(.formatDescriptions).first
            let reader = try AVAssetReader(asset: asset)
            let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(trackOutput)
            let input = AVAssetWriterInput(mediaType: kind, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if kind == .audio { input.preferredVolume = volume }
            writer.add(input)
            pairs.append((reader, trackOutput, input))
        }
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (reader, trackOutput, input) in pairs {
            try #require(reader.startReading())
            while let sample = trackOutput.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    try #require(writer.status == .writing)
                    try await Task.sleep(for: .milliseconds(2))
                }
                try #require(input.append(sample))
            }
            input.markAsFinished()
        }
        await writer.finishWriting()
        try #require(writer.status == .completed)
        return output
    }

    private func codec(of url: URL) async throws -> FourCharCode {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        return CMFormatDescriptionGetMediaSubType(format)
    }

    private func prepare(
        _ path: String, in root: URL, as purpose: LampVideoPreparation.Purpose = .loop, stillAt: Double? = nil,
        largestFileBytes: Int64? = nil, reducedShorterSide: Int = 1_080
    ) async throws -> LampVideoPreparation.Result {
        try await LampVideoPreparation.prepare(
            path, in: root, as: purpose, stillAt: stillAt,
            largestFileBytes: largestFileBytes, reducedShorterSide: reducedShorterSide
        )
    }

    private func assets(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Assets").path))
    }

    @Test func anH264VideoComesOutHEVCWithItsStillUnderNamesFromWhatItHolds() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Made by Blender.mp4")
        try await makeVideo(at: source, colour: { $0 < 6 ? (0, 0, 255) : (255, 255, 0) })
        let before = try Data(contentsOf: source)

        let result = try await prepare("Made by Blender.mp4", in: root)
        #expect(try await codec(of: result.videoURL) == kCMVideoCodecType_HEVC)
        #expect(result.videoURL.lastPathComponent.range(of: #"^Made-by-Blender-[0-9a-f]{8}\.mp4$"#, options: .regularExpression) != nil)
        #expect(result.stillURL.deletingPathExtension().lastPathComponent == result.videoURL.deletingPathExtension().lastPathComponent)
        #expect(result.width == 160 && result.height == 90)
        #expect(!result.reduced && !result.flattenedTransparency)
        #expect(result.samples.count == 4)
        // The still is the first frame: blue.
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: result.stillURL)))
        let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(middle.blueComponent > 0.8 && middle.redComponent < 0.2)
        // What it was made from is left as it was.
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func aVideoOverTheLimitIsMadeSmallerAndOneStillOverIsRefusedWithNothingWritten() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("pattern.mp4"), width: 640, height: 360, frames: 6, pattern: true)

        // Asked for 180 lines rather than 1080, so the video stays small.
        let full = try await prepare("pattern.mp4", in: root, reducedShorterSide: 180)
        #expect(full.width == 640 && !full.reduced)
        for name in try assets(root) { try FileManager.default.removeItem(at: root.appendingPathComponent("Assets/\(name)")) }

        let smaller = try await prepare("pattern.mp4", in: root, largestFileBytes: full.bytes - 1, reducedShorterSide: 180)
        #expect(smaller.reduced)
        #expect(smaller.width == 320 && smaller.height == 180)
        #expect(smaller.bytes < full.bytes)

        let left = try assets(root)
        await #expect(throws: LampVideoPreparation.PreparationError.self) {
            try await prepare("pattern.mp4", in: root, largestFileBytes: 1, reducedShorterSide: 180)
        }
        #expect(try assets(root) == left)
    }

    @Test func aSquareVideoIsMadeSmallerByItsShorterSide() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("square.mp4"), width: 480, height: 480, frames: 6, pattern: true)
        let full = try await prepare("square.mp4", in: root, reducedShorterSide: 240)
        let smaller = try await prepare("square.mp4", in: root, largestFileBytes: full.bytes - 1, reducedShorterSide: 240)
        #expect(smaller.reduced)
        #expect(smaller.width == 240 && smaller.height == 240)
    }

    @Test func the1080pStepGoesByTheShorterSide() {
        #expect(LampVisuallyLosslessVideo.longestSideAt1080p(width: 3_840, height: 2_160) == 1_920)
        #expect(LampVisuallyLosslessVideo.longestSideAt1080p(width: 2_160, height: 3_840) == 1_920)
        #expect(LampVisuallyLosslessVideo.longestSideAt1080p(width: 1_440, height: 1_440) == 1_080)
        #expect(LampVisuallyLosslessVideo.longestSideAt1080p(width: 1_920, height: 1_080) == nil)
        #expect(LampVisuallyLosslessVideo.longestSideAt1080p(width: 2_000, height: 1_000) == nil)
    }

    @Test func aClipKeepsItsSoundAndALoopDropsIt() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let silent = root.appendingPathComponent("talk.mp4")
        try await makeVideo(at: silent)
        let source = try await withSound(silent)
        #expect(!(try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)).isEmpty)

        let clip = try await prepare(source.lastPathComponent, in: root, as: .clip)
        #expect(!(try await AVURLAsset(url: clip.videoURL).loadTracks(withMediaType: .audio)).isEmpty)
        #expect(clip.seam == nil)
        #expect(clip.sourceHasSound && clip.keptSound)
        let loop = try await prepare(source.lastPathComponent, in: root)
        #expect((try await AVURLAsset(url: loop.videoURL).loadTracks(withMediaType: .audio)).isEmpty)
        // Said: a loop drops what sound it had.
        #expect(loop.sourceHasSound && !loop.keptSound)
        // And a clip with none says so.
        let soundless = try await prepare("talk.mp4", in: root, as: .clip)
        #expect(!soundless.sourceHasSound && !soundless.keptSound)
    }

    @Test func aSourceOutsideTheWorkspaceThroughALinkOrNotAVideoIsRefused() async throws {
        let root = try folder()
        let outside = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try await makeVideo(at: outside.appendingPathComponent("private.mp4"))
        for path in ["../\(outside.lastPathComponent)/private.mp4", outside.appendingPathComponent("private.mp4").path, "missing.mp4"] {
            await #expect(throws: LampVideoPreparation.PreparationError.notInWorkspace(path)) {
                try await prepare(path, in: root)
            }
        }
        // A link to the file, and a folder linked out of the workspace.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.mp4"), withDestinationURL: outside.appendingPathComponent("private.mp4")
        )
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out"), withDestinationURL: outside)
        for path in ["link.mp4", "out/private.mp4"] {
            await #expect(throws: LampVideoPreparation.PreparationError.notInWorkspace(path)) {
                try await prepare(path, in: root)
            }
        }

        try "not a video".write(to: root.appendingPathComponent("notes.mp4"), atomically: true, encoding: .utf8)
        await #expect(throws: LampVideoPreparation.PreparationError.notAVideo("notes.mp4")) {
            try await prepare("notes.mp4", in: root)
        }
        #expect(try assets(root).isEmpty)
    }

    @Test func aMovieKeepingItsPicturesInAnotherFileIsRefused() async throws {
        let root = try folder()
        let outside = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let elsewhere = outside.appendingPathComponent("private.mp4")
        try await makeVideo(at: elsewhere)
        // A movie in the workspace whose pictures are the file outside it.
        let movie = AVMutableMovie(url: elsewhere)
        try movie.writeHeader(to: root.appendingPathComponent("reference.mov"), fileType: .mov, options: [])
        #expect(!(try await AVURLAsset(url: root.appendingPathComponent("reference.mov")).loadTracks(withMediaType: .video)).isEmpty)
        await #expect(throws: LampVideoPreparation.PreparationError.notAVideo("reference.mov")) {
            try await prepare("reference.mov", in: root)
        }
        #expect(try assets(root).isEmpty)
    }

    @Test func aLinkedAssetsFolderIsNotWrittenThrough() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = try folder()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Assets"), withDestinationURL: outside)
        try await makeVideo(at: root.appendingPathComponent("scene.mp4"))
        await #expect(throws: LampVideoPreparation.PreparationError.outputMoved) {
            try await prepare("scene.mp4", in: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["Assets"])
    }

    @Test func assetsIsMadeWhereThereIsNone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("scene.mp4"))
        let result = try await prepare("scene.mp4", in: root)
        #expect(FileManager.default.fileExists(atPath: result.videoURL.path))
        #expect(result.videoURL.deletingLastPathComponent().lastPathComponent == "Assets")
    }

    @Test func aChangedVideoArrivesUnderNewNames() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scene.mp4")
        try await makeVideo(at: source, colour: { _ in (255, 0, 0) })
        let first = try await prepare("scene.mp4", in: root)
        try FileManager.default.removeItem(at: source)
        try await makeVideo(at: source, colour: { _ in (0, 255, 0) })
        let second = try await prepare("scene.mp4", in: root)
        #expect(first.videoURL != second.videoURL)
        #expect(first.stillURL != second.stillURL)
        #expect(FileManager.default.fileExists(atPath: second.videoURL.path))
    }

    @Test func aLoopThatJumpsWhereItClosesIsReportedAndOneThatDoesNotIsNot() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Red, out to blue and back to red.
        try await makeVideo(at: root.appendingPathComponent("closing.mp4"), frames: 24, colour: { index in
            let away = UInt8(255 - abs(index - 12) * 255 / 12)
            return (255 - away, 0, away)
        })
        try await makeVideo(at: root.appendingPathComponent("jumping.mp4"), frames: 24, colour: { index in
            index < 12 ? (255, 0, 0) : (0, 0, 255)
        })

        let closes = try #require(try await prepare("closing.mp4", in: root).seam)
        let jumps = try #require(try await prepare("jumping.mp4", in: root).seam)
        #expect(closes.difference <= LampVideoPreparation.seamThreshold, "closing loop: \(closes.difference)")
        #expect(jumps.difference > LampVideoPreparation.seamThreshold, "jumping loop: \(jumps.difference)")
        #expect(!closes.repeatsFirst && !jumps.repeatsFirst)
    }

    @Test func aLoopWhoseLastFrameIsItsFirstAgainIsSaidToStutter() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Red to blue, and then red again as the last frame: the frame the
        // loop starts on, shown twice running.
        try await makeVideo(at: root.appendingPathComponent("twice.mp4"), frames: 24, colour: { index in
            let away = index == 23 ? 0 : UInt8(index * 255 / 22)
            return (255 - away, 0, away)
        })
        let seam = try #require(try await prepare("twice.mp4", in: root).seam)
        #expect(seam.repeatsFirst, "seam \(seam.difference)")
        #expect(abs(seam.lastAt - 23.0 / 12) < 0.01, "last frame at \(seam.lastAt)")
    }

    @Test func aSeeThroughVideoIsSaidToBeLaidOnBlack() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("glass.mov"), frames: 3, seeThrough: true)
        #expect(try await prepare("glass.mov", in: root).flattenedTransparency)
    }

    @Test func aTallVideosFramesAreNoLargerThanTheyNeedBe() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("tall.mp4"), width: 80, height: 720, frames: 3)
        for sample in try await prepare("tall.mp4", in: root).samples {
            let rep = try #require(NSBitmapImageRep(data: sample.jpeg))
            #expect(rep.pixelsWide <= 640 && rep.pixelsHigh <= 640)
        }
    }

    @Test func aPipeAFolderOrALinkOnTheWayIsRefusedAtOnce() async throws {
        let root = try folder()
        let outside = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        // A pipe with nobody writing to it: opened and waited on, it would
        // never answer.
        #expect(mkfifo(root.appendingPathComponent("pipe.mp4").path, 0o600) == 0)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("renders"), withIntermediateDirectories: true)
        try await makeVideo(at: root.appendingPathComponent("renders/scene.mp4"))
        // Links that stay inside the workspace are refused too: the walk
        // follows none.
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("inside.mp4"), withDestinationURL: root.appendingPathComponent("renders/scene.mp4")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("again"), withDestinationURL: root.appendingPathComponent("renders")
        )
        for path in ["pipe.mp4", "folder.mp4", "inside.mp4", "again/scene.mp4", "renders/../renders/scene.mp4", "./renders/scene.mp4"] {
            let started = Date()
            await #expect(throws: LampVideoPreparation.PreparationError.notInWorkspace(path)) {
                try await prepare(path, in: root)
            }
            #expect(Date().timeIntervalSince(started) < 1, "\(path) took \(Date().timeIntervalSince(started)) s")
        }
        // And the plain path to it is taken.
        _ = try await prepare("renders/scene.mp4", in: root)
    }

    @Test func aWorkspaceNamedAnyWayItCanBeIsTaken() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("scene.mp4"))
        let real = try #require(realpath(root.path, nil))
        defer { free(real) }
        let resolved = String(cString: real)
        // As the temporary folder names it (/var/…), resolved (/private/var/…),
        // and through the Data volume's own name for it.
        for spelling in [root.path, resolved, "/System/Volumes/Data" + resolved] {
            _ = try await prepare("scene.mp4", in: URL(fileURLWithPath: spelling, isDirectory: true))
        }
    }

    private static let banner = "/System/Library/CoreServices/BluetoothUIService.app/Contents/Resources/Banner-PID-8203-Case-mov/Banner-PID-8203-Case-Loop.mov"

    @Test(.enabled(if: FileManager.default.fileExists(atPath: banner)))
    func anOrdinaryQuickTimeMovieIsTaken() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: Self.banner), to: root.appendingPathComponent("banner.mov"))
        let result = try await prepare("banner.mov", in: root)
        #expect(result.width > 0)
    }

    @Test func aBrokenOrStrangeFileIsRefusedWithoutStopping() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("whole.mp4"))
        let whole = try Data(contentsOf: root.appendingPathComponent("whole.mp4"))
        func box(_ type: String, _ body: Data) -> Data {
            var size = UInt32(8 + body.count).bigEndian
            return Data(bytes: &size, count: 4) + Data(type.utf8) + body
        }
        let files: [String: Data] = [
            "empty.mp4": Data(),
            "truncated.mp4": whole.prefix(min(200, whole.count / 2)),
            // A box saying it is four gigabytes long.
            "huge.mp4": Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("moov".utf8) + Data(repeating: 0, count: 64),
            // A movie naming another movie to play instead.
            "alternate.mov": box("ftyp", Data("qt  ".utf8) + Data(repeating: 0, count: 4))
                + box("moov", box("rmra", box("rmda", box("rdrf",
                    Data(repeating: 0, count: 4) + Data("url ".utf8)
                        + Data([0, 0, 0, 40]) + Data("file:///System/Library/whatever.mov\0\0\0\0\0".utf8))))),
        ]
        for (name, data) in files {
            try data.write(to: root.appendingPathComponent(name))
            await #expect(throws: LampVideoPreparation.PreparationError.notAVideo(name)) {
                try await prepare(name, in: root)
            }
        }
    }

    @Test func transparencyIsJudgedOnTheTrackThatIsRead() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("opaque.mp4"), frames: 3)
        try await makeVideo(at: root.appendingPathComponent("glass.mov"), frames: 3, seeThrough: true)
        // One movie, holding both: a switched-off opaque track first, then
        // the see-through one that plays.
        let output = root.appendingPathComponent("two.mov")
        let movie = AVMutableMovie()
        movie.defaultMediaDataStorage = AVMediaDataStorage(url: output)
        for (file, enabled) in [("opaque.mp4", false), ("glass.mov", true)] {
            let asset = AVURLAsset(url: root.appendingPathComponent(file))
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let added = try #require(movie.addMutableTrack(withMediaType: .video, copySettingsFrom: track, options: nil))
            try added.insertTimeRange(
                CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: track, at: .zero, copySampleData: true
            )
            added.isEnabled = enabled
        }
        try movie.writeHeader(to: output, fileType: .mov, options: .addMovieHeaderToDestination)
        #expect(try await prepare("two.mov", in: root).flattenedTransparency)
        #expect(!(try await prepare("opaque.mp4", in: root).flattenedTransparency))
    }

    @Test func aFailedSaveIsSaidAsOneAndTheSizeMessageNames1080pOnlyWhenTried() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("scene.mp4"))
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        do {
            _ = try await LampVisuallyLosslessVideo.encode(
                root.appendingPathComponent("scene.mp4"), to: locked.appendingPathComponent("out.mp4"), keepingSound: false
            )
            Issue.record("an unwritable destination was written")
        } catch {
            let said = LampVideoPreparation.preparationError(for: error, name: "scene.mp4")
            guard case LampVideoPreparation.PreparationError.couldNotSave = said else {
                Issue.record("an unwritable destination was said to be \(said)")
                return
            }
        }
        let tried = LampVideoPreparation.PreparationError.tooLarge(bytes: 2, limit: 1, purpose: "clip", triedSmaller: true)
        let notTried = LampVideoPreparation.PreparationError.tooLarge(bytes: 2, limit: 1, purpose: "clip", triedSmaller: false)
        #expect(tried.errorDescription?.contains("1080p") == true)
        #expect(notTried.errorDescription?.contains("1080p") == false)
    }

    @Test func theLastFrameIsFoundByItsOwnTime() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Twelve a second, then one last frame at 1.95 s.
        var times = (0..<11).map { CMTime(value: CMTimeValue($0), timescale: 12) }
        times.append(CMTime(value: 1_950, timescale: 1_000))
        try await makeVideo(
            at: root.appendingPathComponent("uneven.mp4"), frames: 12, times: times, end: CMTime(value: 1_960, timescale: 1_000)
        )
        let last = try #require(try await LampVideoPreparation.lastFrameTime(of: AVURLAsset(url: root.appendingPathComponent("uneven.mp4"))))
        #expect(abs(last.seconds - 1.95) < 0.002, "last frame at \(last.seconds)")
    }

    @Test func aWorkspaceMovedUnderTheCallSaysWhereTheFilesWent() async throws {
        let first = try folder()
        let second = try folder()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("lamp-workspace-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: link)
        }
        try await makeVideo(at: first.appendingPathComponent("scene.mp4"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        do {
            _ = try await LampVideoPreparation.prepare("scene.mp4", in: link, as: .loop, beforePublish: {
                try? FileManager.default.removeItem(at: link)
                try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            })
            Issue.record("a moved workspace was not said")
        } catch LampVideoPreparation.PreparationError.workspaceMoved(let written, let files) {
            #expect(files.count == 2)
            #expect(written.hasSuffix("/\(first.lastPathComponent)/Assets"), "said \(written)")
            for file in files {
                #expect(FileManager.default.fileExists(atPath: first.appendingPathComponent("Assets/\(file)").path))
            }
        }
    }

    @Test func twoPreparesTakeTurnsAtTheEncoder() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("one.mp4"))
        try await makeVideo(at: root.appendingPathComponent("two.mp4"), colour: { _ in (0, 255, 0) })
        async let one = prepare("one.mp4", in: root)
        async let two = prepare("two.mp4", in: root)
        _ = try await (one, two)
        #expect(LampVideoEncodeGate.peak == 1)
    }

    @Test func aSlashTheKernelSeesButSwiftDoesNotOrANulIsRefused() async throws {
        let root = try folder()
        let outside = try folder()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        // A slash with a combining mark after it is one Swift character, so
        // a split on characters sees one name where the kernel walks two,
        // through `a`, a link out of the workspace.
        let beyond = "\u{301}b.mp4"
        try await makeVideo(at: outside.appendingPathComponent(beyond))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a"), withDestinationURL: outside)
        try await makeVideo(at: root.appendingPathComponent("scene.mp4"))
        // And a name the kernel reads only to its NUL: "..", out of the
        // workspace, where the check here saw "..x".
        for path in ["a/\(beyond)", "..\0x/\(outside.lastPathComponent)/\(beyond)"] {
            await #expect(throws: LampVideoPreparation.PreparationError.notInWorkspace(path)) {
                try await prepare(path, in: root)
            }
        }
        #expect(try assets(root).isEmpty)
    }

    @Test func aClipsSoundKeepsTheVolumeItIsSetTo() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try await makeVideo(at: root.appendingPathComponent("talk.mp4"))
        let source = try await withSound(root.appendingPathComponent("talk.mp4"), volume: 0.25)
        let clip = try await prepare(source.lastPathComponent, in: root, as: .clip)
        let sound = try #require(try await AVURLAsset(url: clip.videoURL).loadTracks(withMediaType: .audio).first)
        #expect(abs(try await sound.load(.preferredVolume) - 0.25) < 0.01)
    }

    @Test func aRepeatIsNearlyTheSamePictureAfterARealStep() {
        #expect(LampVideoPreparation.repeatsFirstFrame(seam: 0.0002, lastStep: 0.02))
        // A real jump after a sharp last step is a jump, not a repeat.
        #expect(!LampVideoPreparation.repeatsFirstFrame(seam: 0.15, lastStep: 1.0))
        // A slow or still loop, whose every step is small.
        #expect(!LampVideoPreparation.repeatsFirstFrame(seam: 0.0001, lastStep: 0.0005))
    }

    @Test func aClipsFramesEndWithTheOneItHoldsAndTheStillCanBeChosen() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        // Blue for the first half second, yellow after.
        try await makeVideo(at: root.appendingPathComponent("turn.mp4"), colour: { $0 < 6 ? (0, 0, 255) : (255, 255, 0) })
        let clip = try await prepare("turn.mp4", in: root, as: .clip, stillAt: 0.75)
        #expect(clip.samples.count == 5)
        #expect(abs((clip.samples.last?.seconds ?? 0) - 11.0 / 12) < 0.01, "last sample at \(clip.samples.last?.seconds ?? -1)")
        #expect(abs(clip.stillAt - 0.75) < 0.001)
        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: clip.stillURL)))
        let middle = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        #expect(middle.redComponent > 0.8 && middle.blueComponent < 0.3, "the still is not the yellow half: \(middle)")
        // A loop's frames stay four, its last frame being in its seam.
        #expect(try await prepare("turn.mp4", in: root).samples.count == 4)
    }

    @Test func earlierCopiesOfTheSameVideoAreNamed() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scene.mp4")
        try await makeVideo(at: source, colour: { _ in (255, 0, 0) })
        let first = try await prepare("scene.mp4", in: root)
        #expect(first.earlierCopies.isEmpty)
        // Another video's files are not this one's copies.
        try await makeVideo(at: root.appendingPathComponent("scenery.mp4"))
        _ = try await prepare("scenery.mp4", in: root)
        try FileManager.default.removeItem(at: source)
        try await makeVideo(at: source, colour: { _ in (0, 255, 0) })
        let second = try await prepare("scene.mp4", in: root)
        #expect(second.earlierCopies == [first.stillURL.lastPathComponent, first.videoURL.lastPathComponent].sorted())
    }

    @Test func aNameIsMadeOfWhatIsSafeInOne() {
        #expect(LampVideoPreparation.stem(of: "renders/Made by Blender.mp4") == "Made-by-Blender")
        #expect(LampVideoPreparation.stem(of: "מִשְׁכָּן.mp4") == "video")
        #expect(LampVideoPreparation.stem(of: ".lamp-renders/.hidden.mov") == "hidden")
    }
}
