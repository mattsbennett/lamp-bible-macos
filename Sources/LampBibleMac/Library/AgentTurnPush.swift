import CloudKit
import Foundation
import os
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import Security

/// Tells a paired phone that a turn it asked for has ended, through a record
/// in the reader's own iCloud private database, which the phone subscribes
/// to. The phone is suspended a little while after it is left, and a reply
/// can take minutes; the connection it asked on is gone by then.
///
/// The phone owns the subscription and the alert it shows; this side only
/// writes the record. Its shape is agreed with the phone (iOS ios-6b):
///
/// - type `AgentTurnEnded`, default zone, named `turn.<deviceID>.<chatID>`
///   and saved whole, so a chat's next turn overwrites its last; the phone
///   reads the device and chat from that name when a push leaves the
///   fields out, so the name's form is part of the agreement;
/// - `deviceID` (the pairing's, queryable), `chatID`, `kind` ("reader" or
///   "writing"), `writingID` (writing chats), `turnID`, which the phone
///   matches against a turn end it already heard;
/// - `title` and `subtitle` as the phone shows the chat, subtitle always
///   written, empty or not;
/// - `outcome` ("replied", "failed", "stopped"), `summary` (the body with
///   no reply text), `body` (the reply's opening where the Mac's "Show the
///   start of the reply" allows it, else the summary), `endedAt`.
///
/// Inert without the iCloud entitlement: making a CloudKit container in an
/// app that is not entitled to it stops the app, so nothing here touches
/// CloudKit until the signature says it may.
@MainActor
enum AgentTurnPush {
    nonisolated static let containerIdentifier = "iCloud.com.neus.lamp-bible"
    nonisolated static let recordType = "AgentTurnEnded"
    /// Where a save or sweep that fails says why: best effort is not silent.
    /// Read with `log show --predicate 'subsystem == "com.neus.Lamp-Bible.macOS"
    /// AND category == "turn-push"'`.
    nonisolated private static let log = Logger(subsystem: "com.neus.Lamp-Bible.macOS", category: "turn-push")

    /// What one ended turn says, worked out by the host that ran it.
    struct Ended: Equatable, Sendable {
        var deviceID: String
        var chat: LampAgentRemoteHosting.Chat
        var turnID: UUID
        var title: String
        var subtitle: String
        var outcome: AgentTurnNotifications.Outcome
        /// When the turn ended, taken as its send returned: what orders two
        /// turns of one chat whose pushes are asked for out of turn.
        var endedAt: Date
    }

