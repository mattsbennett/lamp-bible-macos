import AVFoundation
import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

@MainActor
final class ReadAloudController: NSObject, ObservableObject {
    enum State: Equatable {
        case stopped
        case playing
        case paused
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var currentReference: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private var references: [ObjectIdentifier: Int] = [:]
    private var pendingUtterances: Set<ObjectIdentifier> = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(
        items: [ReadAloudItem],
        startingAt reference: Int?,
        voiceIdentifier: String,
        rate: Double
    ) {
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .stopped:
            play(items: items, startingAt: reference, voiceIdentifier: voiceIdentifier, rate: rate)
        }
    }

    func play(
        items: [ReadAloudItem],
        startingAt reference: Int?,
        voiceIdentifier: String,
        rate: Double
    ) {
        stop()
        let queue = ReadAloudQueue(items: items, startingAt: reference)
        let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "en-US")

        for item in queue.remainingItems {
            let utterance = AVSpeechUtterance(string: "Verse \(item.verseNumber). \(item.text)")
            utterance.voice = voice
            utterance.rate = Float(min(max(rate, 0.3), 0.65))
            utterance.preUtteranceDelay = 0.04
            let id = ObjectIdentifier(utterance)
            references[id] = item.reference
            pendingUtterances.insert(id)
            synthesizer.speak(utterance)
        }
        if !pendingUtterances.isEmpty { state = .playing }
    }

    func pause() {
        guard state == .playing, synthesizer.pauseSpeaking(at: .word) else { return }
        state = .paused
    }

    func resume() {
        guard state == .paused, synthesizer.continueSpeaking() else { return }
        state = .playing
    }

    func stop() {
        references.removeAll()
        pendingUtterances.removeAll()
        currentReference = nil
        state = .stopped
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

extension ReadAloudController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            currentReference = references[id]
            state = .playing
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        finish(utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        finish(utterance)
    }

    nonisolated private func finish(_ utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self else { return }
            references.removeValue(forKey: id)
            pendingUtterances.remove(id)
            if pendingUtterances.isEmpty {
                currentReference = nil
                state = .stopped
            }
        }
    }
}
