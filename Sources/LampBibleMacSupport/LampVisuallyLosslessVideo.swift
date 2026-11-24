import AVFoundation
import CoreImage
import Foundation
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
    }

    public enum EncodingError: LocalizedError {
        case noPictures
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .noPictures: "The video has no pictures Lamp can read."
            case .failed(let message): "The video could not be saved: \(message)"
            }
        }
    }

    /// Writes `source` to `destination` as an HEVC .mp4, its longer side at
    /// most `largestSide`, keeping its sound where `keepingSound`.
    public static func encode(
        _ source: URL,
        to destination: URL,
        keepingSound: Bool,
        largestSide: Int = largestPixels,
        quality: Float = quality
    ) async throws -> Result {
        let asset = AVURLAsset(url: source)
        var pictures: AVAssetTrack?
        for candidate in try await asset.loadTracks(withMediaType: .video) {
            guard try await candidate.load(.isEnabled), try await candidate.load(.isPlayable) else { continue }
            pictures = candidate
            break
        }
        guard let pictures else { throw EncodingError.noPictures }
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
            if isAAC && sounds.count == 1 {
                output = AVAssetReaderTrackOutput(track: first, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formats.first)
            } else {
                output = AVAssetReaderAudioMixOutput(audioTracks: sounds, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
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
        let bytes = ((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        return Result(bytes: bytes, width: width, height: height)
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
