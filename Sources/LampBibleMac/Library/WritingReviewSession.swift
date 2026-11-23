import Foundation
import LampCore
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif

/// The versions of each writing this Mac has lately seen, in any window: the
/// editor's text as it settles, each body saved, each draft taken in. A mark
/// is anchored in a text, and is placed exactly from that text
/// (`LampWritingReview.carryingToText`, which hashes them off the main
/// actor). One that has gone is still found by its words and context.
///
/// For drawing only. What is written — a save's carry, a clear — carries
/// from the texts its own window held (`WritingReviewSession.texts`): a
/// draft another window took in, not yet saved, is not this one's to
/// carry, and carried from here its new words would be retired for good.
/// Restores made and not yet written down, kept outside any one editor.
///
/// A record owed when the writer closes the window, or moves to another
/// writing, was lost with the view that held it — and nothing was coming
/// back for it, since the writing itself is saved. Kept here, it is tried
/// again whenever that writing is open.
@MainActor
final class WritingReviewObligations {
    static let shared = WritingReviewObligations(
        fileURL: (LampAgentDescriptorStore.defaultApplicationSupportURL()
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("owed-restores.json")
    )

    private let fileURL: URL
    private var owed: [String: [WritingReviewSession.OwedRestore]]

    init(fileURL: URL) {
        self.fileURL = fileURL
        owed = (try? JSONDecoder().decode(
            [String: [WritingReviewSession.OwedRestore]].self, from: Data(contentsOf: fileURL)
        )) ?? [:]
    }

    func owe(_ restore: WritingReviewSession.OwedRestore, for writingID: String) {
        owed[writingID, default: []].append(restore)
        write()
    }

    /// What is owed for a writing, left on disk until it is written
    /// down. Taking it away here and holding the only copy in an editor
    /// lost it to a crash, a quit, or a failure after the window had
    /// gone — which is the whole case these exist for.
    func owing(for key: WritingReviewKey) -> [WritingReviewSession.OwedRestore] {
        (owed[key.writingID] ?? []).filter { $0.document == key.document }
    }

    /// Whether the page for a writing can still redo.
    ///
    /// The page says so as its history changes, and on `ready` — where a
    /// fresh page has none — so the host never has to guess. Nothing is
    /// kept dormant for a writing this is false for.


    /// Said when the writer clears, so a record written later does not put
    /// a mark back over a passage they have answered.
    ///
    /// `all` for Mark All as Reviewed, which reads every mark there is,
    /// rather than a clear of some passages, which reads only theirs.
    func wasCleared(for key: WritingReviewKey, all: Bool = false) {
        guard var list = owed[key.writingID], !list.isEmpty else { return }
        var changed = false
        for index in list.indices where list[index].document == key.document {
            if !list[index].cleared {
                list[index].cleared = true
                changed = true
            }
            if all, list[index].clearedAll != true {
                list[index].clearedAll = true
                changed = true
            }
        }
        guard changed else { return }
        owed[key.writingID] = list
        write()
    }

    // MARK: Clears, one after another

    /// The clears being made for each writing, in the order asked: the write
    /// to its record, then what the clear read of the marks its owed
    /// restores make again. A keep of the writer's edits waits for them, so
    /// it never finishes with a clear asked for that no pass was given.
    private var clearing: [String: Task<Void, Never>] = [:]
    private var clearCounts: [String: (asked: Int, made: Int)] = [:]

    /// `work` for a clear of `writingID`, after any clear asked before it.
    /// Counted as a pending write until it is made, so quitting waits for
    /// what a clear read, as it waits for the clear's own write.
    func clearing(_ writingID: String, _ work: @escaping @MainActor () async -> Void) {
        clearCounts[writingID, default: (0, 0)].asked += 1
        LampPendingWrites.shared.begin()
        let earlier = clearing[writingID]
        clearing[writingID] = Task { @MainActor in
            await earlier?.value
            await work()
            self.clearCounts[writingID, default: (0, 0)].made += 1
            LampPendingWrites.shared.end()
        }
    }

    /// Returns once every clear asked for `writingID` so far is made.
    func clearsMade(for writingID: String) async {
        while let task = clearing[writingID] {
            await task.value
            if clearing[writingID] == task { clearing[writingID] = nil }
        }
    }

    func clears(for writingID: String) -> (asked: Int, made: Int) { clearCounts[writingID] ?? (0, 0) }

    /// What a clear of some passages (`range` in `text`) read of the marks
    /// the owed restores make again over unread words they put back, kept
    /// with each: ids read whole, and the parts cleared of the rest. Worked
    /// out once, at the clear, from the restore itself, whose marks those
    /// are, and in the writing's own text: a copy of the edits kept
    /// meanwhile takes the result (`keptCopyRecord`), and no clear is ever
    /// made again on a record that has gained other marks since.
    ///
    /// `among` names the restores owed when the clear was made: one made
    /// after it is no business of this clear's, though the clear's result
    /// is worked out later.
    func read(_ range: NSRange, in text: String, for key: WritingReviewKey, among ids: Set<UUID>) async {
        let owing = owing(for: key).filter { ids.contains($0.id) }
        guard !owing.isEmpty else { return }
        let found = await Task.detached(priority: .userInitiated) {
            owing.compactMap { owed in
                WritingReviewSession.remarksRead(by: range, in: text, of: owed).map { (owed.id, $0) }
            }
        }.value
        guard !found.isEmpty, var list = owed[key.writingID] else { return }
        for (id, reading) in found {
            // Settled or moved since: nothing of it is owed here.
            guard let at = list.firstIndex(where: { $0.id == id }) else { continue }
            list[at].remarksRead = (list[at].remarksRead ?? []).union(reading.whole)
            // The whole set: what earlier clears cleared in part is carried
            // in it, from the restore's own marks as they stood.
            list[at].remarkClearances = reading.parts
        }
        owed[key.writingID] = list
        write()
    }

    /// Said once a Mark All as Reviewed has landed: the restores owed when it
    /// was pressed (`ids`) read every mark they make again.
    func markedAll(for key: WritingReviewKey, among ids: Set<UUID>) {
        guard var list = owed[key.writingID] else { return }
        var changed = false
        for index in list.indices where list[index].document == key.document && ids.contains(list[index].id) {
            if list[index].clearedAll != true {
                list[index].clearedAll = true
                changed = true
            }
        }
        guard changed else { return }
        owed[key.writingID] = list
        write()
    }

    /// Said once a record is safely written.
    func settled(_ id: UUID, for writingID: String) {
        guard owed[writingID]?.contains(where: { $0.id == id }) == true else { return }
        owed[writingID]?.removeAll { $0.id == id }
        write()
    }

    /// Said when some of an obligation's passages are written and the
    /// rest are not.
    func stillOwed(_ owing: WritingReviewSession.OwedRestore, for writingID: String) {
        var list = owed[writingID] ?? []
        if let at = list.firstIndex(where: { $0.id == owing.id }) {
            list[at] = owing
        } else {
            list.append(owing)
        }
        owed[writingID] = list
        write()
    }

    /// The named restores leave a writing whose edits were kept as a copy.
    ///
    /// What the copy's text proved is already in the copy's record, written
    /// with its marks by the pass that saved it (the editor's
    /// `carryReviewMarks`). `waiting` is what that text could not answer
    /// for: owed to the copy now, for a save of it that can.
    ///
    /// Named, not the writing's whole bucket: another window's restore
    /// can be parked under the same writing, and its body is not this
    /// copy's. And not one a save of the writing itself committed
    /// (`bodyCommitted`): that record is the writing's own, which
    /// `retryOwedRecords` still owes it. The copy's record holds it too.
    func keptAsCopy(
        _ ids: Set<UUID>, of writingID: String, as copyID: String,
        waiting: [WritingReviewSession.OwedRestore]
    ) {
        guard !ids.isEmpty, let list = owed[writingID] else { return }
        let leaving = Set(list.filter { ids.contains($0.id) && !$0.bodyCommitted }.map(\.id))
        guard !leaving.isEmpty else { return }
        owed[writingID] = list.filter { !leaving.contains($0.id) }
        owed[copyID, default: []].append(contentsOf: waiting.filter { leaving.contains($0.id) })
        write()
    }

    func isEmpty(for writingID: String) -> Bool { (owed[writingID] ?? []).isEmpty }

    /// Kept on disk, because the whole point of them is the record that
    /// has not been written yet: quitting took the lot.
    private func write() {
        owed = owed.filter { !$0.value.isEmpty }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(owed).write(to: fileURL, options: .atomic)
        } catch {
            // Nothing to be done about it here: the records are still
            // owed in memory for as long as this run lasts.
        }
    }
}

