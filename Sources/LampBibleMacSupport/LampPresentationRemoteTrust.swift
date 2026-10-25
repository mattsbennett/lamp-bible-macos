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

    /// What is remembered, read once and then kept.
    ///
    /// The three cases are deliberately kept apart, because treating them
    /// alike loses data. **Nothing there** is a first run, so a new trust is
    /// written. **Something unreadable** — a locked keychain, a refused ACL,
    /// a build this item does not belong to — is not an empty keychain: it
    /// is one that cannot be read *now*, and writing over it would throw away
    /// every remembered remote and rotate the secret. So this run carries on
    /// in memory and writes nothing, which costs the person one re-pair
    /// rather than all of them. **Something unreadable as trust** is corrupt
    /// data that nothing else will ever make sense of, so it is replaced.
    private func trust() -> LampPresentationRemoteTrust {
        if let cached { return cached }
        let stored: Data?
        do {
            stored = try storage.read()
        } catch {
            readable = false
            let fallback = LampPresentationRemoteTrust()
            cached = fallback
            return fallback
        }
        if let stored {
            if let decoded = try? JSONDecoder().decode(
                LampPresentationRemoteTrust.self, from: stored
            ) {
                cached = decoded
                return decoded
            }
            replacedCorrupt = true
        }
        // Not written here. Looking at what is remembered should leave the
        // keychain alone: a presenter nobody has paired a remote with has
        // nothing worth storing, and writing on a mere read would put an item
        // in the keychain of every person who never uses the remote at all.
        // It is written the first time a remote is actually remembered.
        let fresh = LampPresentationRemoteTrust()
        cached = fresh
        return fresh
    }

    /// Whether what is remembered could be read at all this run. False means
    /// nothing is written, so an unreadable keychain is never overwritten.
    ///
    /// Reading it loads the trust, so it answers about this run whenever it
    /// is asked rather than only after something else has looked.
    public var isReadable: Bool { lock.withLock { _ = trust(); return readable } }
    /// Whether stored trust was there but could not be understood, so a
    /// caller can say so rather than silently starting again.
    public var corruptTrustWasReplaced: Bool { lock.withLock { _ = trust(); return replacedCorrupt } }

    private var readable = true
    private var replacedCorrupt = false

    private func persist(_ trust: LampPresentationRemoteTrust) throws {
        cached = trust
        guard readable else { return }
        try storage.write(try JSONEncoder().encode(trust))
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
    /// Pairing the same device again adds a second record rather than
    /// replacing the first. The name comes from the device, and two phones
    /// are both called "iPhone" often enough that matching on it would drop
    /// one of them — and would let anyone who can pair evict a remote by
    /// copying its name. A record nothing holds the code for is harmless and
    /// can be forgotten from the list.
    @discardableResult
    public func remember(clientName: String?, now: Date = Date()) -> (deviceCode: String, presenterSecret: String) {
        lock.withLock {
            var current = trust()
            let code = LampPresentationRemotePairing.generateCode()
            let name = clientName?.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// Opening a connection's frames when which code it speaks is not announced.
///
/// A device pairing by QR seals its frames under the session code; one that
/// has paired before uses the code minted for it then. Nothing in the clear
/// says which, so the first frame is tried against each in turn.
public enum LampPresentationRemoteFrameOpener {
    public struct Opened: Equatable, Sendable {
        public var messages: [LampPresentationRemoteMessage]
        /// The code that opened the frames, once one has. Nil while nothing
        /// has opened yet, which is also true of a frame still arriving.
        public var code: String?

        public init(messages: [LampPresentationRemoteMessage] = [], code: String? = nil) {
            self.messages = messages
            self.code = code
        }
    }

    /// Takes every complete frame `buffer` holds.
    ///
    /// Once `settled` is known the buffer is read directly, so a later frame
    /// that fails to open is the error it should be. Before that, each
    /// candidate is tried on a **copy**: the codec takes a frame out of the
    /// buffer before it finds out whether it can open it, so a failed attempt
    /// on the buffer itself would eat the frame the next candidate needs.
    ///
    /// Only frames that actually open settle the question. A frame that has
    /// not all arrived decodes to nothing under every candidate, and must not
    /// be read as "the first candidate worked" — that would key the whole
    /// connection on a code chosen by nothing at all.
    public static func open(
        buffer: inout Data,
        settled: String?,
        candidates: [String]
    ) throws -> Opened {
        if let settled {
            return Opened(
                messages: try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                    from: &buffer,
                    pairingCode: settled
                ),
                code: settled
            )
        }
        var refusal: (any Error)?
        for candidate in candidates {
            var attempt = buffer
            do {
                let messages = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                    from: &attempt,
                    pairingCode: candidate
                )
                // Nothing came out and nothing was wrong: the frame has not
                // all arrived. How much has is the same under every code, so
                // there is no point trying the rest.
                guard !messages.isEmpty else { return Opened() }
                buffer = attempt
                return Opened(messages: messages, code: candidate)
            } catch {
                refusal = error
            }
        }
        // Every code refused a frame that was complete. This is not a device
        // we know, so it is told apart from one still being heard: keeping
        // the bytes would leave them to be retried against every code on
        // every read, and the buffer would only grow.
        if let refusal { throw refusal }
        return Opened()
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
            // Asked for, though macOS applies it only to the data
            // protection keychain, which needs entitlements an ad-hoc build
            // does not have. Without it the item goes to the login keychain,
            // which does not sync either — so a remote paired with this Mac
            // stays paired with this Mac, by a different route than this
            // attribute.
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
