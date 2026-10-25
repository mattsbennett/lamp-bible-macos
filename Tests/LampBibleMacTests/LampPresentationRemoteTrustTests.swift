import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// What a presenter remembers about the remotes it has paired.
///
/// Two of these are about forgetting rather than remembering, because that is
/// the half that is easy to get almost right: a remote that can no longer
/// connect but can still tell this Mac apart from any other has only half
/// been forgotten.
struct LampPresentationRemoteTrustTests {
    private func store() -> LampPresentationRemoteTrustStore {
        LampPresentationRemoteTrustStore(storage: LampPresentationRemoteTrustMemory())
    }

    @Test func amintedCodeIsRememberedAndUsableAsAFrameKey() throws {
        let trust = store()
        #expect(trust.trustedCodes().isEmpty)

        let minted = trust.remember(clientName: "Matthew's iPhone")
        #expect(trust.trustedCodes() == [minted.deviceCode])
        #expect(trust.remotes().first?.clientName == "Matthew's iPhone")

        // It has to open frames, or the device could never speak again.
        let message = LampPresentationRemoteMessage.command(.init(action: .next))
        let frame = try LampPresentationRemoteSecureFrameCodec.encode(
            message, pairingCode: minted.deviceCode
        )
        var buffer = frame
        #expect(try LampPresentationRemoteSecureFrameCodec.decodeFrames(
            from: &buffer, pairingCode: minted.deviceCode
        ) == [message])
    }

    /// Each device gets its own code, so forgetting one cannot lock out
    /// another.
    @Test func eachDeviceGetsItsOwnCode() {
        let trust = store()
        let phone = trust.remember(clientName: "iPhone")
        let pad = trust.remember(clientName: "iPad")
        #expect(phone.deviceCode != pad.deviceCode)
        #expect(Set(trust.trustedCodes()).count == 2)

        trust.forget(deviceCode: phone.deviceCode)
        #expect(trust.trustedCodes() == [pad.deviceCode])
    }

    /// The presenter's secret is what every paired device recognises it by,
    /// so forgetting one remote must not change it.
    @Test func forgettingOneRemoteLeavesTheOthersRecognisingThePresenter() throws {
        let trust = store()
        let phone = trust.remember(clientName: "iPhone")
        let pad = trust.remember(clientName: "iPad")
        #expect(phone.presenterSecret == pad.presenterSecret)

        trust.forget(deviceCode: phone.deviceCode)

        let challenge = LampPresentationRemotePairing.generateChallenge()
        let hint = try #require(trust.presenterHint(challenge: challenge))
        #expect(LampPresentationRemotePairing.presenterMatches(
            secret: pad.presenterSecret, hint: hint, challenge: challenge
        ))
    }

    /// Forgetting everything mints a new secret, so a device that kept its
    /// copy can no longer even recognise this Mac.
    @Test func forgettingEveryRemoteEndsRecognitionToo() throws {
        let trust = store()
        let old = trust.remember(clientName: "iPhone")

        trust.forgetAll()
        #expect(trust.trustedCodes().isEmpty)

        let challenge = LampPresentationRemotePairing.generateChallenge()
        let hint = try #require(trust.presenterHint(challenge: challenge))
        #expect(
            !LampPresentationRemotePairing.presenterMatches(
                secret: old.presenterSecret, hint: hint, challenge: challenge
            ),
            "a forgotten remote must not go on telling this Mac apart from any other"
        )
    }

    /// The hint is what goes out in the clear, so it must not be the same
    /// twice and must not be the secret.
    @Test func thehintSaysNothingLastingAboutThePresenter() throws {
        let trust = store()
        let minted = trust.remember(clientName: "iPhone")
        let hints = (0..<8).map { _ in
            trust.presenterHint(challenge: LampPresentationRemotePairing.generateChallenge())
        }
        #expect(hints.allSatisfy { $0 != nil })
        #expect(Set(hints.compactMap { $0 }).count == 8)
        #expect(hints.compactMap { $0 }.allSatisfy { $0 != minted.presenterSecret })
    }

    /// What is remembered survives the app being quit, because it is read
    /// back from storage rather than held only in memory.
    @Test func whatIsRememberedIsWrittenDown() throws {
        let storage = LampPresentationRemoteTrustMemory()
        let minted = LampPresentationRemoteTrustStore(storage: storage)
            .remember(clientName: "iPhone")

        let reopened = LampPresentationRemoteTrustStore(storage: storage)
        #expect(reopened.trustedCodes() == [minted.deviceCode])

        let challenge = LampPresentationRemotePairing.generateChallenge()
        let hint = try #require(reopened.presenterHint(challenge: challenge))
        #expect(LampPresentationRemotePairing.presenterMatches(
            secret: minted.presenterSecret, hint: hint, challenge: challenge
        ))
    }

    /// Pairing the same device again replaces its record, so a remote
    /// re-paired after being forgotten is not listed twice.
    @Test func pairingTheSameDeviceAgainReplacesIt() {
        let trust = store()
        let first = trust.remember(clientName: "iPhone")
        let second = trust.remember(clientName: "iPhone")
        #expect(trust.trustedCodes() == [second.deviceCode])
        #expect(!trust.trustedCodes().contains(first.deviceCode))
    }

    /// A device that gave no name still gets remembered; it just has nothing
    /// to show in a list.
    @Test func anunnamedDeviceIsStillRemembered() {
        let trust = store()
        let minted = trust.remember(clientName: "   ")
        #expect(trust.trustedCodes() == [minted.deviceCode])
        #expect(trust.remotes().first?.clientName == nil)
    }
}

