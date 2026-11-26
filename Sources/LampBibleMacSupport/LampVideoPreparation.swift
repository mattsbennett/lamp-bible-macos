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
        /// Whether what it was made from had sound, and whether the video
        /// made keeps it: a clip keeps its sound, a loop is silent.
        public var sourceHasSound: Bool
        public var keptSound: Bool
        /// When the still was taken, in seconds.
        public var stillAt: Double
        /// Earlier videos and stills made from the same source, by an
        /// earlier prepare, still in `Assets`: names only, for whoever made
        /// them to remove those no deck names.
        public var earlierCopies: [String]
        /// A few frames across the video, as JPEG, for whoever made it to
        /// look at.
        public var samples: [(seconds: Double, jpeg: Data)]
        /// For a loop: where it closes.
        public var seam: Seam?
    }

    /// Where a loop closes: its last frame, and how far that is from its
    /// first.
    public struct Seam: Sendable {
        public var lastFrame: Data
        /// When the last frame is shown, in seconds.
        public var lastAt: Double
        /// How far the last frame is from the first: the mean difference of
        /// their colours, 0 for the same picture to 1 for opposite ones.
        public var difference: Double
        /// Whether the last frame is the first again: the loop then shows
        /// that picture twice running, a stutter. Judged against the step
        /// from the frame before it, so a slow or still loop, whose every
        /// step is small, is not taken for one.
        public var repeatsFirst: Bool
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
    /// `stillAt` is the time the still is taken at, the first frame where
    /// nil, kept within the video.
    ///
    /// For tests: `largestFileBytes` stands in for the purpose's limit,
    /// `reducedShorterSide` for 1080, and `beforePublish` runs just before
    /// the files are written.
    public static func prepare(
        _ relativePath: String,
        in workspace: URL,
        as purpose: Purpose,
        stillAt: Double? = nil,
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
        // The still: the first frame, or the one asked for, within the
        // pictures, which can end before the sound does.
        let lastPicture = try await finalFrameTimes(of: asset)?.last.seconds ?? max(0, seconds - 0.001)
        let stillTime = min(max(stillAt ?? 0, 0), lastPicture)
        let stillFrame = stillTime == 0 ? first : try await frame(at: stillTime)
        try jpeg(stillFrame, largestSide: max(stillFrame.width, stillFrame.height), quality: 0.9).write(to: still, options: .atomic)

        var samples: [(seconds: Double, jpeg: Data)] = [(0, try jpeg(first, largestSide: 640, quality: 0.8))]
        for fraction in [0.25, 0.5, 0.75] {
            let time = seconds * fraction
            samples.append((time, try jpeg(try await frame(at: time), largestSide: 640, quality: 0.8)))
        }
        // A clip holds its last frame when it ends: what the room looks at
        // while the talk goes on, so it is shown too.
        if purpose == .clip, let times = try await finalFrameTimes(of: asset) {
            samples.append((times.last.seconds, try jpeg(try await frame(at: times.last), largestSide: 640, quality: 0.8)))
        }
        let sourceHasSound = await hasSound(source)
        let keptSound = await hasSound(video)
        var seam: Seam?
        if purpose == .loop, let times = try await finalFrameTimes(of: asset) {
            // The frame shown last, found by its own time rather than worked
            // out from the frame rate, so nothing rests on how frames are
            // spaced.
            let last = try await frame(at: times.last)
            let toFirst = difference(between: first, and: last)
            var repeatsFirst = false
            if let beforeLast = times.beforeLast {
                let step = difference(between: try await frame(at: beforeLast), and: last)
                repeatsFirst = repeatsFirstFrame(seam: toFirst, lastStep: step)
            }
            seam = Seam(
                lastFrame: try jpeg(last, largestSide: 640, quality: 0.8), lastAt: times.last.seconds,
                difference: toFirst, repeatsFirst: repeatsFirst
            )
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
        let earlierCopies = Self.earlierCopies(of: stemmed, in: assetsHandle)
        return Result(
            videoURL: destination.appendingPathComponent(files[0]),
            stillURL: destination.appendingPathComponent(files[1]),
            bytes: made.bytes, width: made.width, height: made.height, seconds: seconds,
            reduced: reduced, flattenedTransparency: made.seeThrough,
            sourceHasSound: sourceHasSound, keptSound: keptSound, stillAt: stillTime,
            earlierCopies: earlierCopies, samples: samples, seam: seam
        )
    }

    /// Whether `url` has a sound track that plays and holds its own sound,
    /// read as the encoder reads a source: following no reference.
    private static func hasSound(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
        for track in tracks where (try? await track.load(.isEnabled)) == true {
            if (try? await track.load(.isSelfContained)) == true { return true }
        }
        return false
    }

    /// The other videos and stills in the open folder `assets` named as this
    /// tool names what it makes from the same source, `<stem>-<8 hex>`, less
    /// `current` itself.
    nonisolated static func earlierCopies(of current: String, in assets: Int32) -> [String] {
        guard let dash = current.lastIndex(of: "-") else { return [] }
        let stem = String(current[..<dash])
        let duplicate = dup(assets)
        guard duplicate >= 0, let listing = fdopendir(duplicate) else { return [] }
        defer { closedir(listing) }
        var names: [String] = []
        while let entry = readdir(listing) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            let base = (name as NSString).deletingPathExtension
            let kind = (name as NSString).pathExtension
            guard ["mp4", "jpg"].contains(kind), base != current, base.hasPrefix(stem + "-") else { continue }
            let mark = base.dropFirst(stem.count + 1)
            guard mark.count == 8, mark.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { continue }
            names.append(name)
        }
        return names.sorted()
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
    /// workspace as `LampWorkspaceFiles` reaches a file. Cloned where the
    /// file system can; otherwise copied, if there is room, a piece at a
    /// time.
    nonisolated static func snapshot(_ relativePath: String, from workspace: Int32, into scratch: URL) throws -> URL {
        let file: Int32
        do {
            file = try LampWorkspaceFiles.openPlainFile(relativePath, in: workspace)
        } catch LampWorkspaceFiles.Refusal.workspaceUnreadable {
            throw PreparationError.outputMoved
        } catch {
            throw PreparationError.notInWorkspace(relativePath)
        }
        defer { close(file) }
        let pathExtension = (relativePath as NSString).pathExtension
        let copyName = pathExtension.isEmpty ? "source" : "source.\(pathExtension)"
        let scratchHandle = open(scratch.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard scratchHandle >= 0 else { throw PreparationError.couldNotSave("Lamp's working folder could not be opened.") }
        defer { close(scratchHandle) }
        do {
            try LampWorkspaceFiles.copy(file, to: copyName, in: scratchHandle)
        } catch LampWorkspaceFiles.Refusal.noRoom {
            throw PreparationError.couldNotSave("there is not room on this Mac for a working copy of it.")
        } catch let LampWorkspaceFiles.Refusal.writeFailed(reason) {
            throw PreparationError.couldNotSave(reason)
        }
        return scratch.appendingPathComponent(copyName)
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

    /// Whether a loop's last frame is its first again: nearly the same
    /// picture, and much nearer than the step before it, so a slow or still
    /// loop is not taken for one, nor a real jump after a sharp last step.
    /// A loop holding its first picture over several last frames is not
    /// caught: its last step is nothing.
    nonisolated static func repeatsFirstFrame(seam: Double, lastStep: Double) -> Bool {
        lastStep > 0.001 && seam < 0.01 && seam < lastStep * 0.2
    }

    /// When the last frame of `asset` is shown, from its own samples: the
    /// latest sample time less the earliest, since the samples are timed on
    /// the track's own line, which starts later than the video does where
    /// frames are reordered (by two frames, for H.264 with B-frames).
    static func lastFrameTime(of asset: AVURLAsset) async throws -> CMTime? {
        try await finalFrameTimes(of: asset)?.last
    }

    /// When the last two frames of `asset` are shown, from its own samples,
    /// as `lastFrameTime` finds the last.
    static func finalFrameTimes(of asset: AVURLAsset) async throws -> (beforeLast: CMTime?, last: CMTime)? {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return nil }
        var first: CMTime?
        var last: CMTime?
        var beforeLast: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            guard time.isValid else { continue }
            if first.map({ time < $0 }) ?? true { first = time }
            if last.map({ time > $0 }) ?? true {
                beforeLast = last
                last = time
            } else if time != last, beforeLast.map({ time > $0 }) ?? true {
                beforeLast = time
            }
        }
        guard let first, let last else { return nil }
        return (beforeLast.map { CMTimeSubtract($0, first) }, CMTimeSubtract(last, first))
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

/// Files in a writing's workspace, reached as Lamp reaches them for an agent:
/// from the workspace one folder at a time, the path split on the slash
/// scalar as the kernel splits it and refused with a NUL in it, each folder
/// opened without following a link, the file itself without waiting (a pipe
/// would never answer), and taken only if it is a plain file. What Lamp
/// returns from a file it reached this way can carry nothing from outside the
/// workspace (`decisions/0026`).
public enum LampWorkspaceFiles {
    public enum Refusal: Error, Equatable {
        /// Not a plain file reached by plain folder steps.
        case notReachable
        case workspaceUnreadable
        case noRoom
        case writeFailed(String)
    }

    /// The plain file at `relativePath` under the open folder `workspace`,
    /// open for reading. The caller closes it.
    nonisolated public static func openPlainFile(_ relativePath: String, in workspace: Int32) throws -> Int32 {
        let scalars = relativePath.unicodeScalars
        let parts = scalars.split(separator: "/", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
        guard !scalars.contains("\0"), scalars.first != "/", !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Refusal.notReachable }
        var folder = dup(workspace)
        guard folder >= 0 else { throw Refusal.workspaceUnreadable }
        defer { close(folder) }
        for part in parts.dropLast() {
            let next = openat(folder, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Refusal.notReachable }
            close(folder)
            folder = next
        }
        let file = openat(folder, parts[parts.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Refusal.notReachable }
        var status = stat()
        guard fstat(file, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            close(file)
            throw Refusal.notReachable
        }
        return file
    }

    /// Whether `relativePath` is a plain file in `workspace`, reached so.
    nonisolated public static func exists(_ relativePath: String, in workspace: URL) -> Bool {
        let root = open(workspace.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return false }
        defer { close(root) }
        guard let file = try? openPlainFile(relativePath, in: root) else { return false }
        close(file)
        return true
    }

    /// The open file `file`, cloned or else copied as `name` into the open
    /// folder `folder`, a piece at a time, stopping if the task is.
    nonisolated public static func copy(_ file: Int32, to name: String, in folder: Int32) throws {
        if fclonefileat(file, folder, name, 0) == 0 { return }
        var status = stat()
        var volume = statfs()
        if fstat(file, &status) == 0, fstatfs(folder, &volume) == 0 {
            let free = Int64(volume.f_bavail) * Int64(volume.f_bsize)
            guard free > Int64(status.st_size) + 1_000_000_000 else { throw Refusal.noRoom }
        }
        let output = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Refusal.writeFailed(String(cString: strerror(errno))) }
        defer { close(output) }
        // A copy that stops part way is taken away, not left to look whole.
        var finished = false
        defer { if !finished { unlinkat(folder, name, 0) } }
        var buffer = [UInt8](repeating: 0, count: 4 * 1_024 * 1_024)
        while true {
            if Task.isCancelled { throw CancellationError() }
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw Refusal.writeFailed(String(cString: strerror(errno))) }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress! + sent, count - sent) }
                guard wrote > 0 else { throw Refusal.writeFailed(String(cString: strerror(errno))) }
                sent += wrote
            }
        }
        finished = true
    }

    /// Puts the files a deck names, from `workspace`, at the same paths under
    /// `folder`, for a deck written there to be drawn or checked as if it
    /// stood in the workspace. A picture is cloned or copied; a video or a
    /// clip, which a drawing shows as its still, is only marked as there, by
    /// an empty file. A path not reached is left out, and reads as missing.
    nonisolated public static func bringIn(
        pictures: [String], movies: [String], from workspace: URL, into folder: URL
    ) {
        let root = open(workspace.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return }
        defer { close(root) }
        for (path, keepsContent) in pictures.map({ ($0, true) }) + movies.map({ ($0, false) }) {
            guard LampPresentationDeckValidator.isSafeAssetPath(path),
                  let file = try? openPlainFile(path, in: root) else { continue }
            defer { close(file) }
            let destination = folder.appendingPathComponent(path)
            let parent = destination.deletingLastPathComponent()
            guard (try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)) != nil else { continue }
            let parentHandle = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard parentHandle >= 0 else { continue }
            defer { close(parentHandle) }
            let name = destination.lastPathComponent
            if keepsContent {
                try? copy(file, to: name, in: parentHandle)
            } else {
                let marker = openat(parentHandle, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                if marker >= 0 { close(marker) }
            }
        }
    }

    /// The paths a deck names: pictures, whose content a drawing reads, and
    /// videos and clips, whose presence alone is checked.
    nonisolated public static func paths(in deck: LampPresentationDeck) -> (pictures: [String], movies: [String]) {
        var pictures: [String] = []
        var movies: [String] = []
        for slide in deck.slides {
            for block in slide.blocks where block.kind == .image {
                if let assetPath = block.assetPath { pictures.append(assetPath) }
                if let video = block.video { movies.append(video) }
                if let clip = block.clip?.assetPath { movies.append(clip) }
            }
        }
        return (pictures, movies)
    }
}
