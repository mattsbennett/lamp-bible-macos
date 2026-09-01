import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LampCore
import SwiftUI

struct SlideRemotePairingView: View {
    let pairingCode: String

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Pair Presentation Remote")
                    .font(.title3.weight(.semibold))
                Text("Scan this code in Lamp Bible on your iPhone or iPad.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let image = qrImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 224, height: 224)
                    .accessibilityLabel("Presentation Remote pairing QR code")
            }

            VStack(spacing: 4) {
                Text("Or enter this code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LampPresentationRemotePairing.displayCode(pairingCode))
                    .font(.system(.title3, design: .monospaced, weight: .semibold))
                    .textSelection(.enabled)
                    .accessibilityLabel("Pairing code")
                    .accessibilityValue(LampPresentationRemotePairing.displayCode(pairingCode))
            }

            Label(
                "The session is authenticated and encrypted on your local network.",
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 320)
    }

    private var qrImage: NSImage? {
        guard let payload = LampPresentationRemotePairing.qrPayload(for: pairingCode) else {
            return nil
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: .init(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 224, height: 224))
    }
}