    /// Whether this build may use the container: signed with CloudKit and
    /// with this container among its iCloud containers.
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        func strings(_ key: String) -> [String] {
            SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? [String] ?? []
        }
        return strings("com.apple.developer.icloud-services").contains("CloudKit")
            && strings("com.apple.developer.icloud-container-identifiers").contains(containerIdentifier)
    }()

    private static var sweptThisLaunch = false
    /// Every save and sweep in the order asked for, one after another. Two
    /// turns in one chat ending close together would otherwise race, and
    /// a whole-record save ignores change tags, so the older could land
    /// last; and a sweep could delete a record refreshed after it looked.
    private static var tail: Task<Void, Never>?
    /// The latest turn end asked for, by record. A writing turn's push waits
    /// on its collect, in which a later turn of the same chat can end and be
    /// pushed first; the line keeps the order asked for, not the order the
    /// turns ended in, so an older end is refused here.
    private static var latestEnd: [String: Date] = [:]

    /// Writes the record, best effort: a Mac not signed in to iCloud, or
    /// offline, leaves the phone to find the reply when it is next opened.
    ///
    /// `stillAllowed` is asked again once the save's turn in the line comes,
    /// since a slow save ahead of it can outlast the device's trust or the
    /// remote setting. `pairedDevices` bounds the sweep to this Mac's own
    /// phones, so a second Mac on the account keeps its records.
    static func tell(
        _ ended: Ended,
        stillAllowed: @escaping @MainActor () -> Bool,
        pairedDevices: [String]
    ) {
        guard isEntitled, AIFeatures.isEnabledNow, !KeptAgentChats.isQuitting else { return }
        let name = recordName(for: ended)
        if let latest = latestEnd[name], latest >= ended.endedAt { return }
        latestEnd[name] = ended.endedAt
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let sweeps = !sweptThisLaunch
        sweptThisLaunch = true
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            // Made now, not when asked for: the setting for the reply's
            // words is read as it stands when the record is written, so one
            // turned off while this waited is honoured.
            let record: CKRecord? = await MainActor.run {
                guard stillAllowed(), AIFeatures.isEnabledNow, !KeptAgentChats.isQuitting else { return nil }
                return Self.record(for: ended, showsReply: AgentTurnNotifications.showsReplyNow)
            }
            if let record { await save(record, to: database) }
            if sweeps { await sweep(database, devices: pairedDevices) }
        }
        clearPending()
    }

    /// The record for one ended turn. Without the reply allowed, the reply's
    /// words are not written at all, not merely left unshown.
    static func recordName(for ended: Ended) -> String {
        "turn.\(ended.deviceID).\(ended.chat.id)"
    }

    static func record(for ended: Ended, showsReply: Bool) -> CKRecord {
        let chatID = ended.chat.id
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: recordName(for: ended))
        )
        let summary = AgentTurnNotifications.body(for: ended.outcome, showsReply: false)
        record["deviceID"] = ended.deviceID
        record["chatID"] = chatID
        switch ended.chat {
        case .reader:
            record["kind"] = "reader"
        case .writing(let id):
            record["kind"] = "writing"
            record["writingID"] = id
        }
        record["turnID"] = ended.turnID.uuidString
        record["title"] = ended.title
        record["subtitle"] = ended.subtitle
        record["outcome"] = outcomeName(ended.outcome)
        record["summary"] = summary
        record["body"] = showsReply ? AgentTurnNotifications.body(for: ended.outcome, showsReply: true) : summary
        record["endedAt"] = ended.endedAt
        return record
    }

    // MARK: - A turn waiting on the person

    /// What a turn waiting on the person tells the phone that asked for it
    /// (`decisions/0045`), on the same record type as an end, with its
    /// fields only, so no schema changes and a shipped phone alerts: named
    /// `wait.<deviceID>.<chatID>`, which is how the phone tells it from an
    /// end, with a `turnID` of its own, never the turn's, so a phone that
    /// matches it against a turn end it heard doesn't take it for one.
    struct Waiting: Equatable, Sendable {
        var deviceID: String
        var chat: LampAgentRemoteHosting.Chat
        /// As the phone shows the chat.
        var title: String
        var providerName: String
        /// When it began to wait, which the sweep reads as `endedAt`.
        var began: Date
        /// The wait's own id.
        var waitID = UUID()
    }

    static func waitRecordName(deviceID: String, chatID: String) -> String {
        "wait.\(deviceID).\(chatID)"
    }

    /// The record for a wait: who is waiting, never on what. The command,
    /// its folder and the agent's reason are left out, since an alert can
    /// show on a locked phone.
    static func record(for waiting: Waiting) -> CKRecord {
        let record = CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: waitRecordName(deviceID: waiting.deviceID, chatID: waiting.chat.id))
        )
        let words = "\(waiting.providerName) is waiting for your answer."
        record["deviceID"] = waiting.deviceID
        record["chatID"] = waiting.chat.id
        switch waiting.chat {
        case .reader:
            record["kind"] = "reader"
        case .writing(let id):
            record["kind"] = "writing"
            record["writingID"] = id
        }
        record["turnID"] = waiting.waitID.uuidString
        record["title"] = waiting.title
        record["subtitle"] = ""
        record["outcome"] = "waiting"
        record["summary"] = words
        record["body"] = words
        record["endedAt"] = waiting.began
        return record
    }

    /// What a change in whether a turn waits does to its phone: told once
    /// when it begins to wait, cleared when it stops, nothing otherwise.
    enum WaitChange: Equatable { case tell, clear, none }

    nonisolated static func change(wasWaiting: Bool, isWaiting: Bool) -> WaitChange {
        switch (wasWaiting, isWaiting) {
        case (false, true): .tell
        case (true, false): .clear
        default: .none
        }
    }

    /// Tells the phone a turn it asked for waits on the person, best effort.
    /// Saved only if it still waits when its turn in the line comes, and
    /// only while the device may still be told (`stillWaiting`).
    static func tellWaiting(_ waiting: Waiting, stillWaiting: @escaping @MainActor () -> Bool) {
        guard isEntitled, AIFeatures.isEnabledNow, !KeptAgentChats.isQuitting else { return }
        // Put on the list before it is saved, so a crash after the save
        // still has it deleted on the next launch; kept from the list's
        // retries while it lasts in this one.
        let name = waitRecordName(deviceID: waiting.deviceID, chatID: waiting.chat.id)
        activeWaits.insert(name)
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            let record: CKRecord? = await MainActor.run {
                guard stillWaiting(), AIFeatures.isEnabledNow, !KeptAgentChats.isQuitting else { return nil }
                return Self.record(for: waiting)
            }
            // Listed in the line, just before it is saved: an older delete
            // ahead of it in the line can't take the entry away.
            if let record {
                PendingClears.add(name)
                await save(record, to: database)
            }
        }
        clearPending()
    }

    /// Takes the wait's record away, once nothing waits: it tells nothing,
    /// and an alert already shown stays until the phone sees the chat again.
    ///
    /// The phone takes a wait's alert away only once it finds the record gone,
    /// so a record left behind keeps an alert up for a wait long over: a
    /// delete that fails, or is cut short by a quit, is kept on a list and
    /// tried again with the next push and as remote chats start.
    static func clearWaiting(deviceID: String, chatID: String) {
        guard isEntitled else { return }
        let name = waitRecordName(deviceID: deviceID, chatID: chatID)
        activeWaits.remove(name)
        PendingClears.add(name)
        clearPending()
    }

    /// Deletes every wait record on the list, in the line, keeping those whose
    /// delete fails. One already gone is done.
    static func clearPending() {
        guard isEntitled, !PendingClears.names().isEmpty else { return }
        let database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
        let previous = tail
        tail = Task.detached(priority: .utility) {
            await previous?.value
            let active = await MainActor.run { activeWaits }
            let names = PendingClears.names().filter { !active.contains($0) }
            guard !names.isEmpty else { return }
            let ids = names.map { CKRecord.ID(recordName: $0) }
            do {
                let (_, deleted) = try await database.modifyRecords(saving: [], deleting: ids)
                for (id, result) in deleted {
                    switch result {
                    case .success:
                        PendingClears.remove(id.recordName)
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        PendingClears.remove(id.recordName)
                    case .failure(let error):
                        log.error("wait push \(id.recordName, privacy: .public) not cleared: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } catch {
                log.error("wait pushes not cleared: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Waits told in this launch and not over, whose records the list's
    /// retries leave alone.
    private static var activeWaits: Set<String> = []

    /// The wait records still to delete, kept across launches.
    enum PendingClears {
        nonisolated static let key = "agent.turnPush.waitsToClear"
        nonisolated private static let lock = NSLock()

        nonisolated static func names(in defaults: UserDefaults = .standard) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return defaults.stringArray(forKey: key) ?? []
        }

        nonisolated static func add(_ name: String, in defaults: UserDefaults = .standard) {
            lock.lock()
            defer { lock.unlock() }
            var names = defaults.stringArray(forKey: key) ?? []
            if !names.contains(name) { names.append(name) }
            defaults.set(names, forKey: key)
        }

        nonisolated static func remove(_ name: String, in defaults: UserDefaults = .standard) {
            lock.lock()
            defer { lock.unlock() }
            var names = defaults.stringArray(forKey: key) ?? []
            names.removeAll { $0 == name }
            defaults.set(names, forKey: key)
        }
    }

    /// Saves one record, and logs a failure of the call or of the record:
    /// `modifyRecords` can succeed as a call and still fail the record, a
    /// missing schema or an account signed out among the reasons.
    nonisolated private static func save(_ record: CKRecord, to database: CKDatabase) async {
        do {
            let (saved, _) = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            for case let (id, .failure(error)) in saved {
                log.error("turn push \(id.recordName, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
            }
        } catch {
            log.error("turn push not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func outcomeName(_ outcome: AgentTurnNotifications.Outcome) -> String {
        switch outcome {
        case .replied: "replied"
        case .stoppedByLamp: "stopped"
        case .failed, .notice: "failed"
        }
    }

    /// Takes away records older than a day, once a launch. Overwriting keeps
    /// one per chat and phone already; this is for chats and phones gone.
    /// Run in the line with the saves (`tail`), so no save of this Mac's
    /// lands between its looking and its deleting, and only over this Mac's
    /// own phones, so no other Mac's either.
    nonisolated private static func sweep(_ database: CKDatabase, devices: [String]) async {
        guard !devices.isEmpty else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 60 * 60)
        let query = CKQuery(
            recordType: recordType,
            predicate: NSPredicate(format: "endedAt < %@ AND deviceID IN %@", dayAgo as NSDate, devices)
        )
        do {
            let (results, _) = try await database.records(matching: query, desiredKeys: [], resultsLimit: 200)
            let old = results.map(\.0)
            guard !old.isEmpty else { return }
            _ = try await database.modifyRecords(saving: [], deleting: old)
        } catch {
            log.error("turn push sweep failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
