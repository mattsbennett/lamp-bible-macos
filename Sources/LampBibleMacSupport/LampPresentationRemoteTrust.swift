import Foundation
import LampCore
import Security

/// Where a presenter keeps what it needs to recognise a remote it has paired.
///
/// What is kept is a frame key for each remembered device and one secret of
/// the presenter's own, so this is as sensitive as a password file. It belongs
/// in the keychain and **never in the library**: the library syncs to the
/// person's own server, and a trusted-remotes file there would hand every
/// remote's key to whoever can read that server.
public protocol LampPresentationRemoteTrustStorage: AnyObject {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func removeAll() throws
}

/// Everything a presenter remembers between sessions.
public struct LampPresentationRemoteTrust: Codable, Equatable, Sendable {
    /// Identifies this presenter to the devices it has paired. Never a key
    /// for traffic: it only lets a paired device recognise the presenter.
    public var presenterSecret: String
    public var remotes: [LampPresentationTrustedRemote]

    public init(
        presenterSecret: String = LampPresentationRemotePairing.generatePresenterSecret(),
        remotes: [LampPresentationTrustedRemote] = []
    ) {
        self.presenterSecret = presenterSecret
        self.remotes = remotes
    }
}

/// The presenter's memory of the remotes it has paired.
///
/// Reads and writes go through `storage`, so the rules here — which code lets
/// a device in, what forgetting means — are testable without a keychain.
public final class LampPresentationRemoteTrustStore {
    private let storage: any LampPresentationRemoteTrustStorage
    private var cached: LampPresentationRemoteTrust?
    private let lock = NSLock()

    public init(storage: any LampPresentationRemoteTrustStorage) {
        self.storage = storage
    }

    /// The presenter's own keychain.
    public convenience init(service: String = LampPresentationRemoteKeychain.defaultService) {
        self.init(storage: LampPresentationRemoteKeychain(service: service))
    }

    private func trust() -> LampPresentationRemoteTrust {
        if let cached { return cached }
        let loaded = (try? storage.read())
            .flatMap { $0 }
            .flatMap { try? JSONDecoder().decode(LampPresentationRemoteTrust.self, from: $0) }
        let trust = loaded ?? LampPresentationRemoteTrust()
        if loaded == nil { try? persist(trust) }
        cached = trust
        return trust
    }

    private func persist(_ trust: LampPresentationRemoteTrust) throws {
        try storage.write(try JSONEncoder().encode(trust))
        cached = trust
    }

    /// What goes on the public challenge so a device that has paired can
    /// recognise this presenter. Different for every challenge.
    public func presenterHint(challenge: String) -> String? {
        lock.withLock {
            LampPresentationRemotePairing.presenterHint(
                secret: trust().presenterSecret,
                challenge: challenge
            )
        }
    }

    public func remotes() -> [LampPresentationTrustedRemote] {
        lock.withLock { trust().remotes }
    }

    /// Every code that may open a frame from a device that has paired before.
    public func trustedCodes() -> [String] {
        lock.withLock { trust().remotes.map(\.deviceCode) }
    }

    /// Mints this device a code of its own and remembers it, returning what
    /// to send inside `accepted`.
    ///
    /// Pairing the same device again replaces its record rather than adding a
    /// second, so a remote re-paired after being forgotten appears once.
    @discardableResult
    public func remember(clientName: String?, now: Date = Date()) -> (deviceCode: String, presenterSecret: String) {
        lock.withLock {
            var current = trust()
            let code = LampPresentationRemotePairing.generateCode()
            let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
            current.remotes.removeAll { $0.clientName == name && name?.isEmpty == false }
            current.remotes.append(
                LampPresentationTrustedRemote(
                    deviceCode: code,
                    clientName: name?.isEmpty == false ? name : nil,
                    pairedAt: now
                )
            )
            try? persist(current)
            return (code, current.presenterSecret)
        }
    }

    public func forget(deviceCode: String) {
        lock.withLock {
            var current = trust()
            current.remotes.removeAll { $0.deviceCode == deviceCode }
            // The secret is kept while other remotes still need it to
            // recognise this presenter. A device forgotten here can no longer
            // connect, though it could still tell this Mac apart from another
            // until the last remote goes. Rotating now would lock out the
            // remotes that are still trusted, which is the worse trade.
            try? persist(current)
        }
    }

    /// Forgets every remote, and mints a new presenter secret.
    ///
    /// Rotating here is what makes "forget" complete. The secret is shared
    /// with every device that has paired, so a device that keeps its copy
    /// could otherwise go on recognising this Mac for ever — not connecting
    /// to it, but telling it apart from any other. With no remotes left there
    /// is nobody to lock out, so the secret can go.
    public func forgetAll() {
        lock.withLock {
            try? persist(LampPresentationRemoteTrust())
        }
    }
}

/// The keychain, as the trust store writes to it.
public final class LampPresentationRemoteKeychain: LampPresentationRemoteTrustStorage {
    public static let defaultService = "com.neus.Lamp-Bible.presentation-remote"
    private static let account = "trusted-remotes"

    private let service: String

    public init(service: String = defaultService) {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func read() throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return item as? Data
    }

    public func write(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Usable once the Mac has been unlocked after a restart, and not
            // carried to the person's other devices: a remote paired with
            // this Mac is paired with this Mac.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.status(status) }
        var insert = query
        insert.merge(attributes) { current, _ in current }
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError.status(added) }
    }

    public func removeAll() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    public enum KeychainError: Error, Equatable {
        case status(OSStatus)
    }
}

/// Trust held only in memory, for tests and for a run that must not write.
public final class LampPresentationRemoteTrustMemory: LampPresentationRemoteTrustStorage {
    private var data: Data?

    public init(data: Data? = nil) {
        self.data = data
    }

    public func read() throws -> Data? { data }
    public func write(_ data: Data) throws { self.data = data }
    public func removeAll() throws { data = nil }
}
