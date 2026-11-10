import AppKit
import AVFoundation
import Foundation
import LampCore
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
        let voice = SpeechVoices.voice(language: SpeechVoices.english, stored: voiceIdentifier)

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

/// Speaks one quiz card at a time. It deliberately shares the reader's voice and
/// rate preferences, so read-aloud sounds consistent when the quiz is opened
/// beside a plan reading.
@MainActor
final class QuizReadAloudController: NSObject, ObservableObject {
    @Published private(set) var state: ReadAloudController.State = .stopped
    @Published private(set) var currentQuestionID: Int64?

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(
        questionID: Int64,
        text: String,
        voiceIdentifier: String,
        rate: Double
    ) {
        if currentQuestionID == questionID {
            switch state {
            case .playing:
                guard synthesizer.pauseSpeaking(at: .word) else { return }
                state = .paused
                return
            case .paused:
                guard synthesizer.continueSpeaking() else { return }
                state = .playing
                return
            case .stopped:
                break
            }
        }
        play(
            questionID: questionID,
            text: text,
            voiceIdentifier: voiceIdentifier,
            rate: rate
        )
    }

    func play(
        questionID: Int64,
        text: String,
        voiceIdentifier: String,
        rate: Double
    ) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = SpeechVoices.voice(language: SpeechVoices.english, stored: voiceIdentifier)
        utterance.rate = Float(min(max(rate, 0.3), 0.65))
        activeUtteranceID = ObjectIdentifier(utterance)
        currentQuestionID = questionID
        state = .playing
        synthesizer.speak(utterance)
    }

    func stop() {
        activeUtteranceID = nil
        currentQuestionID = nil
        state = .stopped
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

extension QuizReadAloudController: AVSpeechSynthesizerDelegate {
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
            guard let self, activeUtteranceID == id else { return }
            activeUtteranceID = nil
            currentQuestionID = nil
            state = .stopped
        }
    }
}

/// The installed voices, and which one speaks: the reader's Read Aloud
/// choice when it speaks the language, and otherwise the best installed, by
/// core's rule, so the phone chooses alike.
enum SpeechVoices {
    /// The language verses and questions are read in, and the IPA spoken.
    static let english = "en-US"

    /// The installed voices, held until the system says they changed.
    ///
    /// Enumerating them costs about 55 ms on a Mac with 181 voices
    /// installed, and the Settings pane asks three times for every redraw —
    /// the list, the voice Automatic resolves to, and the voice in use — so
    /// opening it, and every slider drag on it, spent a sixth of a second
    /// here before this was held.
    @MainActor
    private static var held: (voices: [AVSpeechSynthesisVoice], described: [LampSpeechVoice])?
    /// Registered once and never removed, so a voice downloaded while the app
    /// is open is still picked up by whatever asks next — the cache would
    /// otherwise outlast the thing it describes.
    @MainActor private static var watching: [any NSObjectProtocol] = []

    @MainActor
    static func installed() -> [LampSpeechVoice] { enumerated().described }

    /// The voices themselves, for a list that shows them.
    @MainActor
    static func all() -> [AVSpeechSynthesisVoice] { enumerated().voices }

    /// Drops what is held. The Settings pane calls this as it redraws on the
    /// same notification, so the order the two observers happen to fire in
    /// cannot leave it drawing a list the system has already changed.
    @MainActor
    static func forget() { held = nil }

    @MainActor
    private static func enumerated()
        -> (voices: [AVSpeechSynthesisVoice], described: [LampSpeechVoice]) {
        if watching.isEmpty {
            // Two, because the first has never been seen to fire here and a
            // cache that misses it is wrong until the app is relaunched —
            // not only in the Settings list but in every speaking path. The
            // second cannot be missed: voices are installed in System
            // Settings, so coming back to Lamp is the one thing a reader who
            // has just downloaded one is certain to do. It costs one
            // enumeration per return to the app, against one per frame.
            watching = [
                AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                NSApplication.didBecomeActiveNotification,
            ].map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { _ in MainActor.assumeIsolated { forget() } }
            }
        }
        if let held { return held }
        let enumerated = AVSpeechSynthesisVoice.speechVoices()
        let answer = (voices: enumerated, described: enumerated.map(describe))
        held = answer
        return answer
    }

    static func describe(_ voice: AVSpeechSynthesisVoice) -> LampSpeechVoice {
        LampSpeechVoice(
            identifier: voice.identifier,
            name: voice.name,
            language: voice.language,
            quality: voice.quality.rawValue,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonal: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }

    @MainActor
    static func voice(language: String, stored: String?) -> AVSpeechSynthesisVoice? {
        let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
        let chosen = LampSpeechVoice.choose(
            language: language,
            stored: stored,
            among: installed(),
            preferredLanguage: preferred,
            systemDefaults: Set([language, preferred].compactMap { AVSpeechSynthesisVoice(language: $0)?.identifier })
        )
        return chosen.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
            ?? AVSpeechSynthesisVoice(language: language)
    }
}