/// Working out which code a connection is speaking.
///
/// This is the part of pairing with the most room to be subtly wrong: the
/// codec takes a frame out of the buffer before it discovers whether it can
/// open it, so a careless attempt destroys the frame the next candidate
/// needed — and a frame that has not all arrived decodes to nothing under
/// every code, which must not be read as agreement.
struct LampPresentationRemoteFrameOpenerTests {
    private let session = LampPresentationRemotePairing.generateCode()
    private let device = LampPresentationRemotePairing.generateCode()
    private let message = LampPresentationRemoteMessage.command(.init(action: .next))

    private func frame(under code: String) throws -> Data {
        try LampPresentationRemoteSecureFrameCodec.encode(message, pairingCode: code)
    }

    @Test func adevicePairingByQRIsOpenedUnderTheSessionCode() throws {
        var buffer = try frame(under: session)
        let opened = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(opened.code == session)
        #expect(opened.messages == [message])
        #expect(buffer.isEmpty)
    }

    /// The session code is tried first and fails, which is exactly the case
    /// that would eat the frame if the attempt were made on the buffer.
    @Test func areturningDeviceIsOpenedUnderItsOwnCode() throws {
        var buffer = try frame(under: device)
        let opened = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(opened.code == device)
        #expect(opened.messages == [message])
        #expect(buffer.isEmpty)
    }

    /// Half a frame says nothing about which code it is under, so nothing is
    /// settled and the bytes are kept for the rest to arrive.
    @Test func afameStillArrivingSettlesNothingAndIsKept() throws {
        let whole = try frame(under: device)
        var buffer = whole.prefix(whole.count / 2)
        let opened = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(opened.code == nil, "a frame that has not all arrived must not pick a code")
        #expect(opened.messages.isEmpty)
        #expect(buffer.count == whole.count / 2, "the bytes so far must be kept")

        // The rest arrives and it opens under the right code.
        buffer.append(whole.suffix(from: whole.count / 2))
        let then = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(then.code == device)
        #expect(then.messages == [message])
    }

    @Test func acodeNobodyKnowsOpensNothing() throws {
        var buffer = try frame(under: LampPresentationRemotePairing.generateCode())
        let opened = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(opened.code == nil)
        #expect(opened.messages.isEmpty)
    }

    /// Once the code is settled, a frame that will not open is an error
    /// rather than silence: the connection is speaking something else.
    @Test func afailureAfterTheCodeIsSettledIsAnError() throws {
        var buffer = try frame(under: session)
        #expect(throws: (any Error).self) {
            _ = try LampPresentationRemoteFrameOpener.open(
                buffer: &buffer, settled: device, candidates: [session, device]
            )
        }
    }

    @Test func severalFramesInOneReadAllOpen() throws {
        var buffer = try frame(under: device) + (try frame(under: device))
        let opened = try LampPresentationRemoteFrameOpener.open(
            buffer: &buffer, settled: nil, candidates: [session, device]
        )
        #expect(opened.code == device)
        #expect(opened.messages == [message, message])
        #expect(buffer.isEmpty)
    }
}
