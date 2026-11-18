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
/// and a chat's traffic is a person typing and a reply arriving.
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
    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    private weak var libraryModel: LibraryModel?

    private var settingsObserver: AnyCancellable?

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
        update(aiEnabled: AIFeatures.isEnabledNow, enabled: UserDefaults.standard.bool(forKey: Self.enabledKey))
    }

    /// Running exactly while it should be: the AI switch on, and this
    /// setting.
    func update(aiEnabled: Bool, enabled: Bool) {
        if aiEnabled, enabled { start() } else { stop() }
    }

    // MARK: Pairing and devices

    /// Reads the paired devices: on demand, never at launch, so the keychain
    /// is not asked with nothing on screen to say why.
    func refreshDevices() {
        let trust = trust
        trustQueue.async { [weak self] in
            let devices = trust.devices()
            let credentials = trust.credentials()
            let secret = trust.hostSecret()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.devices = devices
                    self.knownCredentials = credentials
                    self.knownHostSecret = secret
                }
            }
        }
    }

    func beginPairing() {
        pairing = LampAgentRemotePairingWindow()
    }

    func endPairing() {
        pairing = nil
    }

    func forget(_ device: LampAgentRemotePairedDevice) {
        // Refused at once, before the keychain catches up.
        knownCredentials.removeAll { $0.kind == .device(id: device.id) }
        for peer in Array(peers.values) where peer.deviceID == device.id { close(peer) }
        let trust = trust
        trustQueue.async { trust.forget(deviceID: device.id) }
        refreshDevices()
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
            // Told why, where it can be: the switch went off under it.
            send(.failed(LampAgentRemoteFailure.aiOff, "Chats from this Mac are turned off."), to: peer)
            close(peer)
        }
        status = .off
        connectedNames = []
    }

    // MARK: A connection

    private final class Peer {
        let connection: NWConnection
        var buffer = Data()
        let start: LampAgentRemoteHandshake.HostStart
        var channel: LampAgentRemoteSecureChannel?
        var deviceID: String?
        var name = "Device"
        var open: OpenChat?

        init(connection: NWConnection, start: LampAgentRemoteHandshake.HostStart) {
            self.connection = connection
            self.start = start
        }
    }

    /// A chat a device has open: the model it follows, and what it was last
    /// told, to tell it only what changed.
    private final class OpenChat {
        let id: UUID
        let workspace: URL
        let model: NativeAgentChatModel
        var told = LampAgentRemoteHosting.ChatState()
        var watching: AnyCancellable?

        init(id: UUID, workspace: URL, model: NativeAgentChatModel) {
            self.id = id
            self.workspace = workspace
            self.model = model
        }
    }

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection: connection, start: LampAgentRemoteHandshake.hostStart(hostSecret: knownHostSecret))
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
        if let hello = try? LampAgentRemoteFraming.encode(peer.start.hello) {
            connection.send(content: hello, completion: .contentProcessed { _ in })
        }
        receive(from: peer)
    }

    private func receive(from peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1_024) { [weak self, weak peer] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let peer else { return }
                if let data, !data.isEmpty {
                    peer.buffer.append(data)
                    guard self.read(peer) else { return }
                }
                if isComplete || error != nil {
                    self.close(peer)
                } else {
                    self.receive(from: peer)
                }
            }
        }
    }

    /// Everything complete in the peer's buffer. False if the connection was
    /// closed for what it said.
    private func read(_ peer: Peer) -> Bool {
        do {
            if peer.channel == nil {
                guard let auth = try LampAgentRemoteFraming.decode(LampAgentRemoteAuth.self, from: &peer.buffer) else {
                    return true
                }
                try authenticate(peer, auth)
            }
            guard let channel = peer.channel else { return true }
            for message in try channel.open(from: &peer.buffer) {
                handle(message, from: peer)
            }
            return true
        } catch {
            close(peer)
            return false
        }
    }

    private func authenticate(_ peer: Peer, _ auth: LampAgentRemoteAuth) throws {
        let pairingCredential = pairing?.credential
        let candidates = knownCredentials + (pairingCredential.map { [$0] } ?? [])
        let accepted: (credential: LampAgentRemoteCredential, channel: LampAgentRemoteSecureChannel)
        do {
            accepted = try LampAgentRemoteHandshake.accept(auth, start: peer.start, candidates: candidates)
        } catch {
            // A proof that fit no key counts against an open pairing code.
            pairing?.failed()
            throw error
        }
        peer.channel = accepted.channel
        switch accepted.credential.kind {
        case .pairing:
            // Spent the moment it pairs: a code is for one device.
            pairing?.paired()
            // Minted and kept off the main thread; the device waits for
            // `accepted` before it says anything else.
            let trust = trust
            trustQueue.async { [weak self, weak peer] in
                let minted = trust.pair(name: nil)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, let peer else { return }
                        peer.deviceID = minted.credential.deviceID
                        self.send(.accepted(pairing: minted.credential, hostSecret: minted.hostSecret), to: peer)
                        self.refreshDevices()
                        self.publishConnected()
                    }
                }
            }
        case .device(let id):
            peer.deviceID = id
            peer.name = devices.first { $0.id == id }?.name ?? peer.name
            send(.accepted(), to: peer)
        }
        publishConnected()
    }

    private func handle(_ message: LampAgentRemoteMessage, from peer: Peer) {
        guard AIFeatures.isEnabledNow else {
            send(.failed(LampAgentRemoteFailure.aiOff, "AI features are turned off on this Mac.", requestID: message.requestID), to: peer)
            return
        }
        switch message.kind {
        case .introduce:
            if let name = message.clientName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                peer.name = String(name.prefix(80))
                if let id = peer.deviceID {
                    let trust = trust, name = peer.name
                    trustQueue.async { trust.rename(deviceID: id, name: name) }
                }
                refreshDevices()
                publishConnected()
            }
        case .listChats:
            send(.chats(summaries(), requestID: message.requestID), to: peer)
        case .openChat:
            open(message.chatID, for: peer, requestID: message.requestID)
        case .closeChat:
            peer.open = nil
        case .send:
            Task { await self.send(message, from: peer) }
        case .cancel:
            guard let open = peer.open, message.chatID == open.id.uuidString else {
                send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't open.", requestID: message.requestID), to: peer)
                return
            }
            open.model.cancel()
        case .startChat:
            Task { await self.startChat(message, from: peer) }
        case .ping:
            send(.pong, to: peer)
        default:
            // A kind from a newer phone, or one only a host sends.
            break
        }
    }

    // MARK: Chats

    private var libraryRootURL: URL? { libraryModel?.library.rootURL }

    private func appProvider() -> AIProviderCLI {
        AIProviderCLI(rawValue: ReaderChatTurns.appProviderID) ?? .codex
    }

    private static func hostingProvider(_ provider: AIProviderCLI) -> LampAgentRemoteHosting.Provider {
        .init(id: provider.rawValue, name: provider.name)
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
            appProvider: Self.hostingProvider(appProvider()),
            isRunning: KeptAgentChats.isRunning(in: workspace)
        )
    }

    private func summaries() -> [LampAgentRemoteChatSummary] {
        guard let root = libraryRootURL else { return [] }
        return ReaderChatWorkspaceStore.chats(libraryRootURL: root).compactMap { summary(of: $0.id) }
    }

    /// The model a chat runs in, made ready: the same one a window on this
    /// chat uses, if one is open.
    private func model(for id: UUID, provider requested: AIProviderCLI? = nil) throws -> (model: NativeAgentChatModel, workspace: URL) {
        guard let libraryModel, let root = libraryRootURL else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The library isn't open yet."])
        }
        let workspace = ReaderChatWorkspaceStore.workspaceURL(libraryRootURL: root, chatID: id)
        let provider = requested
            ?? LampAgentRemoteHosting.current(transcripts(in: workspace)).flatMap { AIProviderCLI(rawValue: $0.provider.id) }
            ?? appProvider()
        let configuration = try ReaderChatTurns.prepare(
            workspace: workspace,
            policy: ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel),
            libraryRootURL: root
        )
        let model = KeptAgentChats.model(provider: provider, workspace: workspace, mode: .reader(configuration))
        model.load()
        return (model, workspace)
    }

    private func open(_ chatID: String?, for peer: Peer, requestID: UUID?) {
        guard let chatID, let id = UUID(uuidString: chatID), let summary = summary(of: id) else {
            send(.failed(LampAgentRemoteFailure.notFound, "That chat isn't on this Mac.", requestID: requestID, chatID: chatID), to: peer)
            return
        }
        do {
            let (model, workspace) = try model(for: id)
            let open = OpenChat(id: id, workspace: workspace, model: model)
            open.told = Self.state(of: model)
            peer.open = open
            send(.snapshot(LampAgentRemoteHosting.snapshot(summary: summary, state: open.told), requestID: requestID), to: peer)
            watch(open, for: peer)
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: requestID, chatID: chatID), to: peer)
        }
    }

    private static func state(of model: NativeAgentChatModel) -> LampAgentRemoteHosting.ChatState {
        state(
            messages: model.messages, arriving: model.arrivingReply, activity: model.activity,
            isRunning: model.isRunning, failure: model.errorMessage
        )
    }

    private static func state(
        messages: [NativeAgentChatMessage], arriving: String, activity: AgentChatActivity?,
        isRunning: Bool, failure: String?
    ) -> LampAgentRemoteHosting.ChatState {
        LampAgentRemoteHosting.ChatState(
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
        // taken together with the rest of the same change: told apart, the
        // phone heard a turn begin with no question and end before its
        // answer.
        .debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
        .sink { [weak self, weak peer, weak open] messages, isRunning, activity, rest in
            MainActor.assumeIsolated {
                guard let self, let peer, let open, peer.open === open else { return }
                let next = Self.state(
                    messages: messages, arriving: rest.0, activity: activity, isRunning: isRunning, failure: rest.1
                )
                for event in LampAgentRemoteHosting.events(chatID: open.id.uuidString, from: open.told, to: next) {
                    self.send(.event(event), to: peer)
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
        if peer.open?.id != id { open(chatID, for: peer, requestID: nil) }
        guard let open = peer.open, open.id == id else { return }
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
        let id = UUID()
        do {
            let (model, workspace) = try model(for: id, provider: newChat.provider.flatMap(AIProviderCLI.init(rawValue:)))
            let open = OpenChat(id: id, workspace: workspace, model: model)
            open.told = Self.state(of: model)
            peer.open = open
            watch(open, for: peer)
            await run(first, reading: newChat.reading, in: open, requestID: message.requestID, peer: peer)
            if let summary = summary(of: id) {
                send(.snapshot(LampAgentRemoteHosting.snapshot(summary: summary, state: Self.state(of: model)), requestID: message.requestID), to: peer)
            }
        } catch {
            send(.failed(LampAgentRemoteFailure.needsSetup, error.localizedDescription, requestID: message.requestID), to: peer)
        }
    }

    /// Sends a turn through the chat's model, with the passage the phone is
    /// reading, as a window would send it.
    private func run(_ text: String, reading: LampAgentRemoteReading?, in open: OpenChat, requestID: UUID?, peer: Peer) async {
        guard !open.model.isRunning else {
            send(.failed(LampAgentRemoteFailure.busy, "A reply is still arriving in this chat.", requestID: requestID, chatID: open.id.uuidString), to: peer)
            return
        }
        let conversation = open.model.conversationID
        let prompt = await contextualPrompt(text, reading: reading, workspace: open.workspace)
        let taken = await open.model.send(text, contextualPrompt: prompt, inConversation: conversation)
        if !taken {
            send(.failed(LampAgentRemoteFailure.busy, "This chat changed on the Mac before the message could go.", requestID: requestID, chatID: open.id.uuidString), to: peer)
        }
    }

    /// The question with the passage it was asked over, by ids the phone
    /// sent: the notes and highlights are this Mac's own, read under its own
    /// policy. A question with no passage goes as it is.
    private func contextualPrompt(_ text: String, reading: LampAgentRemoteReading?, workspace: URL) async -> String {
        guard let libraryModel, let reference = reading?.verse ?? reading?.chapter,
              let translation = libraryModel.translations.first(where: { $0.id == reading?.translationID })
                ?? libraryModel.translations.first
        else { return text }
        let book = reference / 1_000_000, chapterNumber = reference / 1_000 % 1_000
        guard let chapter = try? await libraryModel.library.chapter(
            moduleID: translation.id, bookNumber: book, chapterNumber: chapterNumber
        ) else { return text }
        let policy = ReaderChatTurns.currentAccessPolicy(libraryModel: libraryModel)
        try? ReaderChatTurns.writeAccessPolicy(policy, workspace: workspace)
        let capture = ReaderChatTurns.capture(
            book: chapter.book,
            chapter: chapterNumber,
            translation: translation,
            selectedVerse: reading?.verse,
            selection: nil,
            chapterVerses: chapter.verses,
            policy: policy,
            libraryModel: libraryModel
        )
        let notes = await ReaderChatTurns.notes(on: capture.noteReferences, libraryModel: libraryModel)
        return capture.context(notes: notes).prompt(for: text)
    }

    // MARK: Sending

    private func send(_ message: LampAgentRemoteMessage, to peer: Peer) {
        guard let channel = peer.channel, let frame = try? channel.seal(message) else { return }
        peer.connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func close(_ peer: Peer) {
        peer.open = nil
        peers.removeValue(forKey: ObjectIdentifier(peer.connection))
        peer.connection.cancel()
        publishConnected()
    }

    private func publishConnected() {
        connectedNames = peers.values.filter { $0.channel != nil }.map(\.name).sorted()
        guard listener != nil else { return }
        if case .failed = status { return }
        status = connectedNames.isEmpty ? .waiting : .connected
    }
}
