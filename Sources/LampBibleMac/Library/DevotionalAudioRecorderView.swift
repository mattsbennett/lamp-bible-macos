import AVFoundation
import LampCore
import SwiftUI

struct DevotionalAudioRecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel
    @StateObject private var recorder = DevotionalAudioRecorder()
    @State private var isSaving = false
    @State private var errorMessage: String?

    let devotionalID: String
    let onStored: (URL) -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "mic.circle")
                .font(.system(size: 64))
                .foregroundStyle(recorder.isRecording ? Color.red : Color.accentColor)
                .symbolEffect(.pulse, isActive: recorder.isRecording)

            Text(recorder.formattedDuration)
                .font(.system(.title, design: .monospaced).monospacedDigit())

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            } else if recorder.recordedURL == nil {
                Text("Record a prayer, reflection, or spoken devotional attachment.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Recording ready").foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") {
                    recorder.discard()
                    dismiss()
                }
                Spacer()
                if recorder.recordedURL != nil, !recorder.isRecording {
                    Button("Record Again", systemImage: "arrow.counterclockwise") {
                        startRecording()
                    }
                    Button(isSaving ? "Saving…" : "Use Recording", systemImage: "checkmark") {
                        useRecording()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                } else {
                    Button(
                        recorder.isRecording ? "Stop" : "Record",
                        systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                    ) {
                        recorder.isRecording ? recorder.stop() : startRecording()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
        .frame(width: 480, height: 360)
        .interactiveDismissDisabled(recorder.isRecording || isSaving)
    }

    private func startRecording() {
        Task {
            do {
                try await recorder.start()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func useRecording() {
        guard let sourceURL = recorder.recordedURL else { return }
        isSaving = true
        Task {
            do {
                let storedURL = try await model.library.storePersonalDevotionalMedia(
                    from: sourceURL,
                    devotionalID: devotionalID
                )
                onStored(storedURL)
                recorder.discard()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

@MainActor
private final class DevotionalAudioRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordedURL: URL?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    var formattedDuration: String {
        let seconds = Int(duration)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func start() async throws {
        discard()
        guard await microphoneAccess() else { throw DevotionalRecordingError.permissionDenied }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devotional-recording-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw DevotionalRecordingError.couldNotStart
        }
        self.recorder = recorder
        recordedURL = url
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.duration = self?.recorder?.currentTime ?? 0
            }
        }
    }

    func stop() {
        recorder?.stop()
        timer?.invalidate()
        timer = nil
        duration = recorder?.currentTime ?? duration
        isRecording = false
    }

    func discard() {
        stop()
        recorder = nil
        if let recordedURL { try? FileManager.default.removeItem(at: recordedURL) }
        recordedURL = nil
        duration = 0
    }

    private func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

private enum DevotionalRecordingError: LocalizedError {
    case permissionDenied
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Microphone access is disabled. Enable it for Lamp Bible in System Settings → Privacy & Security → Microphone."
        case .couldNotStart:
            "The Mac could not start an audio recording."
        }
    }
}
