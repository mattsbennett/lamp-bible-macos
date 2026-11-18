import Foundation
import LampCore

/// The phones and tablets this Mac lets follow and continue its reader
/// chats, and the secret it is recognised by.
///
/// In the keychain, never in the library, which syncs: a device key is as
/// good as a password to this Mac's chats. Kept apart from the slide
/// remote's: pairing a remote to turn slides is not leave to read chats.
public struct LampAgentRemoteTrust: Codable, Equatable, Sendable {
    /// Identifies this Mac to the devices it has paired, through the hint on
    /// each hello. Never a key for traffic.
    public var hostSecret: String
    public var devices: [LampAgentRemotePairedDevice]

    public init(
        hostSecret: String = LampAgentRemoteHandshake.generateHostSecret(),
        devices: [LampAgentRemotePairedDevice] = []
    ) {
        self.hostSecret = hostSecret
        self.devices = devices
    }
}

public struct LampAgentRemotePairedDevice: Codable, Equatable, Identifiable, Sendable {
    public var credential: LampAgentRemoteDeviceCredential
    /// What the device called itself when it paired, if anything.
    public var name: String?
    public var pairedAt: Date

    public var id: String { credential.deviceID }

    public init(credential: LampAgentRemoteDeviceCredential, name: String?, pairedAt: Date) {
        self.credential = credential
        self.name = name
        self.pairedAt = pairedAt
    }
}

public final class LampAgentRemoteTrustStore {
    public static let keychainService = "com.neus.Lamp-Bible.agent-remote"

    private let storage: any LampPresentationRemoteTrustStorage
    private var cached: LampAgentRemoteTrust?
    private var readable = true
    private let lock = NSLock()

    public init(storage: any LampPresentationRemoteTrustStorage) {
        self.storage = storage
    }

    public convenience init() {
        self.init(storage: LampPresentationRemoteKeychain(service: Self.keychainService))
    }

    /// Whether what is remembered could be read this run. False means nothing
    /// is written, so an unreadable keychain is never overwritten.
    public var isReadable: Bool { lock.withLock { _ = trust(); return readable } }

    private func trust() -> LampAgentRemoteTrust {
        if let cached { return cached }
        let stored: Data?
        do {
            stored = try storage.read()
        } catch {
            readable = false
            let fallback = LampAgentRemoteTrust()
            cached = fallback
            return fallback
        }
        // Read without writing: a Mac nobody has paired a device with has
        // nothing worth keeping, and looking should not put an item in the
        // keychain of everyone who never uses this.
        let decoded = stored.flatMap { try? JSONDecoder().decode(LampAgentRemoteTrust.self, from: $0) }
        let current = decoded ?? LampAgentRemoteTrust()
        cached = current
        return current
    }

    private func persist(_ trust: LampAgentRemoteTrust) {
        cached = trust
        guard readable, let data = try? JSONEncoder().encode(trust) else { return }
        try? storage.write(data)
    }

    public func devices() -> [LampAgentRemotePairedDevice] {
        lock.withLock { trust().devices.sorted { $0.pairedAt > $1.pairedAt } }
    }

    /// This Mac's secret, for the hint on a hello. Nil while no device has
    /// paired, when there is nobody to recognise it.
    public func hostSecret() -> String? {
        lock.withLock { trust().devices.isEmpty ? nil : trust().hostSecret }
    }

    /// The keys a device that has paired before may prove itself with.
    public func credentials() -> [LampAgentRemoteCredential] {
        lock.withLock { trust().devices.compactMap { LampAgentRemoteCredential.device($0.credential) } }
    }

    public func device(id: String) -> LampAgentRemotePairedDevice? {
        lock.withLock { trust().devices.first { $0.id == id } }
    }

    /// Mints a device its key and remembers it, returning what goes back to
    /// it inside the sealed `accepted`.
    ///
    /// Pairing the same device again adds a record rather than replacing one:
    /// the name comes from the device, and matching on it would let anything
    /// that can pair evict a device by copying its name.
    public func pair(name: String?, now: Date = Date()) -> (credential: LampAgentRemoteDeviceCredential, hostSecret: String) {
        lock.withLock {
            var current = trust()
            let credential = LampAgentRemoteDeviceCredential.generate()
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            current.devices.append(LampAgentRemotePairedDevice(
                credential: credential,
                name: trimmed?.isEmpty == false ? String(trimmed!.prefix(80)) : nil,
                pairedAt: now
            ))
            persist(current)
            return (credential, current.hostSecret)
        }
    }

    /// Names a device by what it calls itself, once it says.
    public func rename(deviceID: String, name: String) {
        lock.withLock {
            var current = trust()
            guard let index = current.devices.firstIndex(where: { $0.id == deviceID }) else { return }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, current.devices[index].name != trimmed else { return }
            current.devices[index].name = String(trimmed.prefix(80))
            persist(current)
        }
    }

    /// Stops letting one device in. Its connection, if open, is the host's to
    /// close.
    public func forget(deviceID: String) {
        lock.withLock {
            var current = trust()
            current.devices.removeAll { $0.id == deviceID }
            // The last device gone, nothing can recognise this Mac any more,
            // so the secret goes too and the next pairing starts afresh.
            if current.devices.isEmpty { current.hostSecret = LampAgentRemoteHandshake.generateHostSecret() }
            persist(current)
        }
    }
}

/// A pairing QR on screen: its code, good for one device, and closed after
/// a few proofs that fail under it, so a code read over a shoulder cannot be
/// guessed at for as long as the window stays open.
public struct LampAgentRemotePairingWindow: Equatable, Sendable {
    public let code: String
    public private(set) var failuresLeft: Int
    public private(set) var isClosed = false

    public static let allowedFailures = 5

    public init(code: String = LampPresentationRemotePairing.generateCode(), allowedFailures: Int = Self.allowedFailures) {
        self.code = code
        self.failuresLeft = allowedFailures
    }

    /// The pairing key a device may prove itself with, while the window is
    /// open.
    public var credential: LampAgentRemoteCredential? {
        isClosed ? nil : LampAgentRemoteCredential.pairing(code: code)
    }

    /// A device paired under the code: it is spent.
    public mutating func paired() {
        isClosed = true
    }

    /// A proof that matched no key while the window was open.
    public mutating func failed() {
        guard !isClosed else { return }
        failuresLeft -= 1
        if failuresLeft <= 0 { isClosed = true }
    }
}
