import AppKit
import AVFoundation
import Foundation
import LampCore

/// Makes a video an agent made, by whatever means, into one a deck can carry:
/// HEVC that looks the same as what it was given, inside the deck's size
/// limit, with its first frame as its still, under names that change whenever
/// the video does (`decisions/0026`).
///
/// An agent can already name any video in a deck, but nothing then checks it:
/// a file too large to sync, or in a codec a phone cannot play, or with no
/// still, or re-made under the same name and so never brought in again.
/// Blender, Manim, a Metal program or a browser can each make the video; this
/// is what Lamp takes back from any of them.
///
/// What it reads is reached from the workspace one folder at a time, never
/// through a link, and copied before anything reads it; a video keeping its
/// pictures or sound in another file is refused on AVFoundation's own word;
/// and what it writes goes into the `Assets` it opened inside the workspace,
/// never through a link. An agent that can write only inside its workspace
/// sees nothing of the rest of the disk through what this returns.
@MainActor
public enum LampVideoPreparation {
    /// What the video is for on a slide, which decides its limit and sound.
    public enum Purpose: String, Sendable {
        /// A picture's moving background: silent, looping.
        case loop
        /// A clip the talk stops to watch, with its sound.
        case clip

        public var largestFileBytes: Int64 {
            switch self {
            case .loop: LampPresentationVideo.largestFileBytes
            case .clip: LampPresentationClip.largestFileBytes
            }
        }
    }

    public struct Result: Sendable {
        public var videoURL: URL
        public var stillURL: URL
        public var bytes: Int64
        public var width: Int
        public var height: Int
        public var seconds: Double
        /// Whether it was made at 1080p to come in under the limit.
        public var reduced: Bool
        /// Whether what it was made from was see-through, which a slide's
        /// video cannot be: it was laid on black.
        public var flattenedTransparency: Bool
        /// A few frames across the video, as JPEG, for whoever made it to
        /// look at.
        public var samples: [(seconds: Double, jpeg: Data)]
        /// For a loop: its last frame, and how far it is from its first, 0
        /// for the same picture to 1 for opposite ones.
        public var seam: (lastFrame: Data, difference: Double)?
    }

    public enum PreparationError: LocalizedError, Equatable {
        case notInWorkspace(String)
        case notAVideo(String)
        case couldNotSave(String)
        case tooLarge(bytes: Int64, limit: Int64, purpose: String, triedSmaller: Bool)
        case outputMoved
        /// Written, but into a folder the session's workspace no longer is.
        case workspaceMoved(folder: String, files: [String])

        public var errorDescription: String? {
            switch self {
            case .notInWorkspace(let path):
                "\(path) is not a file Lamp can reach inside this writing's workspace: name a file there, by a path with no links on the way."
            case .notAVideo(let name):
                "\(name) is not a video Lamp can read on its own: it must be a movie file that holds its own pictures and sound."
            case .couldNotSave(let reason):
                "The video could not be saved: \(reason)"
            case .tooLarge(let bytes, let limit, let purpose, let triedSmaller):
                "\(triedSmaller ? "Even in HEVC at 1080p" : "In HEVC"), this video is "
                    + "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)), over Lamp's "
                    + "\(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) for a \(purpose). "
                    + "Make it shorter or simpler."
            case .outputMoved:
                "The workspace's Assets folder moved, or is a link, so nothing was written."
            case .workspaceMoved(let folder, let files):
                "The workspace moved while the video was made. \(files.joined(separator: " and ")) were written into "
                    + "\(folder), the Assets folder it had when the call began; nothing else was changed."
            }
        }
    }

    /// A loop whose last frame is further than this from its first jumps
    /// where it closes.
    nonisolated public static let seamThreshold = 0.08

    /// The folder in a workspace the video and still are written to, beside
    /// the deck.
    nonisolated public static let assetsFolder = "Assets"

