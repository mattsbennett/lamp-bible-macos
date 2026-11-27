import AVFoundation
import CoreImage
import Foundation
import ImageIO
import VideoToolbox

/// Re-encodes a video in HEVC at a quality where nothing a viewer could see
/// is lost: by quality rather than by a bit rate fixed in advance, so a busy
/// scene gets the bits it needs and a still one does not waste them, in ten
/// bits so a soft gradient does not band, at its own frame rate, no larger
/// than a 4K display shows, and with its sound carried over untouched where
/// it is AAC.
///
/// `quality` was chosen by measuring PSNR against a ProRes source: 4K of soft
/// gradients and small type, panned, with fresh random grain on every frame
/// (the hardest thing there is to compress). At 0.72 its worst frame scored
/// 42.6 dB, above the 40 dB usual for a difference no one can see; 0.65
/// scored 37.7. Without the grain every setting tried scored about 48 dB in
/// under 2 MB a second, so real footage, whose noise is far gentler, comes
/// out far smaller than the worst case.
public enum LampVisuallyLosslessVideo {
    /// The encoder's quality, 0 to 1, for a copy no one can tell apart.
    public static let quality: Float = 0.72

    /// The most pixels across a video needs: a 4K display's width.
    public static let largestPixels = 3_840

    public struct Result: Sendable {
        public var bytes: Int64
        public var width: Int
        public var height: Int
        /// Whether the pictures it read were see-through, which HEVC as
        /// written here is not: they were laid on black.
        public var seeThrough: Bool
    }

    public enum EncodingError: LocalizedError, Equatable {
        case noPictures
        /// A track it would read keeps its media in another file.
        case notSelfContained
        case failed(String)
        /// A frame of a frames folder that can't be used, and why.
        case badFrame(String)

        public var errorDescription: String? {
            switch self {
            case .noPictures: "The video has no pictures Lamp can read."
            case .notSelfContained: "The video keeps its pictures or sound in another file."
            case .failed(let message): "The video could not be saved: \(message)"
            case .badFrame(let reason): reason
            }
        }
    }

    /// The longest side that brings a video to 1080p, its shorter side 1080
    /// pixels, or nil where it is that small already. By the shorter side,
    /// so a square or upright video is made 1080 across too: by the longer
    /// side, a square one was made 1920 square and a 1440 square one not
    /// made smaller at all. `shorterSide` stands in for 1080, for tests.
    public static func longestSideAt1080p(width: Int, height: Int, shorterSide: Int = 1_080) -> Int? {
        let shorter = min(width, height), longer = max(width, height)
        guard shorter > shorterSide else { return nil }
        return Int((Double(longer) * Double(shorterSide) / Double(shorter)).rounded())
    }

    /// Writes `source` to `destination` as an HEVC .mp4, its longer side at
    /// most `largestSide`, keeping its sound where `keepingSound`.
    ///
    /// Where `requiringSelfContained`, a video whose pictures or kept sound
    /// are in another file is refused before anything of it is read, by
    /// AVFoundation's own answer for each track it would read: its
    /// reference restrictions alone still followed a reference from one file
    /// on this Mac to another (`decisions/0026`).
    ///
    /// One encode runs at a time on this Mac (`LampVideoEncodeGate`).
    public static func encode(
        _ source: URL,
        to destination: URL,
        keepingSound: Bool,
        largestSide: Int = largestPixels,
        quality: Float = quality,
        requiringSelfContained: Bool = false
    ) async throws -> Result {
        let ticket = await LampVideoEncodeGate.acquire()
        defer { ticket.release() }
        // Given up on while it waited: its turn passes on, unused.
        try Task.checkCancellation()
        let asset = requiringSelfContained
            ? AVURLAsset(url: source, options: [
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            ])
            : AVURLAsset(url: source)
        // The first picture track that plays, as AVFoundation itself shows
        // a movie: a second track laid over it in the file is not drawn by
        // AVFoundation either (tried, 2026-11-26), so neither is it here.
        var pictures: AVAssetTrack?
        for candidate in try await asset.loadTracks(withMediaType: .video) {
            guard try await candidate.load(.isEnabled), try await candidate.load(.isPlayable) else { continue }
            pictures = candidate
            break
        }
        guard let pictures else { throw EncodingError.noPictures }
        if requiringSelfContained {
            guard try await pictures.load(.isSelfContained) else { throw EncodingError.notSelfContained }
            if keepingSound {
                for track in try await asset.loadTracks(withMediaType: .audio) where try await track.load(.isEnabled) {
                    guard try await track.load(.isSelfContained) else { throw EncodingError.notSelfContained }
                }
            }
        }
        // See-through pictures, on the track read: an alpha channel said
        // outright, or ProRes 4444's 32 bits a pixel.
        var seeThrough = false
        for format in try await pictures.load(.formatDescriptions) {
            if let alpha = CMFormatDescriptionGetExtension(format, extensionKey: "ContainsAlphaChannel" as CFString) as? Bool,
               alpha { seeThrough = true }
            if let depth = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_Depth) as? Int,
               depth == 32 { seeThrough = true }
        }
        let natural = try await pictures.load(.naturalSize)
        let transform = try await pictures.load(.preferredTransform)
        // The bounds the turned picture covers, which a turned size alone
        // gets wrong for any turn but a quarter.
        let shown = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        let scale = min(1, Double(largestSide) / Double(max(shown.width, shown.height)))
        // Even sides, as the encoder needs.
        let width = max(2, Int((Double(shown.width) * scale / 2).rounded()) * 2)
        let height = max(2, Int((Double(shown.height) * scale / 2).rounded()) * 2)
        let frameRate = try await pictures.load(.nominalFrameRate)

