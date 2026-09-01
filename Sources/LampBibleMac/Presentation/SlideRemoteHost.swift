import Combine
import Foundation
import LampCore
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

    var commandHandler: ((LampPresentationRemoteCommand) -> Void)?

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        var clientName = "Remote"
        var isAuthorized = false
        let pairingChallenge = LampPresentationRemotePairing.generateChallenge()

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

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
        sendPlaintext(.hello(pairingChallenge: peer.pairingChallenge), to: peer)
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
                    let messages = try LampPresentationRemoteSecureFrameCodec.decodeFrames(
                        from: &peer.buffer,
                        pairingCode: self.pairingCode
                    )
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
            guard message.pairingCode == pairingCode,
                  message.pairingChallenge == peer.pairingChallenge else {
                send(.rejected("That pairing code is not correct."), to: peer)
                return
            }
            peer.isAuthorized = true
            send(.accepted(), to: peer)
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
        guard let frame = try? LampPresentationRemoteSecureFrameCodec.encode(
            message,
            pairingCode: pairingCode
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