    /// A name for the files made from `source`: its own, in letters, digits,
    /// hyphens and underscores.
    nonisolated static func stem(of source: String) -> String {
        let base = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        var stem = ""
        for scalar in base.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                stem.unicodeScalars.append(scalar)
            } else if stem.last != "-" {
                stem.append("-")
            }
        }
        stem = String(stem.trimmingCharacters(in: CharacterSet(charactersIn: "-_")).prefix(60))
        return stem.isEmpty ? "video" : stem
    }

    /// Prepares the video at `relativePath` in `workspace` as a `purpose`,
    /// into the workspace's `Assets` as `<name>-<fingerprint>.mp4` and `.jpg`.
    ///
    /// For tests: `largestFileBytes` stands in for the purpose's limit,
    /// `reducedShorterSide` for 1080, and `beforePublish` runs just before
    /// the files are written.
    public static func prepare(
        _ relativePath: String,
        in workspace: URL,
        as purpose: Purpose,
        largestFileBytes: Int64? = nil,
        reducedShorterSide: Int = 1_080,
        beforePublish: (() -> Void)? = nil
    ) async throws -> Result {
        let limit = largestFileBytes ?? purpose.largestFileBytes
        let name = (relativePath as NSString).lastPathComponent
        // The workspace as the session names it, held for the whole call.
        let workspaceHandle = open(workspace.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard workspaceHandle >= 0 else { throw PreparationError.outputMoved }
        defer { close(workspaceHandle) }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Off this actor, a large copy holding up no other call, and in this
        // task, so a call given up on stops it.
        let source = try await snapshotAway(relativePath, from: workspaceHandle, into: scratch)
        let video = scratch.appendingPathComponent("video.mp4")
        let still = scratch.appendingPathComponent("still.jpg")

        let assetsHandle = try openAssets(in: workspaceHandle)
        defer { close(assetsHandle) }

        var made: LampVisuallyLosslessVideo.Result
        do {
            made = try await LampVisuallyLosslessVideo.encode(
                source, to: video, keepingSound: purpose == .clip, requiringSelfContained: true
            )
        } catch {
            throw preparationError(for: error, name: name)
        }
        // Too large at up to 4K: made at 1080p, which still looks the same at
        // the size most rooms see it, as Slide Studio offers.
        var reduced = false
        if made.bytes > limit,
           let at1080p = LampVisuallyLosslessVideo.longestSideAt1080p(
               width: made.width, height: made.height, shorterSide: reducedShorterSide
           ) {
            try Task.checkCancellation()
            do {
                made = try await LampVisuallyLosslessVideo.encode(
                    source, to: video, keepingSound: purpose == .clip, largestSide: at1080p, requiringSelfContained: true
                )
            } catch {
                throw preparationError(for: error, name: name)
            }
            reduced = true
        }
        guard made.bytes <= limit else {
            throw PreparationError.tooLarge(
                bytes: made.bytes, limit: limit, purpose: purpose == .loop ? "looping video" : "clip", triedSmaller: reduced
            )
        }

        // Everything shown from here on is read from what was made.
        let asset = AVURLAsset(url: video)
        let seconds = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        func frame(at time: CMTime) async throws -> CGImage {
            try await generator.image(at: time).image
        }
        func frame(at seconds: Double) async throws -> CGImage {
            try await frame(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        }
        let first = try await frame(at: 0)
        try jpeg(first, largestSide: max(first.width, first.height), quality: 0.9).write(to: still, options: .atomic)

        var samples: [(seconds: Double, jpeg: Data)] = [(0, try jpeg(first, largestSide: 640, quality: 0.8))]
        for fraction in [0.25, 0.5, 0.75] {
            let time = seconds * fraction
            samples.append((time, try jpeg(try await frame(at: time), largestSide: 640, quality: 0.8)))
        }
        var seam: (lastFrame: Data, difference: Double)?
        if purpose == .loop, let lastShown = try await lastFrameTime(of: asset) {
            // The frame shown last, found by its own time rather than worked
            // out from the frame rate, so nothing rests on how frames are
            // spaced.
            let last = try await frame(at: lastShown)
            seam = (try jpeg(last, largestSide: 640, quality: 0.8), difference(between: first, and: last))
        }

        try Task.checkCancellation()
        let mark = try LampAnimationRenderer.fingerprint(of: video)
        let stemmed = "\(stem(of: relativePath))-\(mark)"
        let files = ["\(stemmed).mp4", "\(stemmed).jpg"]
        try confirmAssets(assetsHandle, in: workspaceHandle)
        beforePublish?()
        try LampAnimationRenderer.publish([(video, files[0]), (still, files[1])], in: assetsHandle)

        // Where the files went, said as the file system says it.
        let written = path(of: assetsHandle) ?? workspace.appendingPathComponent(assetsFolder).path
        // Still the session's workspace, and its Assets, or the names this
        // returns would lead somewhere else; the files stay, since a deck
        // may already name a fingerprinted name.
        var held = stat(), named = stat()
        guard fstat(workspaceHandle, &held) == 0, stat(workspace.path, &named) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              (try? confirmAssets(assetsHandle, in: workspaceHandle)) != nil
        else { throw PreparationError.workspaceMoved(folder: written, files: files) }
        let destination = URL(fileURLWithPath: written, isDirectory: true)
        return Result(
            videoURL: destination.appendingPathComponent(files[0]),
            stillURL: destination.appendingPathComponent(files[1]),
            bytes: made.bytes, width: made.width, height: made.height, seconds: seconds,
            reduced: reduced, flattenedTransparency: made.seeThrough, samples: samples, seam: seam
        )
    }

    /// What a failed encode means for whoever asked: a file that is not a
    /// video it can read on its own, or one that could not be saved.
    nonisolated static func preparationError(for error: Error, name: String) -> Error {
        switch error {
        case LampVisuallyLosslessVideo.EncodingError.noPictures, LampVisuallyLosslessVideo.EncodingError.notSelfContained:
            return PreparationError.notAVideo(name)
        case LampVisuallyLosslessVideo.EncodingError.failed(let reason):
            return PreparationError.couldNotSave(reason)
        case let error as NSError where error.domain == AVFoundationErrorDomain || error.domain == NSOSStatusErrorDomain:
            // Raised opening the file: it is not one AVFoundation reads.
            return PreparationError.notAVideo(name)
        default:
            return error
        }
    }

    /// A private copy of the file at `relativePath`, reached from the
    /// workspace one folder at a time, each opened without following a
    /// link, the file itself without waiting (a pipe would never answer) and
    /// taken only if it is a plain file. Cloned where the file system can;
    /// otherwise copied, if there is room, a piece at a time.
    nonisolated static func snapshot(_ relativePath: String, from workspace: Int32, into scratch: URL) throws -> URL {
        // Split on the slash scalar, as the kernel splits a path, not on
        // Swift's characters: a slash with a combining mark after it is one
        // character, and the kernel would walk through it, following a link
        // there unchecked. And no NUL, which would end the name the kernel
        // reads before the one checked here.
        let scalars = relativePath.unicodeScalars
        let parts = scalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard !scalars.contains("\0"), scalars.first != "/", !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw PreparationError.notInWorkspace(relativePath) }
        var folder = dup(workspace)
        guard folder >= 0 else { throw PreparationError.outputMoved }
        defer { close(folder) }
        for part in parts.dropLast() {
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw PreparationError.notInWorkspace(relativePath) }
            close(folder)
            folder = next
        }
        let file = openat(folder, parts[parts.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw PreparationError.notInWorkspace(relativePath) }
        defer { close(file) }
        var status = stat()
        guard fstat(file, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw PreparationError.notInWorkspace(relativePath)
        }

        let pathExtension = (relativePath as NSString).pathExtension
        let copyName = pathExtension.isEmpty ? "source" : "source.\(pathExtension)"
        let copy = scratch.appendingPathComponent(copyName)
        let scratchHandle = open(scratch.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scratchHandle >= 0 else { throw PreparationError.couldNotSave("Lamp's working folder could not be opened.") }
        defer { close(scratchHandle) }
        if fclonefileat(file, scratchHandle, copyName, 0) == 0 { return copy }

        var volume = statfs()
        if fstatfs(scratchHandle, &volume) == 0 {
            let free = Int64(volume.f_bavail) * Int64(volume.f_bsize)
            guard free > Int64(status.st_size) + 1_000_000_000 else {
                throw PreparationError.couldNotSave("there is not room on this Mac for a working copy of it.")
            }
        }
        let output = openat(scratchHandle, copyName, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw PreparationError.couldNotSave(String(cString: strerror(errno))) }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw PreparationError.couldNotSave(String(cString: strerror(errno))) }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress! + sent, count - sent) }
                guard wrote > 0 else { throw PreparationError.couldNotSave(String(cString: strerror(errno))) }
                sent += wrote
            }
        }
        return copy
    }

    /// `snapshot`, run off the main actor in the caller's task.
    nonisolated private static func snapshotAway(_ relativePath: String, from workspace: Int32, into scratch: URL) async throws -> URL {
        try snapshot(relativePath, from: workspace, into: scratch)
    }

    /// The workspace's `Assets`, made if missing, and opened as a folder
    /// that is not a link.
    nonisolated private static func openAssets(in workspace: Int32) throws -> Int32 {
        if mkdirat(workspace, assetsFolder, 0o755) != 0, errno != EEXIST { throw PreparationError.outputMoved }
        let handle = openat(workspace, assetsFolder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard handle >= 0 else { throw PreparationError.outputMoved }
        return handle
    }

    /// That `assets` is still the workspace's `Assets`, and not a link.
    nonisolated private static func confirmAssets(_ assets: Int32, in workspace: Int32) throws {
        var held = stat(), named = stat()
        guard fstat(assets, &held) == 0, fstatat(workspace, assetsFolder, &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino
        else { throw PreparationError.outputMoved }
    }

    /// The path the file system gives an open folder, for saying where
    /// things were written.
    nonisolated private static func path(of handle: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(handle, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// When the last frame of `asset` is shown, from its own samples: the
    /// latest sample time less the earliest, since the samples are timed on
    /// the track's own line, which starts later than the video does where
    /// frames are reordered (by two frames, for H.264 with B-frames).
    static func lastFrameTime(of asset: AVURLAsset) async throws -> CMTime? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }
        var first: CMTime?
        var last: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid else { continue }
            if first.map({ time < $0 }) ?? true { first = time }
            if last.map({ time > $0 }) ?? true { last = time }
        }
        guard let first, let last else { return nil }
        return CMTimeSubtract(last, first)
    }

    /// `image` as a JPEG, its longer side at most `largestSide` and never
    /// made larger than it is.
    private static func jpeg(_ image: CGImage, largestSide: Int, quality: Double) throws -> Data {
        let scale = min(1, Double(largestSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: quality])
        else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    /// How far apart two pictures are, 0 to 1: the mean difference of their
    /// colours, each drawn 32 pixels across.
    nonisolated static func difference(between a: CGImage, and b: CGImage) -> Double {
        let width = 32, height = 18
        func pixels(_ image: CGImage) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
                context?.interpolationQuality = .medium
                context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
        let left = pixels(a), right = pixels(b)
        var total = 0
        var count = 0
        for index in stride(from: 0, to: left.count, by: 4) {
            for channel in 0..<3 {
                total += abs(Int(left[index + channel]) - Int(right[index + channel]))
                count += 1
            }
        }
        return Double(total) / Double(count * 255)
    }
}