        // Turned upright and scaled by Core Image, so what is written is what
        // was shown.
        let composition = try await AVVideoComposition.videoComposition(with: asset) { request in
            let image = request.sourceImage
            let factor = CGFloat(width) / image.extent.width
            let scaled = factor == 1 ? image : image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: factor,
                kCIInputAspectRatioKey: (CGFloat(height) / image.extent.height) / factor,
            ])
            request.finish(with: scaled.cropped(to: CGRect(x: 0, y: 0, width: width, height: height)), context: nil)
        }
        let renderComposition = composition.mutableCopy() as! AVMutableVideoComposition
        renderComposition.renderSize = CGSize(width: width, height: height)

        let reader = try AVAssetReader(asset: asset)
        let pictureOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [pictures], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        ])
        pictureOutput.videoComposition = renderComposition
        pictureOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(pictureOutput) else { throw EncodingError.failed("its pictures cannot be read") }
        reader.add(pictureOutput)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        var compression: [String: Any] = [
            AVVideoQualityKey: quality,
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if frameRate > 0 {
            compression[AVVideoExpectedSourceFrameRateKey] = frameRate
            compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int(frameRate.rounded()) * 2)
        }
        let pictureInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        pictureInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(pictureInput) else { throw EncodingError.failed("HEVC is not available") }
        writer.add(pictureInput)

        // Sound: carried over as it is when it is AAC, else made AAC at a
        // rate where nothing is heard lost.
        var soundPair: (AVAssetReaderOutput, AVAssetWriterInput)?
        var sounds: [AVAssetTrack] = []
        if keepingSound {
            for track in try await asset.loadTracks(withMediaType: .audio) where try await track.load(.isEnabled) {
                sounds.append(track)
            }
        }
        if let first = sounds.first {
            // One AAC track is carried over as it is; several (narration and
            // music, say) are mixed into one, as they play together.
            let formats = try await first.load(.formatDescriptions)
            let isAAC = formats.first.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
            let output: AVAssetReaderOutput
            let input: AVAssetWriterInput
            // At the volume each track is set to play at: carried as the
            // track's own setting where it is copied as it is, and mixed in
            // where it is mixed.
            if isAAC && sounds.count == 1 {
                output = AVAssetReaderTrackOutput(track: first, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
                input.preferredVolume = try await first.load(.preferredVolume)
            } else {
                let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: sounds, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                let mix = AVMutableAudioMix()
                var parameters: [AVMutableAudioMixInputParameters] = []
                for sound in sounds {
                    let level = AVMutableAudioMixInputParameters(track: sound)
                    level.setVolume(try await sound.load(.preferredVolume), at: .zero)
                    parameters.append(level)
                }
                mix.inputParameters = parameters
                mixOutput.audioMix = mix
                output = mixOutput
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 256_000,
                ])
            }
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                soundPair = (output, input)
            }
        }

        guard reader.startReading() else {
            throw EncodingError.failed(reader.error?.localizedDescription ?? "it could not be read")
        }
        guard writer.startWriting() else {
            throw EncodingError.failed(writer.error?.localizedDescription ?? "it could not be written")
        }
        writer.startSession(atSourceTime: .zero)

        // Each side carries its samples across as the writer takes them; a
        // write that fails (a full disk) ends both, since the other may then
        // never be asked for more.
        let transfers = Transfers()
        let carry: @Sendable (AVAssetReaderOutput, AVAssetWriterInput, String) async -> Void = { output, input, label in
            await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
                transfers.add(label, finished)
                let queue = DispatchQueue(label: "lamp.encode.\(label)")
                nonisolated(unsafe) let output = output
                nonisolated(unsafe) let input = input
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        guard !transfers.failed else {
                            transfers.finish(label)
                            return
                        }
                        guard let sample = output.copyNextSampleBuffer() else {
                            input.markAsFinished()
                            transfers.finish(label)
                            return
                        }
                        guard input.append(sample) else {
                            transfers.failAll()
                            return
                        }
                    }
                }
            }
        }
        nonisolated(unsafe) let pictureOutputBox = pictureOutput
        nonisolated(unsafe) let pictureInputBox = pictureInput
        async let picturesDone: Void = carry(pictureOutputBox, pictureInputBox, "pictures")
        if let (output, input) = soundPair {
            nonisolated(unsafe) let soundOutput = output
            nonisolated(unsafe) let soundInput = input
            await carry(soundOutput, soundInput, "sound")
        }
        await picturesDone

        if reader.status == .failed || writer.status == .failed {
            reader.cancelReading()
            let message = writer.error?.localizedDescription ?? reader.error?.localizedDescription
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw EncodingError.failed(message ?? "it stopped being readable")
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw EncodingError.failed(reader.error?.localizedDescription ?? "it stopped being readable")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw EncodingError.failed(writer.error?.localizedDescription ?? "unknown")
        }
        // Read from the file system, not the URL: a URL keeps what it first
        // read, and a second encode to the same one (the 1080p retry)
        // reported the first's size.
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Result(bytes: bytes, width: width, height: height, seeThrough: seeThrough)
    }
}

