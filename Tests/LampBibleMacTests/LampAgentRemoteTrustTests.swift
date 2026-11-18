import Foundation
import LampBibleMacSupport
import LampCore
import Testing

/// What this Mac remembers about the devices that may follow its chats, and
/// how long a pairing code is good for.
struct LampAgentRemoteTrustTests {
    private func store(_ memory: LampPresentationRemoteTrustMemory = .init()) -> LampAgentRemoteTrustStore {
        LampAgentRemoteTrustStore(storage: memory)
    }

    @Test func apairedDeviceCanProveItselfAndIsRemembered() throws {
        let memory = LampPresentationRemoteTrustMemory()
        let trust = store(memory)
        #expect(trust.devices().isEmpty)
        #expect(trust.hostSecret() == nil)
        let paired = trust.pair(name: "  Matt’s iPhone ")
        #expect(trust.devices().map(\.name) == ["Matt’s iPhone"])
        #expect(trust.hostSecret() == paired.hostSecret)

        // A device proving itself with the key it was given is let in.
        let start = LampAgentRemoteHandshake.hostStart(hostSecret: trust.hostSecret())
        let device = try LampAgentRemoteHandshake.respond(
            to: start.hello, with: try #require(LampAgentRemoteCredential.device(paired.credential))
        )
        let accepted = try LampAgentRemoteHandshake.accept(device.auth, start: start, candidates: trust.credentials())
        #expect(accepted.credential.kind == .device(id: paired.credential.deviceID))

        // And remembered across a relaunch.
        let again = store(memory)
        #expect(again.devices().map(\.id) == [paired.credential.deviceID])
    }

    @Test func aforgottenDeviceIsRefusedAndTheLastTakesTheSecretWithIt() throws {
        let trust = store()
        let first = trust.pair(name: "iPhone")
        let second = trust.pair(name: "iPhone")
        trust.forget(deviceID: first.credential.deviceID)
        #expect(trust.devices().map(\.id) == [second.credential.deviceID])
        #expect(trust.hostSecret() == second.hostSecret)

        let start = LampAgentRemoteHandshake.hostStart(hostSecret: trust.hostSecret())
        let device = try LampAgentRemoteHandshake.respond(
            to: start.hello, with: try #require(LampAgentRemoteCredential.device(first.credential))
        )
        #expect(throws: LampAgentRemoteError.unknownDevice) {
            try LampAgentRemoteHandshake.accept(device.auth, start: start, candidates: trust.credentials())
        }

        trust.forget(deviceID: second.credential.deviceID)
        #expect(trust.hostSecret() == nil)
        #expect(trust.pair(name: nil).hostSecret != second.hostSecret)
    }

    @Test func anUnreadableKeychainIsNeverOverwritten() {
        final class Locked: LampPresentationRemoteTrustStorage {
            var written: [Data] = []
            func read() throws -> Data? { throw CocoaError(.fileReadNoPermission) }
            func write(_ data: Data) throws { written.append(data) }
            func removeAll() throws {}
        }
        let locked = Locked()
        let trust = LampAgentRemoteTrustStore(storage: locked)
        _ = trust.pair(name: "iPad")
        #expect(!trust.isReadable)
        #expect(locked.written.isEmpty)
    }

    @Test func apairingCodePairsOnceAndClosesAfterFailures() {
        var window = LampAgentRemotePairingWindow(allowedFailures: 3)
        #expect(window.credential != nil)
        window.paired()
        #expect(window.credential == nil)

        var guessed = LampAgentRemotePairingWindow(allowedFailures: 3)
        guessed.failed(); guessed.failed()
        #expect(guessed.credential != nil)
        guessed.failed()
        #expect(guessed.credential == nil)
        #expect(guessed.isClosed)
    }
}