/// What a set of review marks is for, which is core's
/// (`LampWritingReviewPlace`): the phone keeps the same texts under the
/// same key, so the key is one type rather than two that agree.
typealias WritingReviewKey = LampWritingReviewPlace

/// The texts this Mac has held, which core keeps
/// (`LampWritingReviewTexts`). The shorthand for a writing's own prose
/// stays here, since it is what every caller outside the editor means.
enum WritingReviewTexts {
    static let shared = LampWritingReviewTexts()
    static let kept = LampWritingReviewTexts.kept
}

extension LampWritingReviewTexts {
    func remember(_ text: String, for writingID: String) {
        remember(text, for: LampWritingReviewPlace(writingID: writingID))
    }

    func known(for writingID: String) -> [String] {
        known(for: LampWritingReviewPlace(writingID: writingID))
    }
}

/// Where the marks are changed by a save's carry and by an assistant's draft
/// taken in: one at a time, in the order they were asked for, off the main
/// actor. In order, a carry asked for before a turn's draft was taken in is
/// done before the draft's marks are made, so it can never take the turn's
/// new marks back to the text before it; off the main actor, the whole
/// manuscript compared, and the wait on the marks file's lock, are not the
/// writer's to feel. Each counts as a pending write, so quitting waits.
@MainActor
final class WritingReviewWork {
    static let shared = WritingReviewWork()
    private var last: Task<Void, Never>?

    func run(_ work: @escaping @Sendable () async -> Void) {
        let previous = last
        LampPendingWrites.shared.begin()
        last = Task.detached(priority: .utility) {
            await previous?.value
            await work()
            await MainActor.run { LampPendingWrites.shared.end() }
        }
    }

    /// A place in line taken now, for work only known later: a save takes
    /// its place before it waits on the database, so a turn's draft taken in
    /// meanwhile is marked after its carry, never before. Filled with the
    /// work once known, or given up, and either way the line moves on.
    struct Reservation: Sendable {
        fileprivate let continuation: AsyncStream<@Sendable () async -> Void>.Continuation

        func fill(_ work: @escaping @Sendable () async -> Void) {
            continuation.yield(work)
            continuation.finish()
        }

        func giveUp() {
            continuation.finish()
        }
    }

    /// How long a place in line waits to be filled before the line moves
    /// on without it: far past any save, and short of a queue stopped for
    /// good by a place nobody fills. Work filled in after that is dropped,
    /// not run late: behind what was queued after it, it would be the stale
    /// writer the line exists to prevent. (The stream is finished as the
    /// place gives up, and a finished stream discards what it is given.)
    var reservationPatience: Duration = .seconds(120)

    func reserve() -> Reservation {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        let patience = reservationPatience
        run {
            let work = await withTaskGroup(of: (@Sendable () async -> Void)?.self) { group in
                group.addTask {
                    for await work in stream { return work }
                    return nil
                }
                group.addTask {
                    try? await Task.sleep(for: patience)
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                continuation.finish()
                return first
            }
            await work?()
        }
        return Reservation(continuation: continuation)
    }

    /// Returns once everything asked for so far is done.
    func drained() async {
        await last?.value
    }
}

/// The review marks of the writing an editor has open (`LampWritingReview`):
/// what is drawn, how many passages are still to read, and the writer's
/// clears. One per editor, held apart from the editor's view so that none of
/// this is worked out in its body, which is on the typing path.
///
/// The marks file is read again when its date moves — an assistant's turn
/// marked something, or another device's clears arrived by sync — checked
/// about once a second while the writing is open. What to draw is worked out
/// off the main actor, once the text has settled.
@MainActor
final class WritingReviewSession: ObservableObject {
    /// What is still marked, in the writing's Markdown, for the Markdown
    /// editor to draw.
    @Published private(set) var ranges: [NSRange] = []
    /// How many passages are still to read, places words were taken out
    /// among them.
    @Published private(set) var count = 0
    /// Whether the surface showing the writing has refused the marks.
    ///
    /// The page draws marks by parsing a copy of the Markdown with
    /// markers written into it, and refuses the lot where what it parsed
    /// is not the document it is holding — which a marker inside a
    /// link's address or a run of stars can cause. Refusing is right:
    /// the alternative is marks drawn somewhere they do not belong.
    ///
    /// But refusing silently is not. A writer looking at a document with
    /// nothing marked cannot tell "the assistant changed nothing" from
    /// "the assistant changed this paragraph and nobody can show you".
    /// That is the one thing marks exist to tell them.
    @Published private(set) var isUnshown = false
    /// With `isUnshown`: the page drew some of the marks, and not others.
    /// One mark's markers can make the document another where they fall,
    /// in Markdown nobody foresaw; the page then places the rest without
    /// it, and the writer is told some are missing rather than that none
    /// are drawn.
    @Published private(set) var isPartlyShown = false
    /// The warning stands because the page holds this text and could not
    /// place every mark, not because it held another: typing does not lift
    /// it, since the page keeps what it drew and is not asked again.
    private var isUnplaceable = false
    /// What of those can be put back as the assistant found it, in the
    /// order they stand. Worked out with what is drawn, off the main actor,
    /// so the editor can offer a restore without asking for it: short of
    /// the marks, since a passage the writer has typed into is not offered.
    @Published private(set) var restorable: [LampWritingReview.Restorable] = []
    /// What the writing's agent is told is still marked
    /// (`WritingChatTurns.reviewNote`), for `.lamp/editor.md`: nil only
    /// while marks are off, `unreadReviewNote` until the marks file is first
    /// read. Changes only as the marks are drawn, once the text settles, so
    /// typing writes nothing.
    @Published private(set) var agentNote: String?

