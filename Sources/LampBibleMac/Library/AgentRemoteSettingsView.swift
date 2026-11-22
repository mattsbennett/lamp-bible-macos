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
            .tint(Color.lampAccentMuted)
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
                if !host.tailnetAddresses.isEmpty {
                    LabeledContent("Over Tailscale") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(host.tailnetAddresses, id: \.self) { address in
                                Text(address.text)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    Text(tailnetNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    /// Lamp's own port is left out of the address, and stays the same; any
    /// other is one the system gave for this launch only.
    private var tailnetNote: String {
        let fixed = host.tailnetAddresses.allSatisfy { $0.port == LampAgentRemoteAddress.defaultPort }
        let which = host.tailnetAddresses.count > 1 ? "either address" : "this address"
        let note = "A paired device on your tailnet can connect to \(which) when it can't find this Mac nearby."
        return fixed ? note : note + " Another app has Lamp's usual port, so the address will change when Lamp next opens."
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
                    .buttonStyle(.lampProminent)
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