extension LampVisuallyLosslessVideo {
    /// Writes the pictures at `frames`, in order, to `destination` as a
    /// silent HEVC .mp4 at `framesPerSecond`, as `encode` writes a video:
    /// the same quality, ten bits, its longer side at most `largestSide`,
    /// a see-through picture laid on black. Every frame must be the first's
    /// size; `frameName` names one in a refusal.
    ///
    /// The frames are read from files Lamp copied them to, never where the
    /// agent wrote them. One encode runs at a time (`LampVideoEncodeGate`).
    public static func encodeFrames(
        _ frames: [URL],
        framesPerSecond: Double,
        to destination: URL,
        largestSide: Int = largestPixels,
        quality: Float = quality,
        frameName: (Int) -> String = { "frame \($0 + 1)" }
    ) async throws -> Result {
        guard !frames.isEmpty else { throw EncodingError.noPictures }
        let ticket = await LampVideoEncodeGate.acquire()
        defer { ticket.release() }
        try Task.checkCancellation()

        func picture(_ index: Int) throws -> CGImage {
            guard let source = CGImageSourceCreateWithURL(frames[index] as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw EncodingError.badFrame("\(frameName(index)) is not a picture Lamp can read.") }
            return image
        }
        let first = try picture(0)
        let natural = CGSize(width: first.width, height: first.height)
        let scale = min(1, Double(largestSide) / Double(max(natural.width, natural.height)))
        let width = max(2, Int((Double(natural.width) * scale / 2).rounded()) * 2)
        let height = max(2, Int((Double(natural.height) * scale / 2).rounded()) * 2)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let rate = max(1, Int(framesPerSecond.rounded()))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: quality,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: rate * 2,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(input) else { throw EncodingError.failed("HEVC is not available") }
        writer.add(input)
        guard writer.startWriting() else {
            throw EncodingError.failed(writer.error?.localizedDescription ?? "it could not be written")
        }
        writer.startSession(atSourceTime: .zero)
        func abandon(_ error: Error) -> Error {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            return error
        }

        // Drawn as the video's own encode draws a picture: scaled by Core
        // Image, in the video's colours, over black.
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any])
        let videoColours = CGColorSpace(name: CGColorSpace.itur_709)!
        let timescale: CMTimeScale = 60_000
        func time(_ index: Int) -> CMTime {
            CMTime(value: CMTimeValue((Double(index) * Double(timescale) / framesPerSecond).rounded()), timescale: timescale)
        }
        var seeThrough = false
        var pendingBuffer: CVPixelBuffer?
        for index in frames.indices {
            do {
                try Task.checkCancellation()
            } catch {
                throw abandon(error)
            }
            try autoreleasepool {
                let image: CGImage
                do {
                    image = index == 0 ? first : try picture(index)
                } catch {
                    throw abandon(error)
                }
                guard image.width == first.width, image.height == first.height else {
                    throw abandon(EncodingError.badFrame(
                        "\(frameName(index)) is \(image.width)×\(image.height), and the first frame \(first.width)×\(first.height): every frame must be the same size."
                    ))
                }
                var drawn = CIImage(cgImage: image)
                if !seeThrough, Self.mayBeSeeThrough(image), Self.isSeeThrough(drawn, in: context) { seeThrough = true }
                let factor = CGFloat(width) / drawn.extent.width
                if factor != 1 {
                    drawn = drawn.applyingFilter("CILanczosScaleTransform", parameters: [
                        kCIInputScaleKey: factor,
                        kCIInputAspectRatioKey: (CGFloat(height) / drawn.extent.height) / factor,
                    ])
                }
                let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                drawn = drawn.cropped(to: bounds).composited(over: CIImage(color: .black).cropped(to: bounds))
                guard let pool = adaptor.pixelBufferPool else { throw abandon(EncodingError.failed("its pictures could not be made")) }
                var made: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made else {
                    throw abandon(EncodingError.failed("its pictures could not be made"))
                }
                CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                context.render(drawn, to: buffer, bounds: bounds, colorSpace: videoColours)
                pendingBuffer = buffer
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let buffer = pendingBuffer, adaptor.append(buffer, withPresentationTime: time(index)) else {
                throw abandon(EncodingError.failed(writer.error?.localizedDescription ?? "it could not be written"))
            }
            pendingBuffer = nil
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time(frames.count))
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw EncodingError.failed(writer.error?.localizedDescription ?? "unknown")
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber)?.int64Value ?? 0
        return Result(bytes: bytes, width: width, height: height, seeThrough: seeThrough)
    }

    /// Whether a picture says it has an alpha channel at all.
    static func mayBeSeeThrough(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Whether any of a picture is less than opaque: its least alpha.
    static func isSeeThrough(_ image: CIImage, in context: CIContext) -> Bool {
        let least = image.applyingFilter("CIAreaMinimum", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [UInt8](repeating: 255, count: 4)
        context.render(least, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return pixel[3] < 255
    }
}

/// The two sides of an encode, each finished once, and all of them as soon
/// as either fails.
private final class Transfers: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var done: Set<String> = []
    private var hasFailed = false

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasFailed
    }

    func add(_ label: String, _ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let failedAlready = hasFailed
        if !failedAlready { waiting[label] = continuation } else { done.insert(label) }
        lock.unlock()
        if failedAlready { continuation.resume() }
    }

    func finish(_ label: String) {
        lock.lock()
        let continuation = done.contains(label) ? nil : waiting.removeValue(forKey: label)
        done.insert(label)
        lock.unlock()
        continuation?.resume()
    }

    func failAll() {
        lock.lock()
        hasFailed = true
        let all = waiting
        waiting = [:]
        done.formUnion(all.keys)
        lock.unlock()
        all.values.forEach { $0.resume() }
    }
}