    /// The marks as the visual editor takes them, each time they change:
    /// the writing's Markdown with markers, or nil for none, and what a
    /// restore of each marked passage would come to. The page keeps them
    /// through the writer's typing itself, so typing sends nothing.
    var onMarksChanged: ((String?, [LampWritingReview.Change?]) -> Void)?
    /// The marks last sent, for an editor that is ready late.
    private(set) var markedMarkdown: String?
    /// What they were sent for: the document the session was following
    /// when it published them, which the page's answer is checked against.
    private(set) var markedKey: WritingReviewKey?
    /// What was sent with them, one to each marked passage, in the order
    /// they stand — which is the order the page finds its markers in.
    private(set) var markedChanges: [LampWritingReview.Change?] = []

    private var writingID: String?
    /// The document beside the writing whose marks these are, or nil for
    /// the writing's own prose. The session follows whichever document the
    /// editor has open.
    private var document: String?
    /// What the session is following, for the holders that are keyed by it.
    private var key: WritingReviewKey? {
        writingID.map { WritingReviewKey(writingID: $0, document: document) }
    }
    private var store: LampWritingReviewStore?
    /// Where the records are, kept whether or not this session is reading
    /// them: a restore made in one document is still owed its record when
    /// the writer opens something that has none.
    private var libraryRoot: URL?
    private var review: LampWritingReview?
    private var text = ""
    private var fileDate: Date?
    /// Whether the marks file has been read since the writing was followed:
    /// the first read is drawn even when it finds nothing, so the agent is
    /// told that nothing is marked.
    private var hasRead = false
    private var settleTask: Task<Void, Never>?
    private var drawGeneration = 0
    /// The page refused the last marks sent (its text was a moment ahead of
    /// this one's), so the next draw sends them again.
    private var needsResend = false
    /// The text a refused set of marks was last sent again for. Refused
    /// again for the same text, they wait for the text to change rather
    /// than going round every few hundred milliseconds.
    private var resentFor: String?
    /// The texts this editor has held, newest last: what its clears and its
    /// saves' carries take marks from.
    private(set) var texts: [String] = []

    static let checkInterval: Duration = .seconds(1)
    static let settleDelay: Duration = .milliseconds(300)

