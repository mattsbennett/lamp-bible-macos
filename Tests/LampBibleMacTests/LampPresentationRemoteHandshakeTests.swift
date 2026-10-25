import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// Pairing a remote, from the first scan to being forgotten.
///
/// Each piece is tested on its own elsewhere. What is held here is the
/// sequence: the parts can each be right while the order they run in is
/// wrong, and this is the behaviour someone actually has — scan once, come
/// back tomorrow, be let in without scanning again.
struct LampPresentationRemoteHandshakeTests {
    /// Stands in for the presenter, so a whole exchange can be run without a
    /// network. It knows only what the real host knows at each point.
    private struct Presenter {
        let sessionCode = LampPresentationRemotePairing.generateCode()
        let trust = LampPresentationRemoteTrustStore(
            storage: LampPresentationRemoteTrustMemory()
        )

        /// What goes out in the clear when a device connects.
        func greeting(challenge: String) -> LampPresentationRemoteMessage {
            .hello(
                pairingChallenge: challenge,
                presenterHint: trust.presenterHint(challenge: challenge)
            )
        }

        /// The host's reply to a sealed `pair`, or nil if nothing opened it.
        func answer(
            to sealed: Data,
            challenge: String
        ) throws -> (reply: LampPresentationRemoteMessage, code: String)? {
            var buffer = sealed
            let opened = try LampPresentationRemoteFrameOpener.open(
                buffer: &buffer,
                settled: nil,
                candidates: [sessionCode] + trust.trustedCodes()
            )
            guard let code = opened.code, let message = opened.messages.first else { return nil }
            guard message.pairingCode == code, message.pairingChallenge == challenge else {
                return (.rejected("That pairing code is not correct."), code)
            }
            if code == sessionCode {
                let minted = trust.remember(clientName: message.clientName)
                return (
                    .accepted(
                        deviceCode: minted.deviceCode,
                        presenterSecret: minted.presenterSecret
                    ),
                    code
                )
            }
            return (.accepted(), code)
        }
    }

    /// What the phone keeps between connections.
    private struct Device {
        var deviceCode: String?
        var presenterSecret: String?

        /// Which code to offer: its own when it recognises the presenter.
        func code(forHint hint: String?, challenge: String, scanned: String?) -> String? {
            if let hint, let secret = presenterSecret, let deviceCode,
               LampPresentationRemotePairing.presenterMatches(
                   secret: secret, hint: hint, challenge: challenge
               ) {
                return deviceCode
            }
            return scanned
        }

        func pair(code: String, challenge: String, name: String) throws -> Data {
            try LampPresentationRemoteSecureFrameCodec.encode(
                .init(kind: .pair, clientName: name, pairingCode: code, pairingChallenge: challenge),
                pairingCode: code
            )
        }
    }

    @Test func scannedOnceThenLetInWithoutScanningAgain() throws {
        let presenter = Presenter()
        var phone = Device()

        // First connection: nothing is known, so the person scans the code.
        let first = LampPresentationRemotePairing.generateChallenge()
        let greeting = presenter.greeting(challenge: first)
        #expect(
            phone.code(forHint: greeting.presenterHint, challenge: first, scanned: nil) == nil,
            "a device that has never paired cannot recognise this presenter"
        )

