import Combine
import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import Network

final class LampPresentationRemoteHost: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case waiting
        case connected
        case failed(String)

        var text: String {
            switch self {
            case .stopped: "Remote off"
            case .starting: "Starting remote…"
            case .waiting: "Waiting for a remote"
            case .connected: "Remote connected"
            case let .failed(message): message
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var pairingCode = LampPresentationRemotePairing.generateCode()
    @Published private(set) var connectedClientNames: [String] = []
    /// Remotes this Mac has paired before and will let straight in.
    @Published private(set) var rememberedRemotes: [LampPresentationTrustedRemote] = []

    var commandHandler: ((LampPresentationRemoteCommand) -> Void)?

    init() {
        rememberedRemotes = trust.remotes()
    }

    /// Stops letting one remote in. It must pair by QR again, and until the
    /// last remote is forgotten it can still tell this Mac apart from
    /// another — see `forgetAllRemotes`.
    func forget(_ remote: LampPresentationTrustedRemote) {
        trust.forget(deviceCode: remote.deviceCode)
        publishRememberedRemotes()
    }

    /// Forgets every remote and mints a new presenter secret, so no device
    /// that was paired can connect to this Mac or recognise it again.
    func forgetAllRemotes() {
        trust.forgetAll()
        publishRememberedRemotes()
    }

    private func publishRememberedRemotes() {
        let remotes = trust.remotes().sorted { $0.pairedAt > $1.pairedAt }
        DispatchQueue.main.async { [weak self] in
            self?.rememberedRemotes = remotes
        }
    }

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        var clientName = "Remote"
        var isAuthorized = false
        let pairingChallenge = LampPresentationRemotePairing.generateChallenge()
        /// The code this peer's frames are sealed under: the session code for
        /// a device pairing by QR, or its own code for one that has paired
        /// before. Settled by the first frame that opens.
        var code: String?

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// The remotes this presenter has paired before. In the keychain, never
    /// in the library, which syncs.
    private let trust = LampPresentationRemoteTrustStore()
    private let queue = DispatchQueue(label: "com.neus.lamp-bible.presentation-remote")
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var latestState: LampPresentationRemoteState?

    func start() {
        guard listener == nil else { return }
        status = .starting

        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: "Lamp Bible on \(Host.current().localizedName ?? "Mac")",
                type: LampPresentationRemoteProtocol.bonjourServiceType,
                domain: nil,
                txtRecord: nil
            )
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.handleListenerState(state, listener: listener)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            status = .failed("Remote unavailable: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            guard let self else { return }
            self.peers.values.forEach { $0.connection.cancel() }
            self.peers.removeAll()
            DispatchQueue.main.async {
                self.connectedClientNames = []
                self.status = .stopped
            }
        }
    }

    func broadcast(_ state: LampPresentationRemoteState) {
        queue.async { [weak self] in
            guard let self else { return }
            self.latestState = state
            for peer in self.peers.values where peer.isAuthorized {
                self.send(.state(state), to: peer)
            }
        }
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener) {
        switch state {
        case .ready:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.listener === listener else { return }
                self.status = self.connectedClientNames.isEmpty ? .waiting : .connected
            }
        case let .failed(error):
            DispatchQueue.main.async { [weak self] in
                self?.status = .failed("Remote unavailable: \(error.localizedDescription)")
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection)
        let id = ObjectIdentifier(connection)
        peers[id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed, .cancelled:
                self.remove(peer)
            default:
                break
            }
        }
        connection.start(queue: queue)
        sendPlaintext(
            .hello(
                pairingChallenge: peer.pairingChallenge,
                presenterHint: trust.presenterHint(challenge: peer.pairingChallenge)
            ),
            to: peer
        )
        receive(from: peer)
    }

    private func receive(from peer: Peer) {
        peer.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }

            if let data, !data.isEmpty {
                peer.buffer.append(data)
                do {
                    let messages = try self.decodeFrames(from: peer)
                    messages.forEach { self.handle($0, from: peer) }
                } catch {
                    peer.connection.cancel()
                    return
                }
            }

            if isComplete || error != nil {
                self.remove(peer)
            } else {
                self.receive(from: peer)
            }
        }
    }

    /// This peer's frames, opened under whichever code it is using.
    ///
    /// A device pairing by QR seals its frames under the session code; one
    /// that has paired before uses the code minted for it then. Which it is
    /// is not announced, so the first frame is tried against each in turn —
    /// on a copy of the buffer, because the codec consumes a frame before it
    /// finds out whether it can open it. Only a frame that actually opens
    /// settles the question, so an incomplete frame leaves it open.
    private func decodeFrames(from peer: Peer) throws -> [LampPresentationRemoteMessage] {
        if let code = peer.code {
            return try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                from: &peer.buffer,
                pairingCode: code
            )
        }
        for candidate in [pairingCode] + trust.trustedCodes() {
            var attempt = peer.buffer
            guard let messages = try? LampPresentationRemoteSecureFrameCodec.decodeFrames(
                from: &attempt,
                pairingCode: candidate
            ), !messages.isEmpty else { continue }
            peer.buffer = attempt
            peer.code = candidate
            return messages
        }
        // Nothing opened it. Either the frame has not all arrived, or this is
        // not a device we know; waiting is right for the first and harmless
        // for the second, which never gets past `pair`.
        return []
    }

    private func handle(_ message: LampPresentationRemoteMessage, from peer: Peer) {
        guard message.protocolVersion == LampPresentationRemoteProtocol.currentVersion else {
            send(.rejected("This remote uses an incompatible protocol version."), to: peer)
            return
        }

        switch message.kind {
        case .hello:
            if let name = message.clientName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !name.isEmpty {
                peer.clientName = String(name.prefix(80))
            }
        case .pair:
            // The code must be the one that opened the frame, so a device
            // cannot name one code and speak under another, and the challenge
            // must be this connection's own, so a recorded pairing cannot be
            // replayed on a later one.
            guard let code = peer.code,
                  message.pairingCode == code,
                  message.pairingChallenge == peer.pairingChallenge else {
                send(.rejected("That pairing code is not correct."), to: peer)
                return
            }
            peer.isAuthorized = true
            if code == pairingCode {
                // Paired by QR: mint this device a code of its own so it is
                // not asked again. Both go back inside `accepted`, which is
                // sealed, so neither is ever in the clear.
                let minted = trust.remember(clientName: message.clientName ?? peer.clientName)
                publishRememberedRemotes()
                send(
                    .accepted(deviceCode: minted.deviceCode, presenterSecret: minted.presenterSecret),
                    to: peer
                )
            } else {
                // A device we already know, let straight in.
                send(.accepted(), to: peer)
            }
            if let latestState { send(.state(latestState), to: peer) }
            publishConnectedPeers()
        case .command:
            guard peer.isAuthorized, let command = message.command else { return }
            DispatchQueue.main.async { [weak self] in
                self?.commandHandler?(command)
            }
        case .ping:
            send(.init(kind: .pong), to: peer)
        case .accepted, .rejected, .state, .pong:
            break
        }
    }

    private func send(_ message: LampPresentationRemoteMessage, to peer: Peer) {
        // Answered under the code this peer is speaking: a device that has
        // paired before is using its own, not the session's.
        guard let frame = try? LampPresentationRemoteSecureFrameCodec.encode(
            message,
            pairingCode: peer.code ?? pairingCode
        ) else { return }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func sendPlaintext(_ message: LampPresentationRemoteMessage, to peer: Peer) {
        guard let frame = try? LampPresentationRemoteFrameCodec.encode(message) else { return }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func remove(_ peer: Peer) {
        peers.removeValue(forKey: ObjectIdentifier(peer.connection))
        peer.connection.cancel()
        publishConnectedPeers()
    }

    private func publishConnectedPeers() {
        let names = peers.values
            .filter(\.isAuthorized)
            .map(\.clientName)
            .sorted()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.connectedClientNames = names
            if self.listener != nil {
                self.status = names.isEmpty ? .waiting : .connected
            }
        }
    }

}
