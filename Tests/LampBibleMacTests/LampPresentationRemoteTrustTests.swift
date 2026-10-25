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

    /// Two devices with the same name are two devices.
    ///
    /// The name is chosen by the device, and phones are called "iPhone" often
    /// enough that matching on it would quietly stop remembering one of them
    /// — and would let anyone who can pair evict a remote by copying its
    /// name.
    @Test func twoDevicesNamedAlikeAreBothRemembered() {
        let trust = store()
        let first = trust.remember(clientName: "iPhone")
        let second = trust.remember(clientName: "iPhone")
        #expect(first.deviceCode != second.deviceCode)
        #expect(Set(trust.trustedCodes()) == Set([first.deviceCode, second.deviceCode]))
    }

    /// Looking at what is remembered must not write anything.
    ///
    /// The presenter host is made when the app launches, so anything it
    /// reads is read before there is a window. A write there would put a
    /// keychain item on every Mac whose owner never uses the remote — and
    /// asking the keychain at all can raise a system prompt, which with no
    /// window on screen is a hang nobody can explain.
    @Test func readingWhatIsRememberedWritesNothing() {
        final class Counting: LampPresentationRemoteTrustStorage {
            var reads = 0
            var writes = 0
            func read() throws -> Data? { reads += 1; return nil }
            func write(_ data: Data) throws { writes += 1 }
            func removeAll() throws {}
        }
        let storage = Counting()
        let store = LampPresentationRemoteTrustStore(storage: storage)

        _ = store.remotes()
        _ = store.trustedCodes()
        _ = store.presenterHint(challenge: LampPresentationRemotePairing.generateChallenge())
        #expect(storage.writes == 0, "nothing is stored until a remote is actually remembered")

        // And the first real pairing does write.
        _ = store.remember(clientName: "iPhone")
        #expect(storage.writes == 1)
    }

    /// A keychain that cannot be read is not an empty keychain.
    ///
    /// This is the one that would have cost the person every remote they had
    /// paired: a locked keychain, a refused ACL, or a differently signed
    /// build, and the store would have written a fresh trust over the top.
    @Test func anunreadableStoreIsNeverWrittenOver() throws {
        let existing = LampPresentationRemoteTrustStore(storage: LampPresentationRemoteTrustMemory())
        let minted = existing.remember(clientName: "iPhone")

        final class Unreadable: LampPresentationRemoteTrustStorage {
            var written: [Data] = []
            func read() throws -> Data? { throw CocoaError(.fileReadNoPermission) }
            func write(_ data: Data) throws { written.append(data) }
            func removeAll() throws {}
        }
        let storage = Unreadable()
        let store = LampPresentationRemoteTrustStore(storage: storage)

        #expect(!store.isReadable)
        #expect(store.trustedCodes().isEmpty, "nothing readable means nothing to offer this run")

        // The point of the test: it must not write.
        _ = store.remember(clientName: "iPad")
        store.forgetAll()
        #expect(storage.written.isEmpty, "an unreadable store must never be written over")

        // And the real data is still there for a run that can read it.
        #expect(existing.trustedCodes() == [minted.deviceCode])
    }

    /// Stored data that cannot be understood is different: nothing will ever
    /// make sense of it, so it is replaced — but the store says so.
    @Test func corruptStoredTrustIsReplacedAndSaidSo() {
        let storage = LampPresentationRemoteTrustMemory(data: Data("not trust at all".utf8))
        let store = LampPresentationRemoteTrustStore(storage: storage)
        #expect(store.trustedCodes().isEmpty)
        #expect(store.isReadable)
        #expect(store.corruptTrustWasReplaced)
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

    /// The counterpart to the incomplete-frame test, and the one that was
    /// missing: a frame that is all here and opens under nothing we know is
    /// a device we do not know, not a device still talking. Swallowing it
    /// would leave the bytes to be retried against every code on every read,
    /// and the buffer would only grow.
    @Test func acompleteFrameUnderAnUnknownCodeIsRefused() throws {
        var buffer = try frame(under: LampPresentationRemotePairing.generateCode())
        #expect(throws: (any Error).self) {
            _ = try LampPresentationRemoteFrameOpener.open(
                buffer: &buffer, settled: nil, candidates: [session, device]
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
