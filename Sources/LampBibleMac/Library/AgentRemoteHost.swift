import AppKit
import Combine
import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import Network

/// Lets a paired iPhone or iPad follow and continue this Mac's reader chats.
///
/// The phone cannot sign in to the providers' command-line tools, so it runs
/// no agent: it is a window onto the chats running here. A turn it sends goes
/// through the same chat model a window on the Mac uses, so an open window
/// shows it too and the transcript is saved as any other.
///
/// Direct over the local network or peer to peer, with nothing of ours in
/// between. Each connection agrees fresh keys (`LampAgentRemoteHandshake`), so
/// a recording of today's chat cannot be opened with a key stolen later.
/// Only while the AI switch and this host's own setting are both on, and only
/// reader chats: read-only, with the same Lamp tools and limits as a reader
/// chat in a window.
///
/// Network work runs on the main queue: the chats are main-actor objects,
/// and a chat's traffic is a person typing and a reply arriving. What is slow
/// — the keychain, reading every transcript — is done off it.
@MainActor
final class AgentRemoteHost: ObservableObject {
    enum Status: Equatable {
        case off
        case waiting
        case connected
        case failed(String)
    }

    static let enabledKey = "agentRemote.enabled"

    @Published private(set) var status: Status = .off
    @Published private(set) var devices: [LampAgentRemotePairedDevice] = []
    /// False when the keychain could not be read this run: nothing is
    /// written then, so a device paired now would be forgotten at the next
    /// launch, and Settings says so rather than let it seem to have worked.
    @Published private(set) var canKeepPairings = true
    @Published private(set) var connectedNames: [String] = []
    /// The pairing QR's window while it is on screen.
    @Published private(set) var pairing: LampAgentRemotePairingWindow?

    private let trust = LampAgentRemoteTrustStore()
    /// The keychain is read and written here, never on the main thread: a
    /// build signed differently from the one that wrote the item is asked
    /// about it, and the app would stand still behind the prompt.
    private let trustQueue = DispatchQueue(label: "com.neus.lamp-bible.agent-remote.trust")
    /// What the keychain held when last read, for connections to be checked
    /// against without waiting on it.
    private var knownCredentials: [LampAgentRemoteCredential] = []
    private var knownHostSecret: String?
    /// Moves on with every change to what is trusted. A read of the keychain
    /// begun before a change is dropped when it lands, so it cannot put back
    /// a device forgotten while it was reading.
    private var trustGeneration = 0
    /// Devices forgotten this run, refused whatever a read of the keychain
    /// says, so no ordering of reads and writes can let one back in.
    private var revoked: Set<String> = []
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// The turns a device has running, by the id of the question that began
    /// each: kept here rather than on its connection, which a phone going to
    /// sleep closes while the turn runs on, so forgetting the device or
    /// turning the host off still stops them — and only them.
    private var runs: [String: [(model: NativeAgentChatModel, turn: UUID)]] = [:]
    private weak var libraryModel: LibraryModel?

    private var settingsObserver: AnyCancellable?

