import AppKit
import Combine
import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import Network

/// Lets a paired iPhone or iPad follow and continue this Mac's reader chats,
/// and the chat on each writing.
///
/// The phone cannot sign in to the providers' command-line tools, so it runs
/// no agent: it is a window onto the chats running here. A turn it sends goes
/// through the same chat model a window on the Mac uses, so an open window
/// shows it too and the transcript is saved as any other.
///
/// Direct over the local network or peer to peer, with nothing of ours in
/// between. Each connection agrees fresh keys (`LampAgentRemoteHandshake`), so
/// a recording of today's chat cannot be opened with a key stolen later.
/// Only while the AI switch and this host's own setting are both on. A reader
/// chat is read-only, with the same Lamp tools and limits as one in a
/// window. A writing turn is a writing window's turn (`WritingChatTurns`):
/// what the assistant writes is taken into the writing, recorded in its
/// history and marked for review, and reaches the phone by sync.
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
    /// Where a device on a tailnet reaches this Mac while it listens, which
    /// Bonjour cannot tell it: a tailnet carries no multicast.
    @Published private(set) var tailnetAddresses: [LampAgentRemoteAddress] = []

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
    /// Watches for the Mac joining or leaving a tailnet while it listens, so
    /// the address Settings shows is the one that works.
    private var pathMonitor: NWPathMonitor?
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// The turns a device has running, by the id of the question that began
    /// each: kept here rather than on its connection, which a phone going to
    /// sleep closes while the turn runs on, so forgetting the device or
    /// turning the host off still stops them — and only them.
    private var runs: [String: [(model: NativeAgentChatModel, turn: UUID)]] = [:]
    /// The request each question a device sent came with, by the question's
    /// id, so the events that carry it name it (`LampAgentRemoteChatState
    /// .askedBy`). The last few only: a question is told moments after it is
    /// asked, and a device that missed it is sent a snapshot instead.
    private var askedBy: [UUID: UUID] = [:]
    private var askedOrder: [UUID] = []
    private weak var libraryModel: LibraryModel?

    private var settingsObserver: AnyCancellable?
    /// A chat's choices saved by a window's menus, for the phones following
    /// it, which show what it runs with.
    private var choicesObserver: AnyCancellable?
    private var pull: (@MainActor () async -> Void)?

    private var isAllowed: Bool {
        AIFeatures.isEnabledNow && UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Given the library at launch, and from then on follows the settings:
    /// on exactly while the AI switch and this host's own are both on.
    /// `pull` takes in what sync has and reads the library again, for a
    /// writing turn asked about a copy newer than this Mac's.
    func attach(_ libraryModel: LibraryModel, pull: @escaping @MainActor () async -> Void) {
        self.libraryModel = libraryModel
        self.pull = pull
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.followSettings() }
            }
        choicesObserver = NotificationCenter.default.publisher(for: AgentChatChoicesStore.saved)
            .compactMap { $0.object as? String }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] path in
                MainActor.assumeIsolated { self?.choicesSaved(inWorkspaceAt: path) }
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
        for open in peers.values.compactMap(\.open) {
            try? writePolicy(for: open.chat, in: open.workspace)
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
        listen(onLampsPort: true)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshTailnetAddresses() }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Listens on Lamp's own port when it is free, so an address typed into
    /// a device for a tailnet keeps working from one launch to the next, and
    /// on any port the system gives when it is taken.
    private func listen(onLampsPort: Bool) {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = if onLampsPort, let port = NWEndpoint.Port(rawValue: LampAgentRemoteAddress.defaultPort) {
                try NWListener(using: parameters, on: port)
            } else {
                try NWListener(using: parameters)
            }
            listener.service = NWListener.Service(
                name: "Lamp Bible on \(Host.current().localizedName ?? "Mac")",
                type: LampAgentRemoteProtocol.bonjourServiceType
            )
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.publishConnected()
                        self.refreshTailnetAddresses()
                    case .failed(.posix(.EADDRINUSE)) where onLampsPort:
                        listener.cancel()
                        self.listener = nil
                        self.listen(onLampsPort: false)
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
        // Before anything else: a listener that could not be made leaves the
        // monitor running with nothing else to stop.
        pathMonitor?.cancel()
        pathMonitor = nil
        tailnetAddresses = []
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
        let chat: LampAgentRemoteHosting.Chat
        let workspace: URL
        let model: NativeAgentChatModel
        var told = LampAgentRemoteChatState()
        var watching: AnyCancellable?
        /// The provider, model and effort the device was last told the chat
        /// runs with, so a change made in a window's menus is told too.
        var toldChoices: [String?] = []

        var id: String { chat.id }

        init(chat: LampAgentRemoteHosting.Chat, workspace: URL, model: NativeAgentChatModel) {
            self.chat = chat
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
            guard let open = peer.open, message.chatID == open.id else {
                send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't open.", requestID: message.requestID), to: peer)
                return
            }
            open.model.cancel()
        case .startChat:
            track(peer) { await self.startChat(message, from: peer) }
        case .getSetup:
            track(peer) { await self.sendSetup(to: peer, requestID: message.requestID) }
        case .setChoices:
            setChoices(message, from: peer)
        case .answerApproval:
            answerApproval(message, from: peer)
        case .ping:
            send(.pong, to: peer)
        default:
            // A kind from a newer phone, or one only a host sends.
            break
        }
    }

    /// A device's answer to a request the open chat's turn waits on
    /// (`decisions/0040`): taken only for the request it showed, still
    /// waiting in the same turn and unchanged, Allow Once only where a device
    /// may allow it, and only once, wherever the first answer came from.
    private func answerApproval(_ message: LampAgentRemoteMessage, from peer: Peer) {
        guard mayAct(peer), let open = peer.open, message.chatID == open.id else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't open.", requestID: message.requestID, chatID: message.chatID), to: peer)
            return
        }
        let model = open.model
        // Judged against the model as it is now, not as last told.
        let now = Self.state(of: model, askedBy: askedBy)
        let outcome = LampAgentRemoteApprovalAnswer.decide(
            decision: message.decision, approvalID: message.approvalID, digest: message.approvalDigest,
            shownTurn: message.turnID, chatID: open.id, currentTurn: now.runningTurn, waiting: now.approvals
        )
        let gone = LampAgentRemoteMessage.failed(
            LampAgentRemoteFailure.approvalGone,
            "That request is no longer waiting: it was answered elsewhere, ran out of time, or its turn ended.",
            requestID: message.requestID, chatID: open.id
        )
        switch outcome {
        case .gone:
            send(gone, to: peer)
        case .notAllowed:
            send(.failed(
                LampAgentRemoteFailure.notAllowed, "This one can only be allowed on the Mac.",
                requestID: message.requestID, chatID: open.id
            ), to: peer)
        case .allowOnce, .deny:
            guard let request = model.pendingApprovals.first(where: { $0.id == message.approvalID }),
                  model.answer(request, with: outcome == .allowOnce ? .allow : .deny, saysWhy: false)
            else {
                send(gone, to: peer)
                return
            }
            send(.approvalAnswered(
                open.id, approvalID: request.id,
                decision: outcome == .allowOnce ? LampAgentRemoteApprovalAnswer.allowOnce : LampAgentRemoteApprovalAnswer.deny,
                requestID: message.requestID
            ), to: peer)
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

    /// The provider a writing's chat starts on: the writing window's own
    /// default (`DevotionalAgentWorkspaceView`).
    private static var writingAppProviderID: String {
        UserDefaults.standard.string(forKey: "devotional.agent.provider") ?? AIProviderCLI.codex.rawValue
    }

    private static func appProviderID(for chat: LampAgentRemoteHosting.Chat) -> String {
        switch chat {
        case .reader: ReaderChatTurns.appProviderID
        case .writing: writingAppProviderID
        }
    }

    /// The provider a chat goes on with: what its pane would open it on.
    private func continuingProvider(for chat: LampAgentRemoteHosting.Chat, in workspace: URL) -> AIProviderCLI {
        let id = LampAgentRemoteHosting.continuingProviderID(in: workspace, appProviderID: Self.appProviderID(for: chat))
        return AIProviderCLI(rawValue: id) ?? .codex
    }

    private func workspace(of chat: LampAgentRemoteHosting.Chat, root: URL) -> URL {
        switch chat {
        case .reader(let id): ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: id)
        case .writing(let id): LampWritingWorkspace.url(libraryRootURL: root, writingID: id)
        }
    }

    private func writing(_ id: String) -> LampDevotional? {
        libraryModel?.devotionals.first { $0.id == id }
    }

    private static func listed(_ writing: LampDevotional) -> LampAgentRemoteHosting.Writing {
        .init(id: writing.id, title: writing.title, isEditable: writing.isEditable)
    }

    private func transcripts(in workspace: URL) -> [LampAgentRemoteHosting.ProviderTranscript] {
        AIProviderCLI.allCases.map { provider in
            .init(
                provider: Self.hostingProvider(provider),
                transcript: AgentChatTranscriptStore.load(providerID: provider.rawValue, in: workspace)
            )
        }
    }

    private func summary(of chat: LampAgentRemoteHosting.Chat) -> LampAgentRemoteChatSummary? {
        guard let root = libraryRootURL else { return nil }
        let workspace = workspace(of: chat, root: root)
        let continuing = Self.hostingProvider(continuingProvider(for: chat, in: workspace))
        let isRunning = KeptAgentChats.isRunning(in: workspace)
        let summary: LampAgentRemoteChatSummary? = switch chat {
        case .reader(let id):
            LampAgentRemoteHosting.summary(
                chatID: id, transcripts: transcripts(in: workspace), continuing: continuing, isRunning: isRunning
            )
        case .writing(let id):
            writing(id).flatMap { writing in
                LampAgentRemoteHosting.summary(
                    writing: Self.listed(writing), transcripts: transcripts(in: workspace), continuing: continuing, isRunning: isRunning
                )
            }
        }
        return summary.map { Self.withChoices($0, in: workspace) }
    }

    /// A summary with the model and effort its chat runs with, as the menus
    /// over a window on it would show them.
    nonisolated private static func withChoices(_ summary: LampAgentRemoteChatSummary, in workspace: URL) -> LampAgentRemoteChatSummary {
        guard let wire = AIProviderCLI(rawValue: summary.provider)?.wireProvider else { return summary }
        let chosen = LampAgentRemoteHosting.chosen(
            in: AgentChatChoicesStore.load(in: workspace), provider: wire,
            appDefault: { UserDefaults.standard.string(forKey: $0) }
        )
        var summary = summary
        summary.model = chosen.model
        summary.effort = chosen.effort
        return summary
    }

    /// A turn's end as the phone names the chat: a writing by its name; a
    /// reader chat as "Reader Chat", under the title its list gives it, or
    /// nothing for one still called "New Chat".
    /// Whether a phone may still be told of a turn: remote chats allowed,
    /// and the device paired and not forgotten. No connection is asked for.
    private func mayStillPush(to device: String) -> Bool {
        isAllowed && !revoked.contains(device) && devices.contains { $0.id == device }
    }

    private func pushedEnd(
        of chat: LampAgentRemoteHosting.Chat, turn: UUID, device: String,
        outcome: AgentTurnNotifications.Outcome, endedAt: Date
    ) -> AgentTurnPush.Ended {
        let (title, subtitle): (String, String) = switch chat {
        case .reader:
            ("Reader Chat", summary(of: chat)?.title.replacingOccurrences(of: "New Chat", with: "") ?? "")
        case .writing(let id):
            (writing(id)?.title ?? "Writing", "")
        }
        return AgentTurnPush.Ended(
            deviceID: device, chat: chat, turnID: turn, title: title, subtitle: subtitle,
            outcome: outcome, endedAt: endedAt
        )
    }

    /// A chat with nothing said in it yet, as it is listed until something is.
    private func untitled(_ chat: LampAgentRemoteHosting.Chat, workspace: URL, title: String = "New Chat", isRunning: Bool) -> LampAgentRemoteChatSummary {
        let writing: LampAgentRemoteHosting.Writing? = switch chat {
        case .reader: nil
        case .writing(let id): self.writing(id).map(Self.listed)
        }
        return Self.withChoices(LampAgentRemoteHosting.untitled(
            chat, Self.hostingProvider(continuingProvider(for: chat, in: workspace)), title: title, writing: writing, isRunning: isRunning
        ), in: workspace)
    }

    /// Every reader chat and writing chat, newest first, read off the main
    /// thread, with whether a reply is running in each added from the live
    /// models here.
    private func list(for peer: Peer, requestID: UUID?) async {
        guard let root = libraryRootURL else {
            send(.chats([], requestID: requestID), to: peer)
            return
        }
        let providers = Self.providers, readerProvider = ReaderChatTurns.appProviderID
        let writingProvider = Self.writingAppProviderID
        let writings = (libraryModel?.devotionals ?? []).map(Self.listed)
        let read = await Task.detached(priority: .userInitiated) {
            (LampAgentRemoteHosting.readSummaries(libraryRootURL: root, providers: providers, appProviderID: readerProvider)
                + LampAgentRemoteHosting.readWritingSummaries(
                    libraryRootURL: root, writings: writings, providers: providers, appProviderID: writingProvider
                ))
            .map { (workspace: $0.workspace, summary: Self.withChoices($0.summary, in: $0.workspace)) }
        }.value
        guard isConnected(peer) else { return }
        let summaries = read.map { item -> LampAgentRemoteChatSummary in
            var summary = item.summary
            summary.isRunning = KeptAgentChats.isRunning(in: item.workspace)
            return summary
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        send(.chats(summaries, requestID: requestID), to: peer)
    }

    private func writePolicy(for chat: LampAgentRemoteHosting.Chat, in workspace: URL) throws {
        guard let libraryModel else { return }
        let policy = ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel)
        switch chat {
        case .reader:
            try ReaderChatTurns.writeAccessPolicy(policy, workspace: workspace)
        case .writing:
            // Where a writing's helper reads it (`WritingChatTurns.prepare`).
            _ = try AgentModuleAccessPreferences.writePolicy(policy, libraryRootURL: libraryModel.library.rootURL)
        }
    }

    /// The model a chat runs in, made ready: the same one a window on this
    /// chat uses, if one is open.
    private func model(for chat: LampAgentRemoteHosting.Chat) throws -> (model: NativeAgentChatModel, workspace: URL) {
        guard let libraryModel, let root = libraryRootURL else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The library isn't open yet."])
        }
        let workspace = workspace(of: chat, root: root)
        let model: NativeAgentChatModel
        switch chat {
        case .reader:
            let configuration = try ReaderChatTurns.prepare(
                workspace: workspace,
                policy: ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel),
                libraryRootURL: root
            )
            model = KeptAgentChats.model(
                provider: continuingProvider(for: chat, in: workspace), workspace: workspace, mode: .reader(configuration)
            )
        case .writing:
            // Pinned as the writing's pane pins it on opening, so the chat
            // goes on with the model and effort the pane would show.
            let choices = AgentChatOwnChoices.pinned(in: workspace, appProviderID: Self.writingAppProviderID)
            let provider = AIProviderCLI(
                rawValue: choices.value(for: AgentChatChoices.providerKey, orAppDefault: Self.writingAppProviderID)
                    ?? Self.writingAppProviderID
            ) ?? .codex
            model = WritingChatTurns.model(provider: provider, workspace: workspace)
        }
        model.load()
        return (model, workspace)
    }

    @discardableResult
    private func open(_ chatID: String?, for peer: Peer, requestID: UUID?) -> OpenChat? {
        guard let chatID, let chat = LampAgentRemoteHosting.Chat(id: chatID), let summary = summary(of: chat) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: requestID, chatID: chatID), to: peer)
            return nil
        }
        do {
            let (model, workspace) = try model(for: chat)
            return follow(OpenChat(chat: chat, workspace: workspace, model: model), summary: summary, for: peer, requestID: requestID)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: chatID), to: peer)
            return nil
        }
    }

    /// Makes a chat the one this peer has open: a snapshot first, then what
    /// changes in it.
    private func follow(_ open: OpenChat, summary: LampAgentRemoteChatSummary, for peer: Peer, requestID: UUID?) -> OpenChat {
        open.told = Self.state(of: open.model, askedBy: askedBy)
        open.toldChoices = Self.choices(of: summary)
        peer.open = open
        send(.snapshot(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: open.told), requestID: requestID), to: peer)
        watch(open, for: peer)
        return open
    }

    private static func state(of model: NativeAgentChatModel, askedBy: [UUID: UUID]) -> LampAgentRemoteChatState {
        state(
            messages: model.messages, arriving: model.arrivingReply, activity: model.activity,
            isRunning: model.isRunning, failure: model.errorMessage, askedBy: askedBy,
            approvals: model.pendingApprovals, provider: model.provider.rawValue
        )
    }

    private static func state(
        messages: [NativeAgentChatMessage], arriving: String, activity: AgentChatActivity?,
        isRunning: Bool, failure: String?, askedBy: [UUID: UUID],
        approvals: [AgentToolApprovalRequest], provider: String
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
            failure: failure,
            askedBy: askedBy,
            approvals: approvals,
            provider: provider
        )
    }

    /// Tells the peer what changes in its open chat, whichever window or
    /// device caused it. The published values are taken as they arrive:
    /// read back off the model inside the sink, they are still the old ones.
    private func watch(_ open: OpenChat, for peer: Peer) {
        let model = open.model
        open.watching = Publishers.CombineLatest4(
            model.$messages, model.$isRunning, model.$activity,
            Publishers.CombineLatest3(model.$arrivingReply, model.$errorMessage, model.$pendingApprovals)
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
                    messages: messages, arriving: rest.0, activity: activity, isRunning: isRunning, failure: rest.1,
                    askedBy: self.askedBy, approvals: rest.2, provider: model.provider.rawValue
                )
                if LampAgentRemoteChatUpdates.needsSnapshot(from: open.told, to: next),
                   let summary = self.summary(of: open.chat)
                    ?? Optional(self.untitled(open.chat, workspace: open.workspace, isRunning: isRunning)) {
                    // Cleared, or turns undone, on the Mac: start the phone's
                    // copy again rather than patch it.
                    self.send(.snapshot(LampAgentRemoteChatUpdates.snapshot(summary: summary, state: next)), to: peer)
                } else {
                    for event in LampAgentRemoteChatUpdates.events(chatID: open.id, from: open.told, to: next) {
                        self.send(.event(event), to: peer)
                    }
                }
                open.told = next
            }
        }
    }

    private func send(_ message: LampAgentRemoteMessage, from peer: Peer) async {
        guard let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let chatID = message.chatID, let chat = LampAgentRemoteHosting.Chat(id: chatID) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: message.requestID), to: peer)
            return
        }
        let open = peer.open?.chat == chat ? peer.open : open(chatID, for: peer, requestID: nil)
        guard let open else { return }
        await run(
            text, reading: message.reading, selection: message.selection, writingRevision: message.writingRevision,
            writingDigest: message.writingDigest, in: open, requestID: message.requestID, peer: peer
        )
    }

    // MARK: Setup

    /// Each provider's connection as last checked, and when. Checking runs
    /// each CLI's sign-in check in a login shell, and Antigravity's opens a
    /// session, so it is done at most once a few minutes for every phone.
    private var connections: [AIProviderCLI: LampAgentRemoteSetup.Connection] = [:]
    private var checkingConnections: Task<Void, Never>?
    private static let connectionsKeptFor: TimeInterval = 5 * 60

    private static func connection(_ state: AIProviderConnectionState, at date: Date) -> LampAgentRemoteSetup.Connection {
        typealias C = LampAgentRemoteSetup.Connection
        return switch state {
        case .checking: C(state: C.checking)
        case .connected: C(state: C.connected, checkedAt: date)
        case .notInstalled: C(state: C.notInstalled, checkedAt: date)
        case .notConnected: C(state: C.notConnected, checkedAt: date)
        case .unavailable(let reason): C(state: C.unavailable, detail: reason, checkedAt: date)
        }
    }

    private func setup() -> LampAgentRemoteSetup {
        let defaults = UserDefaults.standard
        let providers = AIProviderCLI.allCases.map { provider in
            LampAgentRemoteHosting.setupProvider(
                id: provider.rawValue, name: provider.name, shortName: provider.shortName,
                systemImage: provider.systemImage, wire: provider.wireProvider,
                connection: connections[provider] ?? .init(state: LampAgentRemoteSetup.Connection.checking),
                appDefault: { defaults.string(forKey: $0) }
            )
        }
        let scope = defaults.string(forKey: "agent.moduleAccess.scope")
            .flatMap(AgentModuleAccessScope.init(rawValue:)) ?? .enabledModules
        return LampAgentRemoteSetup(
            providers: providers,
            readerProvider: ReaderChatTurns.appProviderID,
            writingProvider: Self.writingAppProviderID,
            access: .init(
                readOnly: true,
                modulesEnabled: defaults.object(forKey: "agent.moduleAccess.enabled") as? Bool ?? true,
                allModules: scope != .enabledModules,
                personalStudy: defaults.object(forKey: "agent.moduleAccess.personal") as? Bool ?? false
            )
        )
    }

    /// The setup as it stands, at once; then again once any connection not
    /// checked lately has been, if that changed anything.
    private func sendSetup(to peer: Peer, requestID: UUID?) async {
        let sent = setup()
        send(.setup(sent, requestID: requestID), to: peer)
        let now = Date()
        let stale = AIProviderCLI.allCases.filter { provider in
            guard let checked = connections[provider]?.checkedAt else { return true }
            return now.timeIntervalSince(checked) > Self.connectionsKeptFor
        }
        guard !stale.isEmpty else { return }
        if checkingConnections == nil {
            checkingConnections = Task { [weak self] in
                let checked = await withTaskGroup(of: (AIProviderCLI, AIProviderConnectionState).self) { group in
                    for provider in stale {
                        group.addTask { (provider, await AIProviderCommandRunner.connectionState(for: provider)) }
                    }
                    var states: [(AIProviderCLI, AIProviderConnectionState)] = []
                    for await state in group { states.append(state) }
                    return states
                }
                guard let self else { return }
                let at = Date()
                for (provider, state) in checked { self.connections[provider] = Self.connection(state, at: at) }
                self.checkingConnections = nil
            }
        }
        await checkingConnections?.value
        guard isConnected(peer), mayAct(peer) else { return }
        let checked = setup()
        if checked != sent { send(.setup(checked), to: peer) }
    }

    /// Takes a phone's choice into a chat's own choices, and what the app
    /// remembers, as a pick in the chat's menus in a window would.
    private func applyChoices(_ change: LampAgentRemoteChoices, for chat: LampAgentRemoteHosting.Chat, in workspace: URL) throws {
        let defaults = UserDefaults.standard
        // Pinned first, as a pane pins a chat on showing it, so a change of
        // only the model leaves its provider and effort where they were
        // rather than following the next pick made in another chat.
        _ = AgentChatOwnChoices.pinned(in: workspace, appProviderID: Self.appProviderID(for: chat))
        let appProviderKey = switch chat {
        case .reader: "reader.chat.provider"
        case .writing: "devotional.agent.provider"
        }
        let applied = try LampAgentRemoteHosting.applying(
            change, to: AgentChatChoicesStore.load(in: workspace),
            appProviderID: Self.appProviderID(for: chat), appProviderKey: appProviderKey,
            wire: { AIProviderCLI(rawValue: $0)?.wireProvider },
            appDefault: { defaults.string(forKey: $0) }
        )
        try AgentChatChoicesStore.save(applied.choices, in: workspace)
        for (key, value) in applied.remembered { defaults.set(value, forKey: key) }
        AgentChatChoicesStore.announceChange(in: workspace)
    }

    /// A chat moved to another provider, model or effort from a phone. The
    /// runner reads a chat's choices as each turn starts, so a change while
    /// one runs would land only on the next and nothing would say so: it is
    /// refused until the turn ends. Answered with the chat's snapshot under
    /// its new choices, which for another provider is that provider's side of
    /// the conversation, as a window shows it.
    private func setChoices(_ message: LampAgentRemoteMessage, from peer: Peer) {
        // Writes the chat's file and the app's defaults: only for a device
        // still trusted, as a turn is.
        guard mayAct(peer) else { return }
        guard let change = message.choices, let chatID = message.chatID,
              let chat = LampAgentRemoteHosting.Chat(id: chatID), let root = libraryRootURL,
              summary(of: chat) != nil || peer.open?.chat == chat
        else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: message.requestID, chatID: message.chatID), to: peer)
            return
        }
        let workspace = workspace(of: chat, root: root)
        if case .writing(let id) = chat, writing(id)?.isEditable == false {
            send(.failed(LampAgentRemoteFailure.notAllowed, "That writing can't be changed by an assistant.", requestID: message.requestID, chatID: chatID), to: peer)
            return
        }
        guard !KeptAgentChats.isBusy(in: workspace) else {
            send(.failed(LampAgentRemoteFailure.busy, "Wait for the reply to finish, then change who answers.", requestID: message.requestID, chatID: chatID), to: peer)
            return
        }
        do {
            try applyChoices(change, for: chat, in: workspace)
        } catch LampAgentRemoteHosting.ChoiceRefusal.unusableName {
            send(.failed(LampAgentRemoteFailure.notAllowed, "That name can't be used for a model or effort.", requestID: message.requestID, chatID: chatID), to: peer)
            return
        } catch LampAgentRemoteHosting.ChoiceRefusal.effortNeedsModel {
            let name = AIProviderCLI(rawValue: change.provider ?? continuingProvider(for: chat, in: workspace).rawValue)?.shortName ?? "This provider"
            send(.failed(LampAgentRemoteFailure.notAllowed, "Name a model first: \(name) sets effort as a variant of the model.", requestID: message.requestID, chatID: chatID), to: peer)
            return
        } catch {
            send(.failed(LampAgentRemoteFailure.notAllowed, error.localizedDescription, requestID: message.requestID, chatID: chatID), to: peer)
            return
        }
        // The chat followed again, on what it now runs with, by this device
        // and by any other following it: each holds the model of the
        // provider it opened on, and would go on sending to it.
        refollow(chat, for: peer, requestID: message.requestID)
        for other in peers.values where other !== peer && other.open?.chat == chat && isConnected(other) {
            refollow(chat, for: other, requestID: nil)
        }
    }

    private static func choices(of summary: LampAgentRemoteChatSummary) -> [String?] {
        [summary.provider, summary.model, summary.effort]
    }

    /// A chat's choices were saved, by a window's menus or by this host: each
    /// device following it is told, unless it already has been, and
    /// follows it again under another provider.
    private func choicesSaved(inWorkspaceAt path: String) {
        for peer in peers.values where isConnected(peer) {
            guard let open = peer.open, open.workspace.standardizedFileURL.path == path else { continue }
            // From the choices file alone, as a summary would say them, so a
            // window's every pick doesn't read the chat's transcripts here.
            let provider = continuingProvider(for: open.chat, in: open.workspace)
            let chosen = LampAgentRemoteHosting.chosen(
                in: AgentChatChoicesStore.load(in: open.workspace), provider: provider.wireProvider,
                appDefault: { UserDefaults.standard.string(forKey: $0) }
            )
            if [provider.rawValue, chosen.model, chosen.effort] != open.toldChoices {
                refollow(open.chat, for: peer, requestID: nil)
            }
        }
    }

    /// Follows a chat again under its current choices: a chat cleared on this
    /// Mac while followed has no summary, and is followed as untitled.
    private func refollow(_ chat: LampAgentRemoteHosting.Chat, for peer: Peer, requestID: UUID?) {
        do {
            let (model, workspace) = try model(for: chat)
            let summary = summary(of: chat) ?? untitled(chat, workspace: workspace, isRunning: model.isRunning)
            _ = follow(OpenChat(chat: chat, workspace: workspace, model: model), summary: summary, for: peer, requestID: requestID)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: chat.id), to: peer)
        }
    }

    private func startChat(_ message: LampAgentRemoteMessage, from peer: Peer) async {
        guard let newChat = message.newChat,
              [LampAgentRemoteChatSummary.reader, LampAgentRemoteChatSummary.writing].contains(newChat.kind) else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "Only reader and writing chats can be started from a device.", requestID: message.requestID), to: peer)
            return
        }
        let first = newChat.firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "Write something to start the chat.", requestID: message.requestID), to: peer)
            return
        }
        // Before anything is saved: a refused name leaves the chat as it was.
        guard [newChat.model, newChat.effort].allSatisfy({ name in
            name.map { LampAgentRemoteHosting.isUsableName($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? true
        }) else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "That name can't be used for a model or effort.", requestID: message.requestID), to: peer)
            return
        }
        guard let root = libraryRootURL else { return }
        let chat: LampAgentRemoteHosting.Chat
        if newChat.kind == LampAgentRemoteChatSummary.writing {
            guard let writingID = newChat.writingID,
                  await isCurrent(
                      writingID, revision: newChat.writingRevision, digest: newChat.writingDigest,
                      requestID: message.requestID, peer: peer
                  )
            else {
                if newChat.writingID == nil {
                    send(.failed(LampAgentRemoteFailure.notFound, "That writing isn't on this Mac.", requestID: message.requestID), to: peer)
                }
                return
            }
            chat = .writing(writingID)
        } else {
            chat = .reader(UUID())
        }
        // A writing has one chat: asking again goes on in it.
        if let open = peer.open, open.chat == chat {
            await run(
                first, reading: newChat.reading, selection: newChat.selection, writingRevision: newChat.writingRevision,
                writingDigest: newChat.writingDigest, in: open, requestID: message.requestID, peer: peer
            )
            return
        }
        let workspace = workspace(of: chat, root: root)
        do {
            if case .writing(let id) = chat {
                // The workspace made before anything is chosen in it, as the
                // writing's pane makes it on opening.
                guard try await prepareWriting(
                    id, revision: newChat.writingRevision, digest: newChat.writingDigest,
                    requestID: message.requestID, peer: peer
                ) else { return }
            }
            guard !Task.isCancelled, mayAct(peer) else { return }
            // The provider chosen is the chat's own, pinned as the pane pins
            // it, so the chat opens on it in a window too. A writing keeps
            // the provider it has unless the phone names one for a chat
            // nothing was said in yet: its pane may have pinned one already.
            let chosen = newChat.provider.flatMap(AIProviderCLI.init(rawValue:))
            let isWriting = if case .writing = chat { true } else { false }
            // New: nothing said in it, and no first turn on its way from a
            // window or another device, whose choices these would overwrite.
            let isNew = summary(of: chat) == nil && !KeptAgentChats.isBusy(in: workspace)
            if isNew, chosen != nil || !isWriting {
                let provider = chosen
                    ?? AIProviderCLI(rawValue: Self.appProviderID(for: chat)) ?? .codex
                var choices = AgentChatChoicesStore.load(in: workspace)
                choices.set(provider.rawValue, for: AgentChatChoices.providerKey)
                try AgentChatChoicesStore.save(choices, in: workspace)
                _ = AgentChatOwnChoices.pinned(in: workspace, appProviderID: provider.rawValue)
                // A pane open on the empty chat follows it to that provider.
                AgentChatChoicesStore.announceChange(in: workspace)
            }
            // And the model and effort the phone opened it on, as though
            // picked in the chat's menus once it was made: a writing's too,
            // on whichever provider it has.
            let picked = LampAgentRemoteChoices(model: newChat.model, effort: newChat.effort)
            if isNew, !picked.isEmpty {
                do {
                    try applyChoices(picked, for: chat, in: workspace)
                } catch LampAgentRemoteHosting.ChoiceRefusal.effortNeedsModel {
                    // The chat still starts, on the model's default.
                }
            }

            let (model, _) = try model(for: chat)
            let summary = summary(of: chat)
                ?? untitled(chat, workspace: workspace, title: ReaderChatWorkspaceStore.label(first), isRunning: false)
            // The snapshot before anything streams, so every event after it
            // is for a chat the phone already holds.
            let open = follow(OpenChat(chat: chat, workspace: workspace, model: model), summary: summary, for: peer, requestID: message.requestID)
            await run(
                first, reading: newChat.reading, selection: newChat.selection, writingRevision: newChat.writingRevision,
                writingDigest: newChat.writingDigest, in: open, requestID: message.requestID, peer: peer
            )
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: message.requestID), to: peer)
        }
    }

    /// Sends a turn through the chat's model, as a window would send it: a
    /// reader turn with the passage the phone is reading, a writing turn with
    /// what is selected in it and what is still marked. Checked again just
    /// before it goes, since preparing it waits, and the device may have been
    /// forgotten or the host turned off meanwhile.
    private func run(
        _ text: String, reading: LampAgentRemoteReading?, selection: String?, writingRevision: Int?,
        writingDigest: String?, in open: OpenChat, requestID: UUID?, peer: Peer
    ) async {
        guard !open.model.isRunning else {
            send(.failed(LampAgentRemoteFailure.busy, "A reply is still arriving in this chat.", requestID: requestID, chatID: open.id), to: peer)
            return
        }
        // Held from here, while the prompt is prepared and before the model
        // says it is running, so a change of provider from another device
        // can't move the chat out from under the turn (`setChoices`).
        KeptAgentChats.beginTurn(in: open.workspace)
        defer { KeptAgentChats.endTurn(in: open.workspace) }
        let conversation = open.model.conversationID
        let prompt: String
        switch open.chat {
        case .reader:
            do {
                // Every turn, whether or not it names a passage: the helper
                // reads this file on each call, and access may have narrowed
                // since.
                try writePolicy(for: open.chat, in: open.workspace)
            } catch {
                send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: open.id), to: peer)
                return
            }
            prompt = await contextualPrompt(text, reading: reading)
        case .writing(let id):
            guard let written = await writingPrompt(
                text, selection: selection, writingID: id, revision: writingRevision, digest: writingDigest,
                in: open, requestID: requestID, peer: peer
            ) else { return }
            prompt = written
        }
        guard !Task.isCancelled, mayAct(peer), let device = peer.deviceID else { return }
        // The question's id is chosen here, so the turn is known as this
        // device's for as long as it runs, and no longer.
        let turn = UUID()
        runs[device, default: []].append((open.model, turn))
        if let requestID { remember(requestID, asked: turn) }
        let collecting = collectWhileRunning(open)
        // Counted from before the run to after its last collection, so a
        // quit waits for what the turn wrote to be saved and marked rather
        // than for a count that is zero between the marks and the save.
        LampPendingWrites.shared.begin()
        defer { LampPendingWrites.shared.end() }
        // No notification on this Mac when it ends: whoever asked is on the
        // phone, which follows the reply as it arrives.
        let taken = await open.model.send(
            text, contextualPrompt: prompt, messageID: turn, inConversation: conversation,
            notifiesWhenDone: false
        )
        // How it ended, read now: the collecting below waits, and a turn
        // started in that wait, from this Mac or another phone, clears it.
        let outcome = taken ? open.model.lastTurnOutcome : nil
        let endedAt = Date()
        // A poll part way through saving finishes before the last one looks,
        // or the last would read the writing from before that save.
        collecting?.cancel()
        await collecting?.value
        // Checked before the turn is taken: taking it is once only, and a
        // window watching the writing files the change under it.
        if case .writing(let id) = open.chat, let libraryModel, !WritingChatTurns.isWatched(id) {
            // Once more as it ends: a run's last write lands just before it
            // exits, after the last poll.
            _ = try? await WritingChatTurns.collect(
                writingID: id, turnID: open.model.takeTurnForAttribution() ?? turn, libraryModel: libraryModel
            )
        }
        // Told through iCloud whether or not the phone still looks
        // connected (`AgentTurnPush`): iOS can suspend Lamp with its socket
        // left open, so being in `peers` is no proof the phone heard the
        // end. A phone that did hear it knows the turn id and lets the push
        // go unshown.
        // Asked again here, not when the turn began: the device may have
        // been forgotten, or remote chats turned off, during the collect,
        // and a reply's words must not go to a phone that is no longer
        // trusted. No live connection is asked for; that is the point.
        if let outcome, mayStillPush(to: device) {
            AgentTurnPush.tell(
                pushedEnd(of: open.chat, turn: turn, device: device, outcome: outcome, endedAt: endedAt),
                stillAllowed: { [weak self] in self?.mayStillPush(to: device) ?? false },
                pairedDevices: devices.map(\.id)
            )
        }
        runs[device]?.removeAll { $0.turn == turn }
        if runs[device]?.isEmpty == true { runs[device] = nil }
        if !taken, isConnected(peer), peer.open === open {
            send(.failed(LampAgentRemoteFailure.busy, "This chat changed on the Mac before the message could go.", requestID: requestID, chatID: open.id), to: peer)
        }
    }

    /// Makes a writing's workspace ready for a turn, as its pane does on
    /// opening: under the policy as it is now, and holding the writing as it
    /// is now, which may have moved since the last turn, by sync or in a
    /// window. False, having said why, where there is nothing to do it on or
    /// a turn is running in it; false and silent where the device may no
    /// longer act, checked before each change, since the request may have
    /// been cancelled while it waited.
    ///
    /// Never while a turn runs: levelling the draft then would take that
    /// turn's work in under no turn, and an undo of it would leave it behind.
    private func prepareWriting(
        _ id: String, revision: Int?, digest: String?, requestID: UUID?, peer: Peer
    ) async throws -> Bool {
        let chatID = LampAgentRemoteHosting.Chat.writing(id).id
        guard !Task.isCancelled, mayAct(peer),
              await isCurrent(id, revision: revision, digest: digest, requestID: requestID, peer: peer),
              !Task.isCancelled, mayAct(peer)
        else { return false }
        guard let libraryModel, let writing = writing(id) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That writing isn't on this Mac.", requestID: requestID, chatID: chatID), to: peer)
            return false
        }
        guard writing.isEditable else {
            send(.failed(LampAgentRemoteFailure.notAllowed, "This writing came with a module, so the assistant can't change it.", requestID: requestID, chatID: chatID), to: peer)
            return false
        }
        let workspace = LampWritingWorkspace.url(libraryRootURL: libraryModel.library.rootURL, writingID: id)
        func idle() -> Bool {
            guard !KeptAgentChats.isRunning(in: workspace) else {
                send(.failed(LampAgentRemoteFailure.busy, "A reply is still arriving in this chat.", requestID: requestID, chatID: chatID), to: peer)
                return false
            }
            return true
        }
        guard idle() else { return false }
        _ = try await WritingChatTurns.prepare(
            writingID: id,
            draft: writing.displayMarkdown,
            context: WritingChatTurns.contextDocument(for: writing),
            policy: ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel),
            libraryRootURL: libraryModel.library.rootURL,
            bundledModulesArchiveURL: Bundle.main.url(forResource: "bundled_modules.db", withExtension: "zlib")
        )
        guard !Task.isCancelled, mayAct(peer), idle() else { return false }
        try await WritingChatTurns.begin(writingID: id, turnID: nil, libraryModel: libraryModel)
        return !Task.isCancelled && mayAct(peer)
    }

    /// Whether this Mac holds the writing at least as new as the copy the
    /// phone asked about. Where it is older or missing, what sync has is
    /// taken in first: the phone saves and syncs before it asks, but this
    /// Mac only sees that at its own next pass. Still behind after that, the
    /// turn is refused rather than run on a text the writer has since
    /// changed, whose result would sync back over their edits. False,
    /// having said why, where it is behind or not here.
    private func isCurrent(_ id: String, revision: Int?, digest: String?, requestID: UUID?, peer: Peer) async -> Bool {
        let chatID = LampAgentRemoteHosting.Chat.writing(id).id
        // A copy here that was never dated cannot be compared, and goes on
        // as a turn always has. Only an older copy refuses; one that holds
        // something else in the same second is fetched for, and goes on.
        func behind(fetching: Bool) -> Bool {
            guard let held = writing(id) else { return revision != nil }
            guard let saved = held.lastModified else { return false }
            return fetching
                ? LampAgentRemoteWritingRevision.hostShouldFetch(
                    host: saved, hostDigest: LampAgentRemoteWritingRevision.digest(of: held),
                    device: revision, deviceDigest: digest
                )
                : LampAgentRemoteWritingRevision.hostIsBehind(host: saved, device: revision)
        }
        // After a pull, a copy still not the phone's — older, or of the same
        // second holding something else — is refused too: the pull may have
        // been queued behind offloads and not run yet, and a turn on this
        // copy would save its result over the phone's edit. Retryable; the
        // next ask finds the pass done.
        var pulled = false
        if behind(fetching: true), let pull {
            await pull()
            pulled = true
        }
        if behind(fetching: false) || (pulled && behind(fetching: true)) {
            send(.failed(
                LampAgentRemoteFailure.writingBehind,
                "This Mac doesn't have your latest edits to this writing yet.",
                requestID: requestID, chatID: chatID
            ), to: peer)
            return false
        }
        guard writing(id) != nil else {
            send(.failed(LampAgentRemoteFailure.notFound, "That writing isn't on this Mac.", requestID: requestID, chatID: chatID), to: peer)
            return false
        }
        // An editor open on the writing keeps the copy it loaded or last
        // saved, whatever sync brings in since, and the turn would run on
        // that copy and the editor save it back over the phone's edits.
        // Every open copy is asked about, since two of one second can hold
        // different texts: none may be older than the phone's, or of the
        // same second and holding something else.
        let stale = WritingChatTurns.watchedCopies(id).contains { open in
            LampAgentRemoteWritingRevision.hostIsBehind(host: open.revision, device: revision)
                || (revision == LampAgentRemoteWritingRevision.of(lastModified: open.revision)
                    && digest != nil && open.digest != nil && open.digest != digest)
        }
        if stale {
            send(.failed(
                LampAgentRemoteFailure.writingBehind,
                "This writing is open on the Mac with an older copy. Close it there, then try again.",
                requestID: requestID, chatID: chatID
            ), to: peer)
            return false
        }
        return true
    }

    /// A writing turn's message as the provider is sent it: with the words
    /// selected on the phone, as the visual editor would show them, and what
    /// is still marked for the writer to read.
    private func writingPrompt(
        _ text: String, selection: String?, writingID: String, revision: Int?, digest: String?,
        in open: OpenChat, requestID: UUID?, peer: Peer
    ) async -> String? {
        do {
            guard try await prepareWriting(writingID, revision: revision, digest: digest, requestID: requestID, peer: peer)
            else { return nil }
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: open.id), to: peer)
            return nil
        }
        guard let libraryModel, let writing = writing(writingID) else { return nil }
        let root = libraryModel.library.rootURL
        let focus = WritingEditorFocus(
            documentPath: "draft.md", documentName: writing.title, isVisual: false,
            selectedText: selection?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // Read off the main actor: the review file's lock can be held by a
        // carry or a marking comparing whole drafts, and waiting for it here
        // would hold up the Mac's own windows.
        let store = WritingReviewMarks.store(libraryRootURL: root)
        let workspace = open.workspace
        let known = WritingReviewTexts.shared.known(for: writingID)
        let fallback = writing.displayMarkdown
        let note = await Task.detached(priority: .userInitiated) { () -> String? in
            let review = try? store?.review(writingID: writingID)
            let draft = (try? await DevotionalAgentWorkspaceStore.readDraft(from: workspace)) ?? fallback
            return WritingChatTurns.reviewNote(review ?? nil, marksAreOn: store != nil, in: draft, known: known)
        }.value
        return WritingChatTurns.prompt(for: text, focus: focus, note: note)
    }

    /// Takes in what a writing turn writes as it writes it, as the writing's
    /// window does by its poll: so a window opened meanwhile, or the phone
    /// by sync, sees the work arrive rather than all at the end. Nil for a
    /// reader chat, which writes nothing.
    private func collectWhileRunning(_ open: OpenChat) -> Task<Void, Never>? {
        guard case .writing(let id) = open.chat, let libraryModel else { return nil }
        return Task { [weak libraryModel, model = open.model] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let libraryModel else { return }
                guard !WritingChatTurns.isWatched(id) else { continue }
                _ = try? await WritingChatTurns.collect(
                    writingID: id, turnID: model.takeTurnForAttribution() ?? model.currentTurn, libraryModel: libraryModel
                )
            }
        }
    }

    private func remember(_ requestID: UUID, asked question: UUID) {
        askedBy[question] = requestID
        askedOrder.append(question)
        while askedOrder.count > 64 { askedBy[askedOrder.removeFirst()] = nil }
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

    private func refreshTailnetAddresses() {
        let addresses = listener?.port.map { LampAgentRemoteTailnet.addresses(port: $0.rawValue) } ?? []
        if addresses != tailnetAddresses { tailnetAddresses = addresses }
    }

    private func publishConnected() {
        connectedNames = peers.values.filter { $0.deviceID != nil }.map(\.name).sorted()
        guard listener != nil else { return }
        if case .failed = status { return }
        status = connectedNames.isEmpty ? .waiting : .connected
    }
}