/// One video encode at a time on this Mac, across Lamp and every `lamp-mcp`
/// an agent session runs.
///
/// Test videos of 4K noise at 200 Mbps, encoded several at once, brought the
/// hardware encoder down with the whole Mac (a kernel panic in `dart-ave`,
/// 2026-11-26). Nothing shows ordinary encodes would, but several at once
/// buy nothing a person waits less for, so they take turns: in this
/// process by a queue, and between processes by a lock on a file in the
/// user's temporary folder, which Lamp and its helper share.
public enum LampVideoEncodeGate {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var busy = false
    nonisolated(unsafe) private static var waiting: [CheckedContinuation<Void, Never>] = []
    nonisolated(unsafe) private static var active = 0
    /// The most encodes this process has had running at once, for tests.
    nonisolated(unsafe) static var peak = 0

    static let lockFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("lamp-video-encode.lock").path

    /// A turn at the encoder, given back with `release()`.
    public final class Ticket: @unchecked Sendable {
        private let handle: Int32
        private var released = false
        fileprivate init(handle: Int32) { self.handle = handle }

        public func release() {
            LampVideoEncodeGate.lock.lock()
            guard !released else {
                LampVideoEncodeGate.lock.unlock()
                return
            }
            released = true
            LampVideoEncodeGate.active -= 1
            LampVideoEncodeGate.lock.unlock()
            if handle >= 0 {
                flock(handle, LOCK_UN)
                close(handle)
            }
            LampVideoEncodeGate.lock.lock()
            let next = LampVideoEncodeGate.waiting.isEmpty ? nil : LampVideoEncodeGate.waiting.removeFirst()
            if next == nil { LampVideoEncodeGate.busy = false }
            LampVideoEncodeGate.lock.unlock()
            next?.resume()
        }
    }

    /// Waits for this process's turn, then for every other process's.
    public static func acquire() async -> Ticket {
        await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy {
                waiting.append(turn)
                lock.unlock()
            } else {
                busy = true
                lock.unlock()
                turn.resume()
            }
        }
        let handle = open(lockFile, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if handle >= 0 {
            // Off this thread: another process's encode can take a while.
            await Task.detached { _ = flock(handle, LOCK_EX) }.value
        }
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
        return Ticket(handle: handle)
    }
}
