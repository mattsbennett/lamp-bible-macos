import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import LampBibleMacSupport

/// A video saved for a deck: HEVC, upright, no larger than asked, and with
/// its sound only where it is to be heard.
struct LampVisuallyLosslessVideoTests {
    /// A phone's portrait clip: filmed sideways at 640 × 360, marked to be
    /// turned, with a second of silence for its sound.
    private func portraitClipWithSound() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let pictures = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        pictures.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)
        let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: pictures, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
        ])
        writer.add(pictures)
        writer.add(sound)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !pictures.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer!), width: 640, height: 360, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )!
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 180, width: 320, height: 180))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        var silence = [Int16](repeating: 0, count: 44_100)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: silence.count * 2, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: silence.count * 2, flags: 0, blockBufferOut: &block
        )
        CMBlockBufferReplaceDataBytes(with: &silence, blockBuffer: block!, offsetIntoDestination: 0, dataLength: silence.count * 2)
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: silence.count,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
        )
        while !sound.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        sound.append(sample!)
        pictures.markAsFinished()
        sound.markAsFinished()
        await writer.finishWriting()
        return url
    }

    @Test func aClipKeepsItsSoundAndAPictureLoopDoesNotAndBothStayUpright() async throws {
        let source = try await portraitClipWithSound()
        defer { try? FileManager.default.removeItem(at: source) }
        for keepingSound in [true, false] {
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: destination) }
            let result = try await LampVisuallyLosslessVideo.encode(source, to: destination, keepingSound: keepingSound)
            // Upright: the pictures turned, not marked to be.
            #expect(result.width == 360 && result.height == 640)
            let asset = AVURLAsset(url: destination)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            let format = try #require(try await track.load(.formatDescriptions).first)
            #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
            #expect(try await track.load(.preferredTransform) == .identity)
            #expect(try await asset.loadTracks(withMediaType: .audio).count == (keepingSound ? 1 : 0))

            // Its top left still red, as filmed and turned.
            let generator = AVAssetImageGenerator(asset: asset)
            let (image, _) = try await generator.image(at: .zero)
            let corner = try #require(redness(of: image, atX: image.width * 7 / 8, y: image.height / 8))
            #expect(corner > 0.6)
        }
    }

    @Test func aVideoIsMadeNoLargerThanAsked() async throws {
        let source = try await portraitClipWithSound()
        defer { try? FileManager.default.removeItem(at: source) }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }
        let result = try await LampVisuallyLosslessVideo.encode(source, to: destination, keepingSound: false, largestSide: 320)
        #expect(result.height == 320 && result.width == 180)
    }

    /// How red the pixel at x, y from the top left is, 0 to 1.
    private func redness(of image: CGImage, atX x: Int, y: Int) -> Double? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Double(pixel[0]) / 255 - Double(pixel[2]) / 255
    }
}