        let offered = try #require(
            phone.code(forHint: greeting.presenterHint, challenge: first, scanned: presenter.sessionCode)
        )
        let answered = try #require(
            try presenter.answer(
                to: try phone.pair(code: offered, challenge: first, name: "Matthew's iPhone"),
                challenge: first
            )
        )
        #expect(answered.reply.kind == .accepted)
        phone.deviceCode = try #require(answered.reply.deviceCode)
        phone.presenterSecret = try #require(answered.reply.presenterSecret)

        // Second connection, another day: no scanning, and the code offered
        // is the device's own rather than the session's.
        let second = LampPresentationRemotePairing.generateChallenge()
        let laterGreeting = presenter.greeting(challenge: second)
        let returning = try #require(
            phone.code(forHint: laterGreeting.presenterHint, challenge: second, scanned: nil),
            "a paired device must recognise the presenter with nothing scanned"
        )
        #expect(returning == phone.deviceCode)
        #expect(returning != presenter.sessionCode)

        let letIn = try #require(
            try presenter.answer(
                to: try phone.pair(code: returning, challenge: second, name: "Matthew's iPhone"),
                challenge: second
            )
        )
        #expect(letIn.reply.kind == .accepted)
        #expect(letIn.code == phone.deviceCode)
        #expect(
            letIn.reply.deviceCode == nil,
            "a device that is already known needs no new code"
        )
    }

    /// A different Mac must not be mistaken for the one this device paired
    /// with, or the device would offer its code to a stranger.
    @Test func anotherPresenterIsNotMistakenForTheOneItPairedWith() throws {
        let paired = Presenter()
        var phone = Device()

        let first = LampPresentationRemotePairing.generateChallenge()
        let answered = try #require(
            try paired.answer(
                to: try phone.pair(code: paired.sessionCode, challenge: first, name: "iPhone"),
                challenge: first
            )
        )
        phone.deviceCode = answered.reply.deviceCode
        phone.presenterSecret = answered.reply.presenterSecret

        let stranger = Presenter()
        let challenge = LampPresentationRemotePairing.generateChallenge()
        let greeting = stranger.greeting(challenge: challenge)
        #expect(
            phone.code(forHint: greeting.presenterHint, challenge: challenge, scanned: nil) == nil,
            "the device must not offer its code to a Mac it has never paired with"
        )
    }

    /// Forgetting everything ends both halves: the device cannot get in, and
    /// cannot tell this Mac apart from any other either.
    @Test func forgettingEveryRemoteShutsTheDeviceOutAndEndsRecognition() throws {
        let presenter = Presenter()
        var phone = Device()

        let first = LampPresentationRemotePairing.generateChallenge()
        let answered = try #require(
            try presenter.answer(
                to: try phone.pair(code: presenter.sessionCode, challenge: first, name: "iPhone"),
                challenge: first
            )
        )
        phone.deviceCode = answered.reply.deviceCode
        phone.presenterSecret = answered.reply.presenterSecret

        presenter.trust.forgetAll()

        let challenge = LampPresentationRemotePairing.generateChallenge()
        let greeting = presenter.greeting(challenge: challenge)
        #expect(
            phone.code(forHint: greeting.presenterHint, challenge: challenge, scanned: nil) == nil,
            "a forgotten device must not go on recognising this Mac"
        )

        // And if it tries its old code anyway, the presenter refuses the
        // frame outright rather than sitting on bytes it cannot read.
        let sealed = try phone.pair(
            code: try #require(phone.deviceCode), challenge: challenge, name: "iPhone"
        )
        #expect(throws: (any Error).self) {
            _ = try presenter.answer(to: sealed, challenge: challenge)
        }
    }

    /// The code a device names has to be the one its frames are sealed under,
    /// so it cannot speak as itself while claiming to be another device.
    @Test func adeviceCannotNameACodeItIsNotSpeakingUnder() throws {
        let presenter = Presenter()
        let challenge = LampPresentationRemotePairing.generateChallenge()
        let sealed = try LampPresentationRemoteSecureFrameCodec.encode(
            .init(
                kind: .pair,
                pairingCode: LampPresentationRemotePairing.generateCode(),
                pairingChallenge: challenge
            ),
            pairingCode: presenter.sessionCode
        )
        let answered = try #require(try presenter.answer(to: sealed, challenge: challenge))
        #expect(answered.reply.kind == .rejected)
        #expect(presenter.trust.trustedCodes().isEmpty, "a refused pairing must remember nothing")
    }

    /// A pairing recorded from one connection must not work on the next.
    @Test func arecordedPairingDoesNotWorkOnALaterConnection() throws {
        let presenter = Presenter()
        let phone = Device()

        let first = LampPresentationRemotePairing.generateChallenge()
        let recorded = try phone.pair(code: presenter.sessionCode, challenge: first, name: "iPhone")

        let second = LampPresentationRemotePairing.generateChallenge()
        let replayed = try #require(try presenter.answer(to: recorded, challenge: second))
        #expect(replayed.reply.kind == .rejected)
        #expect(presenter.trust.trustedCodes().isEmpty)
    }
}
