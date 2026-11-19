import AppKit
import CoreImage.CIFilterBuiltins
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// Settings for following this Mac's reader chats from a paired iPhone or
/// iPad: whether it may, pairing a device by QR, and the devices paired.
struct AgentRemoteSettingsSection: View {
    @EnvironmentObject private var host: AgentRemoteHost
    @AppStorage(AgentRemoteHost.enabledKey) private var isEnabled = false
    @State private var isPairing = false

    var body: some View {
        Section("Chats on iPhone and iPad") {
            Toggle("Allow chats from paired devices", isOn: $isEnabled)
            Text(
                """
                A paired iPhone or iPad can read your reader chats and carry \
                them on, while Lamp is open on this Mac. The chats run here, \
                with the same library access as a reader chat in a window, \
                and nothing passes through anyone else's servers.
                """
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if isEnabled {
                LabeledContent("Status", value: statusText)
                if !host.canKeepPairings {
                    Label(
                        "Lamp couldn't read its saved devices from the keychain, so a device paired now will need pairing again after Lamp next opens.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                ForEach(host.devices) { device in
                    LabeledContent(device.name ?? "Device") {
                        HStack(spacing: 10) {
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .foregroundStyle(.secondary)
                            Button("Forget") { host.forget(device) }
                        }
                    }
                }
                Button("Pair a Device…") {
                    host.beginPairing()
                    isPairing = true
                }
            }
        }
        .onAppear { host.refreshDevices() }
        .sheet(isPresented: $isPairing, onDismiss: { host.endPairing() }) {
            AgentRemotePairingSheet { isPairing = false }
                .environmentObject(host)
        }
    }

    private var statusText: String {
        switch host.status {
        case .off: "Off"
        case .waiting: "Waiting for a device"
        case .connected: "Connected: \(host.connectedNames.joined(separator: ", "))"
        case .failed(let message): message
        }
    }
}

/// The pairing QR, for the phone's Lamp to scan. Its code pairs one device
/// and is spent; the sheet says so when it has been.
private struct AgentRemotePairingSheet: View {
    @EnvironmentObject private var host: AgentRemoteHost
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Pair an iPhone or iPad")
                .font(.headline)
            if let pairing = host.pairing, !pairing.isClosed {
                if let image = qrImage(for: pairing.code) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .accessibilityLabel("Pairing QR code")
                }
                Text("In Lamp on your iPhone or iPad, open Chats on Mac and scan this code.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(pairing.code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if host.pairing != nil {
                Label("Paired. This code can't be used again.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func qrImage(for code: String) -> NSImage? {
        guard let payload = LampAgentRemoteHandshake.qrPayload(for: code) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: .init(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 220, height: 220))
    }
}