    private var isAllowed: Bool {
        AIFeatures.isEnabledNow && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Given the library at launch, and from then on follows the settings:
    /// on exactly while the AI switch and this host's own are both on.
    func attach(_ libraryModel: LibraryModel) {
        self.libraryModel = libraryModel
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.followSettings() }
            }
        #if DEBUG
        // A test client pairing with a code it chose, with no sheet to open.
        // Debug builds only.
        if let code = ProcessInfo.processInfo.environment["LAMP_AGENT_REMOTE_TEST_CODE"],
           let normalized = LampPresentationRemotePairing.normalizedCode(code) {
            pairing = LampAgentRemotePairingWindow(code: normalized)
        }
        #endif
        followSettings()
    }

    private func followSettings() {
        if isAllowed { start() } else { stop() }
        // Library access may have changed: the open chats' helpers read their
        // policy file on every call, so it is rewritten now, not at the next
        // turn.
        for open in Set(peers.values.compactMap { $0.open?.workspace }) {
            try? writePolicy(in: open)
        }
    }

    // MARK: Pairing and devices

    /// Reads the paired devices: on demand, never at launch, so the keychain
    /// is not asked with nothing on screen to say why.
    func refreshDevices() {
        let trust = trust, generation = trustGeneration
        trustQueue.async { [weak self] in
            let devices = trust.devices()
            let credentials = trust.credentials()
            let secret = trust.hostSecret()
            let readable = trust.isReadable
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.trustGeneration else { return }
                    let revoked = self.revoked
                    self.devices = devices.filter { !revoked.contains($0.id) }
                    self.knownCredentials = credentials.filter {
                        if case .device(let id) = $0.kind { return !revoked.contains(id) }
                        return false
                    }
                    self.knownHostSecret = secret
                    self.canKeepPairings = readable
                    self.closeUntrusted()
                }
            }
        }
    }

    /// A change to what is trusted: reads begun before it are dropped, and a
    /// fresh one queued behind the write.
    private func changeTrust(_ write: @escaping @Sendable (LampAgentRemoteTrustStore) -> Void) {
        trustGeneration += 1
        let trust = trust
        trustQueue.async { write(trust) }
        refreshDevices()
    }

    func beginPairing() {
        pairing = LampAgentRemotePairingWindow()
    }

    func endPairing() {
        pairing = nil
    }

    func forget(_ device: LampAgentRemotePairedDevice) {
        // Refused at once, before the keychain catches up, and whatever it
        // says when it does.
        revoked.insert(device.id)
        knownCredentials.removeAll { $0.kind == .device(id: device.id) }
        devices.removeAll { $0.id == device.id }
        closeUntrusted()
        stopRuns(of: device.id)
        let id = device.id
        changeTrust { $0.forget(deviceID: id) }
    }

    /// Ends every connection from a device no longer trusted, stopping what
    /// it started: a forgotten device's turn does not run on.
    private func closeUntrusted() {
        let trusted = Set(devices.map(\.id))
        for peer in Array(peers.values) {
            // A device still being paired has no id yet, and is let be.
            guard let id = peer.deviceID else { continue }
            if revoked.contains(id) || !trusted.contains(id) {
                revoke(peer, reason: "This device is no longer paired with the Mac.", code: LampAgentRemoteFailure.notAllowed)
            }
        }
    }

    // MARK: Listening

    private func start() {
        guard listener == nil else { return }
        refreshDevices()
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: "Lamp Bible on \(Host.current().localizedName ?? "Mac")",
                type: LampAgentRemoteProtocol.bonjourServiceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready: self.publishConnected()
                    case .failed(let error): self.status = .failed("Chats from devices unavailable: \(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
            status = .waiting
        } catch {
            status = .failed("Chats from devices unavailable: \(error.localizedDescription)")
        }
    }

    private func stop() {
        guard listener != nil || !peers.isEmpty else { return }
        listener?.cancel()
        listener = nil
        for peer in Array(peers.values) {
            // Told why, where it can be, and what it started stopped: the
            // switch went off under it.
            revoke(peer, reason: "Chats from this Mac are turned off.", code: LampAgentRemoteFailure.aiOff)
        }
        for device in Array(runs.keys) { stopRuns(of: device) }
        status = .off
        connectedNames = []
    }

    // MARK: A connection

    /// One connection: its bytes, and core's account of where its handshake
    /// stands and what may be done (`LampAgentRemoteHostConnection`).
    private final class Peer {
        let connection: NWConnection
        var link: LampAgentRemoteHostConnection
        var name = "Device"
        var open: OpenChat?
        /// Requests still being worked on, cancelled if the connection goes.
        var tasks: [UUID: Task<Void, Never>] = [:]

        var deviceID: String? { link.deviceID }

        init(connection: NWConnection, link: LampAgentRemoteHostConnection) {
            self.connection = connection
            self.link = link
        }
    }

    /// A chat a device has open: the model it follows, and what it was last
    /// told, to tell it only what changed.
    private final class OpenChat {
        let id: UUID
        let workspace: URL
        let model: NativeAgentChatModel
        var told = LampAgentRemoteChatState()
        var watching: AnyCancellable?

        init(id: UUID, workspace: URL, model: NativeAgentChatModel) {
            self.id = id
            self.workspace = workspace
            self.model = model
        }
    }

    private func accept(_ connection: NWConnection) {
        // Only so many unproven at once: nothing that has not proved itself
        // holds more than a handshake's worth of this Mac.
        guard peers.values.filter({ !$0.link.isProven }).count < LampAgentRemoteHostConnection.unprovenLimit else {
            connection.cancel()
            return
        }
        let peer = Peer(connection: connection, link: LampAgentRemoteHostConnection(hostSecret: knownHostSecret))
        peers[ObjectIdentifier(connection)] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            MainActor.assumeIsolated {
                guard let self, let peer else { return }
                switch state {
                case .failed, .cancelled: self.close(peer)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        connection.send(content: peer.link.opening, completion: .contentProcessed { _ in })
        receive(from: peer)
        Task { [weak self, weak peer] in
            // Measured by the task's own sleep, not the wall clock, which can
            // be set back: still unproven when it wakes, it is closed.
            try? await Task.sleep(for: .seconds(LampAgentRemoteHostConnection.handshakeDeadline))
            guard let self, let peer, self.isConnected(peer), !peer.link.isProven else { return }
            self.close(peer)
        }
    }

    private func isConnected(_ peer: Peer) -> Bool {
        peers[ObjectIdentifier(peer.connection)] === peer
    }

    private func receive(from peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self, weak peer] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let peer, self.isConnected(peer) else { return }
                if let data, !data.isEmpty {
                    let effects = peer.link.receive(
                        data, trusted: self.knownCredentials, revoked: self.revoked, pairing: &self.pairing
                    )
                    self.perform(effects, for: peer)
                    guard self.isConnected(peer) else { return }
                }
                if isComplete || error != nil {
                    self.close(peer)
                } else {
                    self.receive(from: peer)
                }
            }
        }
    }

    /// Does what core says the connection calls for.
    private func perform(_ effects: [LampAgentRemoteHostConnection.Effect], for peer: Peer) {
        for effect in effects {
            switch effect {
            case .send(let frame):
                peer.connection.send(content: frame, completion: .contentProcessed { _ in })
            case .pairedByCode:
                mintKey(for: peer)
            case .acceptedDevice(let id):
                peer.name = devices.first { $0.id == id }?.name ?? peer.name
                publishConnected()
            case .received(let message):
                guard isConnected(peer) else { return }
                handle(message, from: peer)
            case .close:
                close(peer)
                return
            }
        }
    }

    /// A device paired by code: its key is minted and kept off the main
    /// thread, then sent to it inside `accepted`. It says nothing until then.
    private func mintKey(for peer: Peer) {
        trustGeneration += 1
        let trust = trust
        trustQueue.async { [weak self, weak peer] in
            let minted = trust.pair(name: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshDevices()
                    guard let peer, self.isConnected(peer) else { return }
                    self.devices.append(LampAgentRemotePairedDevice(credential: minted.credential, name: nil, pairedAt: Date()))
                    self.perform(peer.link.completePairing(minted.credential, hostSecret: minted.hostSecret), for: peer)
                    self.publishConnected()
                }
            }
        }
    }

    /// Whether this peer may still have a turn run for it: connected, its
    /// device still trusted, and the host still allowed.
    private func mayAct(_ peer: Peer) -> Bool {
        guard isConnected(peer), listener != nil, isAllowed, let id = peer.deviceID else { return false }
        return !revoked.contains(id) && devices.contains { $0.id == id }
    }

    private func handle(_ message: LampAgentRemoteMessage, from peer: Peer) {
        guard isAllowed else {
            send(.failed(LampAgentRemoteFailure.aiOff, "AI features are turned off on this Mac.", requestID: message.requestID), to: peer)
            return
        }
        // Nothing but `accepted` reaches a device still being paired, and it
        // says nothing until then.
        guard peer.deviceID != nil else { return }
        switch message.kind {
        case .introduce:
            if let name = message.clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
               let id = peer.deviceID {
                peer.name = String(name.prefix(80))
                let renamed = peer.name
                if let index = devices.firstIndex(where: { $0.id == id }) { devices[index].name = renamed }
                changeTrust { $0.rename(deviceID: id, name: renamed) }
                publishConnected()
            }
        case .listChats:
            track(peer) { await self.list(for: peer, requestID: message.requestID) }
        case .openChat:
            open(message.chatID, for: peer, requestID: message.requestID)
        case .closeChat:
            peer.open = nil
        case .send:
            track(peer) { await self.send(message, from: peer) }
        case .cancel:
            guard let open = peer.open, message.chatID == open.id.uuidString else {
                send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't open.", requestID: message.requestID), to: peer)
                return
            }
            open.model.cancel()
        case .startChat:
            track(peer) { await self.startChat(message, from: peer) }
        case .ping:
            send(.pong, to: peer)
        default:
            // A kind from a newer phone, or one only a host sends.
            break
        }
    }

    /// Works on a request, holding it only while it is in flight.
    private func track(_ peer: Peer, _ work: @escaping () async -> Void) {
        let id = UUID()
        peer.tasks[id] = Task { [weak peer] in
            await work()
            peer?.tasks[id] = nil
        }
    }

    // MARK: Chats

    private var libraryRootURL: URL? { libraryModel?.library.rootURL }

    private static let providers = AIProviderCLI.allCases.map { LampAgentRemoteHosting.Provider(id: $0.rawValue, name: $0.name) }

    private static func hostingProvider(_ provider: AIProviderCLI) -> LampAgentRemoteHosting.Provider {
        .init(id: provider.rawValue, name: provider.name)
    }

    /// The provider a chat goes on with: what the reader chat pane would open
    /// it on.
    private func continuingProvider(in workspace: URL) -> AIProviderCLI {
        let id = LampAgentRemoteHosting.continuingProviderID(in: workspace, appProviderID: ReaderChatTurns.appProviderID)
        return AIProviderCLI(rawValue: id) ?? .codex
    }

    private func transcripts(in workspace: URL) -> [LampAgentRemoteHosting.ProviderTranscript] {
        AIProviderCLI.allCases.map { provider in
            .init(
                provider: Self.hostingProvider(provider),
                transcript: AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
            )
        }
    }

    private func summary(of id: UUID) -> LampAgentRemoteChatSummary? {
        guard let root = libraryRootURL else { return nil }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: id)
        return LampAgentRemoteHosting.summary(
            chatID: id,
            transcripts: transcripts(in: workspace),
            continuing: Self.hostingProvider(continuingProvider(in: workspace)),
            isRunning: KeptAgentChats.isRunning(in: workspace)
        )
    }

    /// Every reader chat, read off the main thread, with whether a reply is
    /// running in it added from the live models here.
    private func list(for peer: Peer, requestID: UUID?) async {
        guard let root = libraryRootURL else {
            send(.chats([], requestID: requestID), to: peer)
            return
        }
        let providers = Self.providers, appProvider = ReaderChatTurns.appProviderID
        let read = await Task.detached(priority: .userInitiated) {
            LampAgentRemoteHosting.readSummaries(libraryRootURL: root, providers: providers, appProviderID: appProvider)
        }.value
        guard isConnected(peer) else { return }
        let summaries = read.map { item -> LampAgentRemoteChatSummary in
            var summary = item.summary
            summary.isRunning = KeptAgentChats.isRunning(in: item.workspace)
            return summary
        }
        send(.chats(summaries, requestID: requestID), to: peer)
    }

    private func writePolicy(in workspace: URL) throws {
        guard let libraryModel else { return }
        try ReaderChatTurns.writeAccessPolicy(
            ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel), workspace: workspace
        )
    }

    /// The model a chat runs in, made ready: the same one a window on this
    /// chat uses, if one is open.
    private func model(for id: UUID) throws -> (model: NativeAgentChatModel, workspace: URL) {
        guard let libraryModel, let root = libraryRootURL else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The library isn't open yet."])
        }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: id)
        let configuration = try ReaderChatTurns.prepare(
            workspace: workspace,
            policy: ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel),
            libraryRootURL: root
        )
        let model = KeptAgentChats.model(
            provider: continuingProvider(in: workspace), workspace: workspace, mode: .reader(configuration)
        )
        model.load()
        return (model, workspace)
    }

    @discardableResult
    private func open(_ chatID: String?, for peer: Peer, requestID: UUID?) -> OpenChat? {
        guard let chatID, let id = UUID(uuidString: chatID), let summary = summary(of: id) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: requestID, chatID: chatID), to: peer)
            return nil
        }
        do {
            let (model, workspace) = try model(for: id)
            return follow(OpenChat(id: id, workspace: workspace, model: model), summary: summary, for: peer, requestID: requestID)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: chatID), to: peer)
            return nil
        }
    }

    /// Makes a chat the one this peer has open: a snapshot first, then what
    /// changes in it.
    private func follow(_ open: OpenChat, summary: LampAgentRemoteChatSummary, for peer: Peer, requestID: UUID?) -> OpenChat {
        open.told = Self.state(of: open.model)
        peer.open = open
        send(.snapshot(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: open.told), requestID: requestID), to: peer)
        watch(open, for: peer)
        return open
    }

    private static func state(of model: NativeAgentChatModel) -> LampAgentRemoteChatState {
        state(
            messages: model.messages, arriving: model.arrivingReply, activity: model.activity,
            isRunning: model.isRunning, failure: model.errorMessage
        )
    }

    private static func state(
        messages: [NativeAgentChatMessage], arriving: String, activity: AgentChatActivity?,
        isRunning: Bool, failure: String?
    ) -> LampAgentRemoteChatState {
        LampAgentRemoteHosting.state(
            // As the transcript is written: what has words, the arriving
            // reply excepted, which has none yet.
            messages: messages.compactMap { message in
                message.text.map {
                    AgentChatTranscript.Message(
                        id: message.id, role: message.isSender ? .user : .assistant, text: $0, date: message.date
                    )
                }
            },
            arriving: arriving,
            activity: activity,
            isRunning: isRunning,
            failure: failure
        )
    }

    /// Tells the peer what changes in its open chat, whichever window or
    /// device caused it. The published values are taken as they arrive:
    /// read back off the model inside the sink, they are still the old ones.
    private func watch(_ open: OpenChat, for peer: Peer) {
        let model = open.model
        open.watching = Publishers.CombineLatest4(
            model.$messages, model.$isRunning, model.$activity,
            Publishers.CombineLatest(model.$arrivingReply, model.$errorMessage)
        )
        .dropFirst()
        // The model changes its values one at a time — running before the
        // question is in, running off before the answer is — so each is
        // taken with the rest of the same change. Turns that run together in
        // one step are still told apart (`LampAgentRemoteHosting.events`).
        .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
        .sink { [weak self, weak peer, weak open] messages, isRunning, activity, rest in
            MainActor.assumeIsolated {
                guard let self, let peer, let open, peer.open === open, self.isConnected(peer) else { return }
                let next = Self.state(
                    messages: messages, arriving: rest.0, activity: activity, isRunning: isRunning, failure: rest.1
                )
                if LampAgentRemoteChatUpdates.needsSnapshot(from: open.told, to: next),
                   let summary = self.summary(of: open.id) ?? Optional(LampAgentRemoteHosting.untitled(
                       open.id, Self.hostingProvider(self.continuingProvider(in: open.workspace)), isRunning: isRunning
                   )) {
                    // Cleared, or turns undone, on the Mac: start the phone's
                    // copy again rather than patch it.
                    self.send(.snapshot(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: next)), to: peer)
                } else {
                    for event in LampAgentRemoteChatUpdates.events(chatID: open.id.uuidString, from: open.told, to: next) {
                        self.send(.event(event), to: peer)
                    }
                }
                open.told = next
            }
        }
    }

    private func send(_ message: LampAgentRemoteMessage, from peer: Peer) async {
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let chatID = message.chatID, let id = UUID(uuidString: chatID) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: message.requestID), to: peer)
            return
        }
        let open = peer.open?.id == id ? peer.open : open(chatID, for: peer, requestID: nil)
        guard let open else { return }
        await run(text, reading: message.reading, in: open, requestID: message.requestID, peer: peer)
    }

    private func startChat(_ message: LampAgentRemoteMessage, from peer: Peer) async {
        guard let newChat = message.newChat, newChat.kind == LampAgentRemoteChatSummary.reader else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "Only reader chats can be started from a device.", requestID: message.requestID), to: peer)
            return
        }
        let first = newChat.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "Write something to start the chat.", requestID: message.requestID), to: peer)
            return
        }
        guard let root = libraryRootURL else { return }
        let id = UUID()
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: id)
        do {
            // The provider chosen is the chat's own, pinned as the pane pins
            // it, so the chat opens on it in a window too.
            let provider = newChat.provider.flatMap(AIProviderCLI.init(rawValue:))
                ?? AIProviderCLI(rawValue: ReaderChatTurns.appProviderID) ?? .codex
            var choices = AgentChatChoicesStore.load(in: workspace)
            choices.set(provider.rawValue, for: AgentChatChoices.providerKey)
            try AgentChatChoicesStore.save(choices, in: workspace)
            _ = AgentChatOwnChoices.pinned(in: workspace, appProviderID: provider.rawValue)

            let (model, _) = try model(for: id)
            let summary = LampAgentRemoteHosting.untitled(
                id, Self.hostingProvider(provider), title: ReaderChatWorkspaceStore.label(first), isRunning: false
            )
            // The snapshot before anything streams, so every event after it
            // is for a chat the phone already holds.
            let open = follow(OpenChat(id: id, workspace: workspace, model: model), summary: summary, for: peer, requestID: message.requestID)
            await run(first, reading: newChat.reading, in: open, requestID: message.requestID, peer: peer)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: message.requestID), to: peer)
        }
    }

    /// Sends a turn through the chat's model, with the passage the phone is
    /// reading, as a window would send it — checked again just before it
    /// goes, since preparing it waits, and the device may have been forgotten
    /// or the host turned off meanwhile.
    private func run(_ text: String, reading: LampAgentRemoteReading?, in open: OpenChat, requestID: UUID?, peer: Peer) async {
        guard !open.model.isRunning else {
            send(.failed(LampAgentRemoteFailure.busy, "A reply is still arriving in this chat.", requestID: requestID, chatID: open.id.uuidString), to: peer)
            return
        }
        let conversation = open.model.conversationID
        do {
            // Every turn, whether or not it names a passage: the helper reads
            // this file on each call, and access may have narrowed since.
            try writePolicy(in: open.workspace)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: open.id.uuidString), to: peer)
            return
        }
        let prompt = await contextualPrompt(text, reading: reading)
        guard !Task.isCancelled, mayAct(peer), let device = peer.deviceID else { return }
        // The question's id is chosen here, so the turn is known as this
        // device's for as long as it runs, and no longer.
        let turn = UUID()
        runs[device, default: []].append((open.model, turn))
        let taken = await open.model.send(text, contextualPrompt: prompt, messageID: turn, inConversation: conversation)
        runs[device]?.removeAll { $0.turn == turn }
        if runs[device]?.isEmpty == true { runs[device] = nil }
        if !taken, isConnected(peer), peer.open === open {
            send(.failed(LampAgentRemoteFailure.busy, "This chat changed on the Mac before the message could go.", requestID: requestID, chatID: open.id.uuidString), to: peer)
        }
    }

    /// The question with the passage it was asked over, by ids the phone
    /// sent: the notes and highlights are this Mac's own, read under its own
    /// policy. A question with no passage goes as it is.
    private func contextualPrompt(_ text: String, reading: LampAgentRemoteReading?) async -> String {
        guard let libraryModel, let reference = reading?.verse ?? reading?.chapter,
              let translation = libraryModel.translations.first(where: { $0.id == reading?.translationID })
                ?? libraryModel.translations.first
        else { return text }
        let book = reference / 1_000_000, chapterNumber = reference / 1_000 % 1_000
        guard let chapter = try? await libraryModel.library.chapter(
            moduleID: translation.id, bookNumber: book, chapterNumber: chapterNumber
        ) else { return text }
        let capture = ReaderChatTurns.capture(
            book: chapter.book,
            chapter: chapterNumber,
            translation: translation,
            selectedVerse: reading?.verse,
            selection: nil,
            chapterVerses: chapter.verses,
            policy: ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel),
            libraryModel: libraryModel
        )
        let notes = await ReaderChatTurns.notes(on: capture.noteReferences, libraryModel: libraryModel)
        return capture.context(notes: notes).prompt(for: text)
    }

    // MARK: Sending and closing

    private func send(_ message: LampAgentRemoteMessage, to peer: Peer) {
        perform(peer.link.seal(message), for: peer)
    }

    /// Ends a connection whose device may no longer act, and the work it
    /// has waiting.
    private func revoke(_ peer: Peer, reason: String, code: String) {
        send(.failed(code, reason), to: peer)
        close(peer)
    }

    /// Stops the turns a device has running, connected or not: each only if
    /// the chat is still on that turn, so a turn someone else began since is
    /// left alone.
    private func stopRuns(of device: String) {
        for run in runs.removeValue(forKey: device) ?? [] where run.model.isRunning {
            let current = run.model.messages.last { $0.isSender }?.id
            if current == run.turn { run.model.cancel() }
        }
    }

    /// A connection gone: a phone asleep or out of range. What it started
    /// runs on, as a run outlives a closed window.
    private func close(_ peer: Peer) {
        peer.tasks.values.forEach { $0.cancel() }
        peer.tasks = [:]
        peer.open = nil
        peers.removeValue(forKey: ObjectIdentifier(peer.connection))
        peer.connection.cancel()
        publishConnected()
    }

    private func publishConnected() {
        connectedNames = peers.values.filter { $0.deviceID != nil }.map(\.name).sorted()
        guard listener != nil else { return }
        if case .failed = status { return }
        status = connectedNames.isEmpty ? .waiting : .connected
    }
}