    /// Keeps the writing's marks current until the task is cancelled: the
    /// editor's `.task(id:)`, keyed on the writing and on whether marks are
    /// shown at all. Shown off, everything is cleared and nothing is read.
    /// `hasMarks` false is a file that is none of the writing's
    /// documents — one opened by hand from a subdirectory — which is not
    /// the same as marks being turned off. Marks off still holds the
    /// texts, so an edit made while they were hidden is carried back to
    /// them when they return; a file that is nothing of the writing's
    /// must leave no trace at all, or its words are offered as a source
    /// when the writing's own marks are carried.
    func follow(
        writingID: String, document: String? = nil, text: String,
        libraryRootURL: URL, isShown: Bool, hasMarks: Bool = true
    ) async {
        // Nothing drawn for what was followed before may land now.
        settleTask?.cancel()
        drawGeneration += 1
        // The texts held are kept while the same thing is followed (marks
        // turned off and on again): an edit made meanwhile is carried from
        // them back to the marks. A different document is a different set
        // of marks made of different words, so nothing carries across.
        if self.writingID != writingID || self.document != document { texts = [] }
        self.writingID = writingID
        self.document = document
        // Before the guard: a restore owed in a document must be
        // recordable while the writer has something open that has none,
        // and that must not depend on a previous follow having set it.
        libraryRoot = libraryRootURL
        guard hasMarks else {
            self.text = text
            review = nil
            fileDate = nil
            hasRead = false
            needsResend = false
            resentFor = nil
            store = nil
            publish(
                ranges: [], count: 0, restorable: [], marked: nil, changes: [],
                note: nil, sendsMarks: true
            )
            return
        }
        self.text = text
        remember(text)
        review = nil
        fileDate = nil
        hasRead = false
        needsResend = false
        resentFor = nil
        store = isShown ? LampWritingReviewStore(rootURL: libraryRootURL) : nil
        publish(
            ranges: [], count: 0, restorable: [], marked: nil, changes: [],
            note: isShown ? WritingChatTurns.unreadReviewNote : nil, sendsMarks: true
        )
        guard isShown else { return }
        while !Task.isCancelled {
            await reloadIfMoved()
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    /// The writing's text moved: what to draw is worked out again once it
    /// settles. The visual page is not sent the marks again for it, unless
    /// it refused the last ones.
    func textChanged(_ text: String) {
        // A new text is a new question. The page may well take the
        // marks for it, and until it has answered there is nothing to
        // warn about — an undo that puts back text the page was happy
        // with would otherwise keep the warning over marks the writer
        // can see.
        //
        // Not where only some were drawn: the page keeps those through
        // typing and is not asked again, so the rest are still missing.
        if isUnshown, !isUnplaceable, text != self.text { isUnshown = false }
        guard text != self.text else { return }
        self.text = text
        guard review != nil else { return }
        scheduleDraw()
    }

    /// The page could not place the marks it was sent: its text was not
    /// this one. They go again once the text settles.
    /// The page would not draw the marks it was sent.
    ///
    /// `askedIn` is what it was sent for. The page answers after a turn
    /// of its own and the writer can open another document meanwhile;
    /// an answer about the outline must not put a warning over the
    /// notes, which may be perfectly well marked.
    func marksRejected(askedIn: WritingReviewKey? = nil) {
        if let askedIn, askedIn != key { return }
        needsResend = true
        // Said on the first refusal, not the second.
        //
        // A refusal schedules another draw, and that draw makes the
        // same Markdown from the same record — which the page is not
        // even sent, being identical to what it just refused. So a
        // second refusal never comes, and waiting for one left the
        // writer looking at an unmarked document with nothing to say
        // the marks had been turned away.
        //
        // Cleared again the moment anything draws, so a resend that
        // does land takes the warning with it.
        if !isUnshown, count > 0 { isUnshown = true }
        if isPartlyShown { isPartlyShown = false }
        isUnplaceable = false
        guard resentFor != text else { return }
        resentFor = text
        scheduleDraw()
    }

    /// The page drew them, so there is nothing to warn about.
    ///
    /// Said by the page, not worked out from having ranges to send:
    /// ranges exist in exactly the cases the page turns down, so
    /// clearing on those would clear the warning whenever it was most
    /// deserved.
    func marksDrawn(askedIn: WritingReviewKey? = nil) {
        if let askedIn, askedIn != key { return }
        if isUnshown { isUnshown = false }
        if isPartlyShown { isPartlyShown = false }
        isUnplaceable = false
    }

    /// The page holds this text and could not place every mark. Not a
    /// refusal: nothing is sent again, since the same marks would part the
    /// same way, but the writer is told what is drawn is not all of it —
    /// or, where it drew none, that none are, as when it refuses.
    func marksPartlyDrawn(askedIn: WritingReviewKey? = nil, drawn: Int) {
        if let askedIn, askedIn != key { return }
        if !isUnshown, count > 0 { isUnshown = true }
        let partly = drawn > 0 && count > 0
        if isPartlyShown != partly { isPartlyShown = partly }
        isUnplaceable = count > 0
    }

    /// Something else wants the marks sent again — a restore the page
    /// refused, whose marks it may no longer agree with. Not a sign
    /// that the marks cannot be drawn: they may be on the screen as
    /// this is called, and refusing an edit says nothing about them.
    func marksNeedResend() {
        needsResend = true
        guard resentFor != text else { return }
        resentFor = text
        scheduleDraw()
    }

    // MARK: - Clearing

    /// Clears what of the marks `range` of the writing covers. A caret with
    /// nothing selected clears the mark it stands in.
    ///
    /// The marks are carried to the text as it is now first: typed into
    /// since they were read, a marked passage would otherwise not be found
    /// and the clear would do nothing.
    func clear(range: NSRange) {
        clear(range: range, in: text)
    }

    /// Made in `text` with the marks carried there, changing only the marks
    /// it touches: `text` can be a moment behind the latest marks (the
    /// page's, pressed before a turn's draft reached it), and carried whole
    /// into it, a mark with no words there would be retired by a clear of
    /// some other passage.
    private func clear(range: NSRange, in text: String, drawsAnyway: Bool = false) {
        guard let writingID else { return }
        remember(text)
        let known = texts
        // Reaching back over a line's own block syntax where the range
        // begins just after it. Not outward over emphasis delimiters:
        // see the note on the other call site. a change to that syntax alone is drawn
        // as a point after it while the mark sits on it, so a clear
        // from that point touches nothing and the writer watches the
        // mark stay (core's `takingInSyntax`).
        let asked = LampWritingReviewMarkdown.takingInSyntax(range, of: text)
        // The restores owed as the clear is made: the only ones it reads.
        let owedNow = key.map { Set(WritingReviewObligations.shared.owing(for: $0).map(\.id)) } ?? []
        if let key { WritingReviewObligations.shared.wasCleared(for: key) }
        let landed = Landed()
        let written = change(drawsAnyway: drawsAnyway, { $0.clearing(asked, in: text, carryingFrom: known) }) {
            landed.value = $0
        }
        guard let key else { return }
        // After the write to the writing's record, what the clear read of the
        // marks its owed restores make again, which that record does not
        // hold: one after another, so a keep can wait for them. Not for a
        // clear whose write did not land: it read nothing in the writing.
        WritingReviewObligations.shared.clearing(writingID) {
            await written?.value
            guard landed.value else { return }
            await WritingReviewObligations.shared.read(asked, in: text, for: key, among: owedNow)
        }
    }

    /// Clears the range the visual page marked in the Markdown it sent.
    ///
    /// Where that is the writing as held here, give or take spelling, the
    /// clear is made in it. Otherwise the page was ahead or behind (typed
    /// into within the settle before its text is reported, or pressed
    /// before a turn's draft reached it), and the clear is made in the
    /// page's own text, `pageText`, which it sends unmarked beside the
    /// marked: that text is then known, so the next draw and save carry the
    /// clear on from it. Never held back for a text typing may already have
    /// passed.
    ///
    /// Never made in the marked Markdown with its markers taken out: a
    /// marker can change how the page writes what is round it (inside an
    /// autolink, `<url>` becomes `[url](url)`), so that is text the page
    /// never held. A page that sends no text of its own clears only where
    /// it matches the writing here.
    /// `askedIn` is the document the page was asked about. The page
    /// answers after a turn of its own, and the writer can open another
    /// meanwhile: an answer let through then clears a passage of a file
    /// nobody touched, which matching the text does not catch — two
    /// documents can begin with the same words.
    ///
    /// The page takes the block's marks off as it is pressed, before this
    /// answers, so it is always answered with the marks drawn again: where
    /// the record comes back unchanged, the write fails, or the range
    /// cannot be placed, nothing else would put back what the page took off.
    func clear(markedMarkdown marked: String, pageText: String? = nil, askedIn: WritingReviewKey? = nil) {
        if let askedIn, askedIn != key { return }
        if let range = LampWritingReview.markedRange(in: marked, of: text) {
            clear(range: range, in: text, drawsAnyway: true)
        } else if let pageText, let range = LampWritingReview.markedRange(in: marked, of: pageText) {
            clear(range: range, in: pageText, drawsAnyway: true)
        } else {
            draw(sendsMarks: true)
        }
    }

    func clearAll() {
        // The restores owed as Mark All is pressed: the only ones it reads.
        let owedNow = key.map { Set(WritingReviewObligations.shared.owing(for: $0).map(\.id)) } ?? []
        if let key { WritingReviewObligations.shared.wasCleared(for: key) }
        let landed = Landed()
        let written = change({ $0.clearingAll() }) { landed.value = $0 }
        guard let writingID else { return }
        // That it read every mark is said once its write has landed: a Mark
        // All that did not land read nothing in the writing, and must not be
        // taken to have read the marks a copy holds.
        WritingReviewObligations.shared.clearing(writingID) { [key] in
            await written?.value
            guard landed.value, let key else { return }
            WritingReviewObligations.shared.markedAll(for: key, among: owedNow)
        }
    }

    // MARK: - Putting a wording back

    /// The restore `range` of the writing asks for, or nil where it cannot
    /// be made exactly: every marked passage it touches whole, and nothing
    /// unless all of them can be put back.
    ///
    /// Worked out here rather than taken from `restorable` so that the
    /// refusal is the record's own: a selection holding one passage the
    /// writer has typed into is refused, and that is not a thing the drawn
    /// list can say, holding only what can be put back.
    func restoring(_ range: NSRange, in text: String? = nil) -> LampWritingReview.RestoreOutcome {
        let text = text ?? self.text
        // The same reach back over a line's block syntax as a clear's.
        //
        // Not outward over emphasis delimiters. What the assistant
        // changed to make `red dog` bold is the two runs of `**`, so a
        // selection of the words does not cover them and the marks on
        // them stay — a sliver a second clear or a caret clear
        // removes. That is the small cost.
        //
        // Reaching for them cost more. Six rounds of the iOS session's
        // codex found six ways a hand-written pairing takes in a
        // delimiter belonging to a word the writer never selected,
        // which partly clears that word's mark and leaves its change
        // unrestorable: a run that merely matches, a literal run in a
        // code span, an escaped run, a caret, a list bullet, and a
        // nested emphasis. Each fix was one case narrower than the
        // problem.
        //
        // The rule behind all of them is CommonMark's delimiter-run
        // algorithm — flanking runs and the emphasis-processing pass —
        // which is what the editor page itself follows, through
        // markdown-it, and so what decides what the writer sees as
        // bold. Matching it means parsing with cmark, or porting that
        // pass faithfully and testing against the spec's own emphasis
        // examples. Until one of those is done, this reaches only for
        // block syntax. Do not add emphasis back by hand.
        let asked = LampWritingReviewMarkdown.takingInSyntax(range, of: text)
        return live(in: text)?.restoring(asked, in: text) ?? .nothingTouched
    }

    /// The marks carried into `text`, as drawing carries them.
    ///
    /// A restore planned against the stored record rather than this one
    /// can put words back in the wrong place: a mark whose own words the
    /// writer has typed into is not found where it stands, and the same
    /// words standing somewhere else — an untouched sentence that happens
    /// to repeat them — are found instead, where they pass the digest and
    /// are replaced. The carry is what ties a mark to its own place.
    private func live(in text: String) -> LampWritingReview? {
        guard let review else { return nil }
        return review.carryingToText(text, from: texts)
    }

    /// Records a restore the editor's own surface has just made, the text
    /// going from what it held to `restored`.
    ///
    /// The surface makes the edits, not this: in the visual page they are a
    /// transaction of its own, so the writer's ⌘Z takes them back, and in
    /// the Markdown view they are the text view's edit for the same reason.
    func restored(_ plan: LampWritingReview.RestorePlan, in from: String, to restored: String) {
        guard writingID != nil else { return }
        remember(from)
        remember(restored)
        text = restored
        let known = texts
        change { $0.restoringWording(plan, from: from, to: restored, carryingFrom: known) }
    }

    /// A restore the visual page has asked for: the Markdown it sent with
    /// markers at the edges of the passage, and its own text beside it.
    ///
    /// Worked out and handed back rather than recorded, because the page
    /// makes the edit — as one transaction of its own, so the writer's ⌘Z
    /// takes it back — and it may refuse. Recorded by `recordRestore` once
    /// the page says what it now holds.
    ///
    /// The page's own text is tried first: it is the text the press was
    /// made in. A page that sends none is answered against the writing as
    /// held here.
    ///
    /// By id rather than by a range of text: the page widens a range to a
    /// whole link when it writes its markers, so two changes inside one
    /// link label came back under the first one's button.
    ///
    /// Off the main actor: carrying the marks into the page's text and
    /// planning reads every mark, a quarter of a second on a long writing,
    /// and on the main actor that held the whole window still after the
    /// press. Worked out from the record and texts as they stand when it is
    /// asked; the page makes the edit only if it still holds `base`.
    func pageRestore(ids: String, pageText: String?) async -> PageRestore? {
        guard let review else { return nil }
        let text = text
        let texts = texts
        return await Task.detached(priority: .userInitiated) {
            Self.pageRestore(ids: ids, pageText: pageText, review: review, text: text, texts: texts)
        }.value
    }

    private nonisolated static func pageRestore(
        ids: String, pageText: String?, review: LampWritingReview, text: String, texts: [String]
    ) -> PageRestore? {
        let wanted = Set(ids.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
        guard !wanted.isEmpty else { return nil }
        // The marks carried into a text, as drawing carries them (`live`).
        func live(in text: String) -> LampWritingReview { review.carryingToText(text, from: texts) }
        // The page's own text first, since a plan made in it needs no
        // carrying at all.
        if let pageText, case .plan(let plan) = live(in: pageText).restoring(marks: wanted, in: pageText) {
            return PageRestore(base: pageText, restored: plan.applied(to: pageText), plan: plan)
        }
        guard case .plan(let plan) = live(in: text).restoring(marks: wanted, in: text)
        else { return nil }
        // Then the writing as it is held, carried into the page's own
        // spelling of it.
        //
        // The page writes its own Markdown — `*firmly*` where the file
        // says `_firmly_` — and carrying marks into that text reads the
        // difference as the writer's edits, so no plan is made there.
        // Sent as the file spells it, the page rightly refuses an edit
        // against text it is not holding, and a passage nobody has
        // touched cannot be put back at all. This was written to run
        // after the plan in the file failed, which is never: the file's
        // plan is exactly what succeeds in that case.
        if let pageText, let carried = plan.carried(from: text, to: pageText) {
            return PageRestore(
                base: pageText, restored: carried.applied(to: pageText), plan: carried
            )
        }
        return PageRestore(base: text, restored: plan.applied(to: text), plan: plan)
    }

    /// A restore the page has made, recorded against the text it now holds.
    ///
    /// `held` is the page's own Markdown afterwards, not what the plan
    /// worked out: the page writes its own spelling, and a word of it may
    /// come back another way. Only the marks put back change either way.
    /// `for` is what the restore was made in, which is not always what
    /// this session is following now: the proof of a restore is worked
    /// out off the main actor, and the writer can open another document
    /// while it runs. Written through the session regardless, the
    /// outline's restorations and marks would land in the notes.
    func recordRestore(
        _ restore: PageRestore, held: String, for key: WritingReviewKey,
        only marks: Set<UUID>? = nil,
        remarkingUnread: Bool = true, then: @escaping (Bool) -> Void = { _ in }
    ) {
        guard key != self.key else {
            guard store != nil else { return then(false) }
            return recordRestoreHere(
                restore, held: held, only: marks, remarkingUnread: remarkingUnread, then: then
            )
        }
        do {
            // Something else is open. The record is written straight to
            // its own file, off the actor as `change` does, and nothing
            // of this session's state is touched: none of it is that
            // document's.
            //
            // Its own store, not this session's, which is nil whenever
            // the writer has something open that has no marks at all. A
            // restore already made is owed its record whatever they look
            // at next, and nothing else would come back for it.
            guard let root = libraryRoot else { return then(false) }
            let store = LampWritingReviewStore(rootURL: root)
            let known = WritingReviewTexts.shared.known(for: key)
            WritingReviewTexts.shared.remember(restore.base, for: key)
            WritingReviewTexts.shared.remember(held, for: key)
            LampPendingWrites.shared.begin()
            Task {
                let written = await Task.detached(priority: .userInitiated) {
                    try? store.update(writingID: key.writingID, document: key.document) {
                        $0.restoringWording(
                            restore.plan, from: restore.base, to: held, only: marks,
                            remarkingUnread: remarkingUnread, carryingFrom: known
                        )
                    }
                }.value
                LampPendingWrites.shared.end()
                then(written != nil)
            }
            return
        }
    }

    /// The same for the document this session is following, which can use
    /// everything it holds.
    private func recordRestoreHere(
        _ restore: PageRestore, held: String, only marks: Set<UUID>?,
        remarkingUnread: Bool, then: @escaping (Bool) -> Void
    ) {
        remember(restore.base)
        remember(held)
        // Not `text = held`: this runs after the writing was saved, and
        // the writer may have typed since. Setting it back would draw the
        // marks in a text nobody is holding, and tell the assistant about
        // that one. The editor reports its text as it settles.
        let known = texts
        change(
            { $0.restoringWording(
                restore.plan, from: restore.base, to: held, only: marks,
                remarkingUnread: remarkingUnread, carryingFrom: known
            ) },
            then: then
        )
    }

    /// The record a copy of a writing's edits is filed with: the writing's
    /// `record`, with the `restores` that the copy's text proves written into
    /// it first, where their marks still stand and their plans were made, as
    /// a save of the writing would have settled them, and the whole carried
    /// into the copy's `text`. Nil where there is nothing to file.
    ///
    /// Worked out from these alone, so a later pass of the keep, filing it
    /// again, comes out the same: nothing recorded earlier is lost, nor
    /// recorded twice. With the passages `saved`, the copy's text before its
    /// picture links were rewritten, could not answer for.
    nonisolated static func keptCopyRecord(
        of record: LampWritingReview, filed: LampWritingReview? = nil, as copyID: String,
        saved: String, current: String, text: String, proseTexts: [String], known: [String],
        relinked: (String) -> String, restores: [OwedRestore]
    ) -> (record: LampWritingReview?, waiting: [OwedRestore], dormant: [UUID: Set<UUID>]) {
        // What the copy's record holds already (`filed`, what earlier passes
        // filed), joined with what the writing's has come to since, as two
        // devices' records are joined: so each pass adds to what was filed,
        // as successive saves of the writing add to its record, and nothing
        // one pass filed (and may have synced out) is dropped by a later one.
        var record = filed.map { $0.merged(with: record) } ?? record
        // Restorations older than core keeps, which the writing's own record
        // may still hold, are not joined back in: a save of the writing
        // prunes them whenever it records.
        let today = Date()
        record.restorations.removeAll { today.timeIntervalSince($0.restoredAt) >= LampWritingReview.restorationWindow }
        // The marks the copy holds before this pass records anything: the
        // only ones a Mark All while the keep ran can have read.
        let present = Set(record.marks.map(\.id))
        // Written down for the writing itself since they were asked for, or by
        // an earlier pass: carried with the rest, and not recorded twice.
        let already = Set(record.restorations.map(\.markID))
        var sources = known
        var waiting: [OwedRestore] = []
        // The passages each restore's text shows undone, in the save and
        // now: let go, as a save of the writing lets them go.
        var dormant: [UUID: Set<UUID>] = [:]
        var recorded = false
        var retiring = false
        for owed in restores {
            // Proved as a save of the writing proves it, by core's decision
            // (`RestorePlan.settlement`).
            // Against what was saved, and against what the writer holds now
            // the save is done (`current`), as a save of the writing is: a
            // passage undone in the save and redone since waits, not let go.
            let answers = owed.restore.plan.standingByMark(from: owed.held, in: saved)
            let now = current == saved ? answers : owed.restore.plan.standingByMark(from: owed.held, in: current)
            let (stands, unknown, undone) = LampWritingReview.RestorePlan.settlement(
                pending: owed.pendingMarks.subtracting(already), inSaved: answers, inCurrent: now
            )
            if !unknown.isEmpty { waiting.append(owed.pending(unknown)) }
            if !undone.isEmpty { dormant[owed.id] = undone }
            // Cleared while owed: the words it puts back are not marked
            // again, and the marks it would make are retired, whether or not
            // it is recorded here. An earlier pass may have filed one before
            // the clear, or another device's recording of this restore may
            // have brought one into the writing's record since, and a copy
            // synced with either keeps it unless this record retires it.
            // Marked All as Reviewed while the keep ran: the marks it made
            // again over words it put back, which an earlier pass filed and the
            // copy holds, were among those read, and are retired, as Mark All
            // retires every mark in the writing. Only those: a mark no pass
            // filed was never there to read, and retiring it would hide the
            // one a later restore of the same words makes; and only for its
            // own passages, still owed or let go by this keep, not one a save
            // of the writing let go before. A clear of some other passage
            // reads none of them, as in the writing, where it touches only
            // the marks it covers.
            //
            // And a clear of some passages reads those its own result names
            // (`remarksRead`, worked out at the clear, from the restore
            // itself): whole, retired; in part, the clearance alone, which
            // touches no mark but its own.
            // Only its own: the marks it could have filed, its passages still
            // owed or let go by this keep. Another restore of the same words,
            // made since, makes a mark of the same id, which this one's
            // reading, of words since undone and let go, has no claim on.
            let own = Set(owed.pendingMarks.union(owed.keptLetGo ?? []).map(LampWritingReview.remarkID(restoring:)))
            var read = (owed.remarksRead ?? []).intersection(own)
            if owed.clearedAll == true { read.formUnion(own) }
            for id in read where present.contains(id) {
                record.marks.removeAll { $0.id == id }
                record.retired.append(LampWritingReview.Retirement(id: id, retiredAt: today))
                retiring = true
            }
            let parts = (owed.remarkClearances ?? []).filter { part in
                own.contains(part.markID) && present.contains(part.markID) && !read.contains(part.markID)
                    && !record.clearances.contains { $0.id == part.id }
            }
            if !parts.isEmpty {
                // In the copy's links, as the copy's marks are.
                record.clearances += parts.map { Self.relinked($0, from: owed.held, by: relinked) }
                // Where they are anchored.
                sources.append(relinked(owed.held))
                retiring = true
            }
            guard !stands.isEmpty else { continue }
            let standing = Set(record.marks.map(\.id))
            record = record.restoringWording(
                owed.restore.plan, from: owed.restore.base, to: owed.held, only: stands,
                remarkingUnread: !owed.cleared,
                carryingFrom: proseTexts + [owed.restore.base, owed.held]
            )
            // The words it put back that the writer had not read are marked
            // again, under ids core takes from the marks restored
            // (`LampWritingReview.remarkID`), so every pass makes the same
            // mark as any other recorder of this restore would. None is kept
            // that names the writing's own picture links, which the copy's
            // text does not hold, so it could never be drawn there: unmarked,
            // as core leaves words it cannot place, rather than marked where
            // nothing stands.
            record.marks.removeAll { mark in
                !standing.contains(mark.id) && mark.pieces.contains { relinked($0.text) != $0.text }
            }
            // Where the restore's fresh marks are anchored.
            sources += [relinked(owed.restore.base), relinked(owed.held)]
            recorded = true
        }
        var carried = record.carryingToText(text, from: sources)
        // Filed where it records a restore, or holds marks or restorations
        // the writing's record did: a restore the writing wrote down for
        // itself since it was asked is one of those, and with no marks left
        // the copy would otherwise get no record of it at all.
        // And where it holds only what the writer read: a retirement or a
        // clearance, from a clear of the writing or of a restore, is what
        // stops a copy synced with an earlier pass's record from keeping
        // the marks it ends, however little else is left.
        guard recorded || retiring || !carried.marks.isEmpty || !carried.restorations.isEmpty
                || !carried.retired.isEmpty || !carried.clearances.isEmpty else {
            return (nil, waiting, dormant)
        }
        carried.writingID = copyID
        return (carried, waiting, dormant)
    }

    /// Whether a write landed, said by `change` after it returns its task.
    private final class Landed { var value = false }

    /// A clearance worked out in the writing's own text (`owed.held`, whose
    /// picture links name the writing), rewritten for the copy's: its words
    /// and their context relinked, its place moved by what relinking
    /// changed before it, anchored in the relinked text. So it is placed in
    /// the copy as the copy's own marks are, carried from relinked texts.
    nonisolated static func relinked(
        _ clearance: LampWritingReview.Clearance, from held: String, by relinked: (String) -> String
    ) -> LampWritingReview.Clearance {
        let source = held as NSString
        let target = relinked(held)
        let anchor = LampWritingReview.digest(of: target)
        let pieces = clearance.pieces.map { piece -> LampWritingReview.Piece in
            let hint = min(max(0, piece.hint), source.length)
            let moved = (relinked(source.substring(to: hint)) as NSString).length
            return LampWritingReview.Piece(
                text: relinked(piece.text), before: relinked(piece.before), after: relinked(piece.after),
                hint: moved, anchoredIn: piece.anchoredIn == nil ? nil : anchor
            )
        }
        return LampWritingReview.Clearance(
            id: clearance.id, markID: clearance.markID, pieces: pieces,
            version: clearance.version, clearedAt: clearance.clearedAt
        )
    }

    /// The marks `owed` makes again over unread words it put back, alone,
    /// as the writer's clears have left them so far: the same pieces under
    /// the same ids as a pass of a keep files, from the restore itself.
    nonisolated static func remarks(of owed: OwedRestore) -> LampWritingReview {
        var made = LampWritingReview(writingID: "").restoringWording(
            owed.restore.plan, from: owed.restore.base, to: owed.held,
            only: owed.pendingMarks.union(owed.keptLetGo ?? [])
        )
        made.retired = []
        made.restorations = []
        let read = owed.remarksRead ?? []
        made.marks.removeAll { read.contains($0.id) }
        made.clearances = (owed.remarkClearances ?? []).filter { part in
            made.marks.contains { $0.id == part.markID }
        }
        return made
    }

    /// What a clear of `range` in `text` reads of those marks: the ids read
    /// whole, and the parts cleared of the rest, anchored in `owed.held`.
    /// Nil where it reads none of them.
    nonisolated static func remarksRead(
        by range: NSRange, in text: String, of owed: OwedRestore
    ) -> (whole: Set<UUID>, parts: [LampWritingReview.Clearance])? {
        let before = remarks(of: owed)
        // No unread words put back: nothing to read, and no alignment.
        guard !before.marks.isEmpty else { return nil }
        let after = before.clearing(range, in: text, carryingFrom: [owed.held])
        let whole = Set(after.retired.map(\.id))
        let parts = after.carryingToText(owed.held, from: [text]).clearances
        // A carry that only drops a mark it cannot place is not a read.
        guard !whole.isEmpty || parts.count != before.clearances.count else { return nil }
        return (whole, parts)
    }

    /// A restore the surface made that no save has carried to storage
    /// yet, and that is therefore not written down.
    struct OwedRestore: Identifiable, Codable {
        var id = UUID()
        let restore: PageRestore
        let held: String
        /// Set once a save holding this restore has landed and only the
        /// marks file is left: nothing else would come back for it, since
        /// the writing is clean and no further save is owed.
        var bodyCommitted = false

        /// The passages still to be written down. The plan is kept
        /// whole however many of them are left, because where each one
        /// ended up depends on every edit before it: a plan with the
        /// others taken out gives the wrong places.
        var pending: Set<UUID>?

        var pendingMarks: Set<UUID> { pending ?? Set(restore.plan.marks) }


        /// The document beside the writing this restore was made in, or
        /// nil for its own prose. Kept inside the record rather than in
        /// the key it is filed under, so the file on disk keeps the shape
        /// it has: a writing's obligations are one bucket, and each knows
        /// its own document.
        var document: String?

        /// Passages a keep of the writer's edits let go, found undone, after
        /// a pass may already have filed their marks again in the copy: a
        /// restore cleared since retires those marks there too. Nil for none,
        /// as every obligation filed before this was kept has.
        var keptLetGo: Set<UUID>?

        /// The marks this restore makes again over unread words it put back
        /// that a clear of some passages read whole while it was owed, and
        /// the parts cleared of the others (`WritingReviewObligations.read`).
        var remarksRead: Set<UUID>?
        var remarkClearances: [LampWritingReview.Clearance]?

        /// Whether that clear was Mark All as Reviewed, which reads every
        /// mark there is, the one a restore makes again among them. Nil for
        /// none, as every obligation filed before this was kept has.
        var clearedAll: Bool?

        /// Whether the writer cleared while this was owed.
        ///
        /// Putting back wording they had not yet read marks it, since they
        /// have taken back words they never reviewed. But the record is
        /// only written once a save proves the text, and a writer who
        /// cleared in between cleared a passage that carried no mark at
        /// the time — so a mark appearing after that is one they have
        /// already answered.
        var cleared = false

        func pending(_ marks: Set<UUID>) -> OwedRestore {
            var copy = self
            copy.pending = marks
            return copy
        }
    }

    /// A restore worked out for the page, before the page has made it.
    struct PageRestore: Codable {
        let base: String
        let restored: String
        let plan: LampWritingReview.RestorePlan
    }

    // MARK: - Internals

    /// A text the editor is about to hold, an assistant's draft it takes
    /// in: remembered at once rather than as the text settles, since the
    /// writer may type into it first.
    func holds(_ text: String) {
        remember(text)
    }

    /// Remembers a text this editor holds, here and among every window's.
    private func remember(_ text: String) {
        guard let writingID else { return }
        WritingReviewTexts.shared.remember(
            text, for: WritingReviewKey(writingID: writingID, document: document)
        )
        guard texts.last != text else { return }
        texts.append(text)
        texts = Array(texts.suffix(WritingReviewTexts.kept))
    }

    /// Changes the marks file off the main actor — another writer can hold
    /// its lock for as long as a long manuscript takes to compare — and
    /// takes up what was written, with the file's date read under the same
    /// lock. Counted as a pending write, so quitting waits for a clear.
    /// `drawsAnyway` draws the marks again and sends them however the write
    /// goes, for a change the page has already shown (`clear(markedMarkdown:)`).
    @discardableResult
    private func change(
        drawsAnyway: Bool = false,
        _ edit: @escaping @Sendable (LampWritingReview) -> LampWritingReview,
        then: @escaping (Bool) -> Void = { _ in }
    ) -> Task<Void, Never>? {
        guard let store, let writingID else {
            then(false)
            return nil
        }
        let document = document
        LampPendingWrites.shared.begin()
        return Task { [weak self] in
            let written = await Task.detached(priority: .userInitiated) {
                try? store.updating(writingID: writingID, document: document, edit)
            }.value
            LampPendingWrites.shared.end()
            // Said either way, and said here: the caller may be waiting to
            // tell the writer that the writing took their restore and the
            // marks file would not.
            then(written != nil)
            // Not for a writing or document left since, nor once marks
            // were turned off.
            guard let self, self.writingID == writingID,
                  self.document == document, self.store != nil
            else { return }
            guard let written else {
                if drawsAnyway { self.draw(sendsMarks: true) }
                return
            }
            self.apply(written.review, date: written.modified, drawsAnyway: drawsAnyway)
        }
    }

    /// Reads the marks file again if its date has moved since it was last
    /// read: the record and its date together, under the file's lock, so a
    /// write can never be taken for the one before it. Off the main actor,
    /// for the same reason as `change`.
    private func reloadIfMoved() async {
        guard let store, let writingID else { return }
        let document = document
        let read = await Task.detached(priority: .utility) {
            try? store.snapshot(writingID: writingID, document: document)
        }.value
        guard self.writingID == writingID, self.document == document, !Task.isCancelled
        else { return }
        guard let read else {
            // Unreadable now, though it was read before: the agent is told
            // so rather than what was read then, until a read succeeds.
            hasRead = false
            if agentNote != nil, agentNote != WritingChatTurns.unreadReviewNote {
                agentNote = WritingChatTurns.unreadReviewNote
            }
            return
        }
        guard read.modified != fileDate || !hasRead else { return }
        apply(read.modified == nil ? nil : read.review, date: read.modified)
    }

    private func apply(_ review: LampWritingReview?, date: Date?, drawsAnyway: Bool = false) {
        fileDate = date
        let isFirstRead = !hasRead
        hasRead = true
        guard review != self.review || isFirstRead || drawsAnyway else { return }
        self.review = review
        draw(sendsMarks: true)
    }

    private func scheduleDraw() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.remember(self.text)
            // Sent too while none are shown but some stand: marks that placed
            // nowhere in the text before (a newer body arrived) may place in
            // this one.
            let unplaced = self.markedMarkdown == nil && !(self.review?.isEmpty ?? true)
            self.draw(sendsMarks: self.needsResend || unplaced)
        }
    }

    private func draw(sendsMarks asked: Bool) {
        drawGeneration += 1
        let generation = drawGeneration
        // Owed until a draw that sends them lands: a later draw supersedes
        // this one (a typing settle while it is worked out), and the marks
        // it was to send are then that draw's to send.
        if asked { needsResend = true }
        let sendsMarks = needsResend
        guard let review, !review.isEmpty else {
            needsResend = false
            publish(
                ranges: [], count: 0, restorable: [], marked: nil, changes: [],
                note: noteForAgent(ranges: []), sendsMarks: sendsMarks
            )
            return
        }
        let text = self.text
        // Drawn from the marks carried into the text as it is now, each from
        // the text it is anchored in: typed into since they were saved, a
        // marked passage would otherwise be found nowhere, and not counted,
        // until the next save carries it.
        let known = key.map { WritingReviewTexts.shared.known(for: $0) } ?? []
        Task { [weak self] in
            let drawn = await Task.detached(priority: .userInitiated) {
                let live = review.carryingToText(text, from: known)
                // Everything drawn, from one finding of the marks, each
                // piece anchored in this text first so it is placed at a
                // look: asked one by one, each found every mark again, and
                // on a writing gone over many times a clear took seconds to
                // show.
                let drawing = live.drawing(in: text, forPlacing: sendsMarks)
                // The page places the marks by where it writes each
                // character of its document (its review-trace.js), each
                // passage carrying its own place, which pairs it with its
                // change whatever order the page finds them in.
                let placed = drawing.markedMarkdown.map { LampWritingReviewMarkdown.drawable($0) }
                return (
                    drawing.ranges,
                    // Passages as drawn, not marks: see `passageCount`.
                    drawing.passageCount,
                    placed,
                    drawing.restorable,
                    drawing.changes
                )
            }.value
            guard let self, self.drawGeneration == generation else { return }
            if sendsMarks { self.needsResend = false }
            self.publish(
                ranges: drawn.0, count: drawn.1, restorable: drawn.3, marked: drawn.2,
                changes: drawn.4, note: self.noteForAgent(ranges: drawn.0, in: text),
                sendsMarks: sendsMarks
            )
        }
    }

    /// The note for what is drawn, as the session stands: nothing once marks
    /// are off, though a draw asked for before (a rejection the page sends
    /// late) still lands; unread until the file has been read.
    private func noteForAgent(ranges: [NSRange], in text: String? = nil) -> String? {
        guard store != nil else { return nil }
        guard hasRead else { return WritingChatTurns.unreadReviewNote }
        return WritingChatTurns.reviewNote(
            ranges: ranges, in: text ?? self.text, restorations: review?.restorations ?? []
        )
    }

    private func publish(
        ranges: [NSRange], count: Int, restorable: [LampWritingReview.Restorable],
        marked: String?, changes: [LampWritingReview.Change?], note: String?, sendsMarks: Bool
    ) {
        if self.ranges != ranges { self.ranges = ranges }
        // Nothing marked at all: there is nothing that could not be
        // shown. Anything else waits for the page to say it drew them.
        if isUnshown, count == 0 {
            isUnshown = false
            isPartlyShown = false
            isUnplaceable = false
        }
        if self.count != count { self.count = count }
        if self.restorable != restorable { self.restorable = restorable }
        if agentNote != note { agentNote = note }
        if sendsMarks {
            markedMarkdown = marked
            markedChanges = changes
            markedKey = key
            onMarksChanged?(marked, changes)
        }
    }
}

/// Makes the marks a reconciler pass asked for, in the order it asked.
///
/// Synchronous and on the main actor by design. `WritingReviewWork` carries
/// each save's marks into that save's body in order, so a carry of pre-draft
/// text that runs after a turn's marks were made takes those marks back to
/// the pre-draft text and retires them. The caller therefore makes these in
/// the same uninterrupted stretch that makes the editor's content the draft:
/// then every save reserved before them saved pre-draft text and runs first,
/// and every save reserved after them saved post-draft text. Put an `await`
/// between the two and that ordering is gone.
///
/// See `DevotionalAgentDraftReconciler.ReviewChange`, which is why a pass
/// names its marks rather than making them.
@MainActor
struct WritingReviewChanges {
    let writingID: String
    /// The document the pass's changes were made in, or nil for the
    /// writing's own prose.
    var document: String?
    let store: LampWritingReviewStore?

    private var key: WritingReviewKey {
        WritingReviewKey(writingID: writingID, document: document)
    }

    func make(_ changes: [DevotionalAgentDraftReconciler.ReviewChange]) {
        for change in changes {
            switch change {
            case .assistantWrote(let from, let to, let turnID):
                update { $0.markingAssistantChange(from: from, to: to, turnID: turnID) }
                WritingReviewTexts.shared.remember(to, for: key)
            case .turnsUndone(let turns, let from, let to):
                update { $0.undoingTurns(turns, from: from, to: to) }
            }
        }
    }

    private func update(
        _ change: @escaping @Sendable (LampWritingReview) -> LampWritingReview
    ) {
        guard let store else { return }
        let writingID = writingID
        let document = document
        // In line with the saves' carries, off the main actor
        // (`WritingReviewWork`).
        WritingReviewWork.shared.run {
            _ = try? store.update(writingID: writingID, document: document, change)
        }
    }
}
