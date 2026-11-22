import CloudKit
import Foundation
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
            if let record {
                _ = try? await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            }
            if sweeps { await sweep(database, devices: pairedDevices) }
        }
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
        guard let (results, _) = try? await database.records(matching: query, desiredKeys: [], resultsLimit: 200)
        else { return }
        let old = results.map(\.0)
        guard !old.isEmpty else { return }
        _ = try? await database.modifyRecords(saving: [], deleting: old)
    }
}
