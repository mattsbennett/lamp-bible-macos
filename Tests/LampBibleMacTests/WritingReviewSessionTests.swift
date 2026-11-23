import Foundation
import LampCore
import Testing
@testable import LampBibleMac

/// The writing editor's review marks, followed and cleared.
@MainActor
struct WritingReviewSessionTests {
    private func library() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    // MARK: - What the page is told a restore would do

    /// The crossing is positional: one entry to each range the marks are
    /// drawn in, in the order they stand, because that is the order the
    /// page finds its markers in. An entry that did not line up would put
    /// one passage's wording under another's button.
    private func changes(
        _ review: LampWritingReview, in text: String
    ) -> [LampWritingReview.Change?] {
        review.changes(in: text, ranges: review.highlightedRanges(in: text))
    }

    @Test func thePageIsToldWhatComesBackAndWhatGoes() throws {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "The quick brown fox.", to: "The slow red fox.")
        let told = changes(review, in: "The slow red fox.")
        #expect(told.count == 1)
        #expect(told[0]?.now == "slow red")
        #expect(told[0]?.before == "quick brown")
        #expect(told[0]?.reason == nil)
    }

    /// What goes is the mark *and* the space the assistant put in with it,
    /// so the page shows the writer the same thing the restore does.
    @Test func whatGoesIncludesTheSpaceThatCameWithIt() throws {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "One two.", to: "One alpha two.")
        let told = changes(review, in: "One alpha two.")
        #expect(told[0]?.now == "alpha ")
        #expect(told[0]?.before == "")
    }

    /// Where the assistant only took words out there is nothing to see in
    /// the text at all, which is why the page is told rather than left to
    /// work it out from a zero-width marker.
    @Test func aPlaceWordsWereTakenOutSaysWhatWouldComeBack() throws {
        let old = "First sentence. Second sentence. Third sentence."
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: old, to: "First sentence. Third sentence.")
        let told = changes(review, in: "First sentence. Third sentence.")
        #expect(told[0]?.now == "")
        #expect(told[0]?.before == "Second sentence. ")
    }

    @Test func aPassageTypedIntoSaysWhyItCannotComeBack() throws {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "One two three.", to: "One alpha beta three.")
        let typed = "One alpha mine beta three."
        let carried = review.carryingWriterEdit(from: "One alpha beta three.", to: typed)
        let told = changes(carried, in: typed)
        #expect(told.allSatisfy { $0?.before == nil })
        #expect(told.contains { $0?.reason == "edited" })
    }

    /// A passage whose wording was never kept is not the writer's doing, so
    /// the page is given nothing to say about it rather than a reason that
    /// would read as an accusation.
    @Test func aPassageWhoseWordingWasNeverKeptSaysNothing() throws {
        var review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "The quick brown fox.", to: "The slow red fox.")
        review.wordings = []
        #expect(changes(review, in: "The slow red fox.") == [nil])
    }

    /// The page presses by this label, not by a range of the writing's
    /// Markdown: it widens a range to a whole link when it writes markers,
    /// which put two changes in one link label under one button.
    @Test func eachEntryNamesTheMarksItsPassageStandsIn() throws {
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: "The quick brown fox.", to: "The slow red fox.")
        let told = changes(review, in: "The slow red fox.")
        let id = try #require(review.marks.first?.id)
        #expect(told[0]?.id == id.uuidString)
    }

    @Test func anEntryNamingSeveralMarksSortsThem() throws {
        let one = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
        let two = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        #expect(LampWritingReview.Change.id(of: [one, two]) == "\(two.uuidString),\(one.uuidString)")
    }

    @Test func thereIsOneEntryToEachDrawnPassageInTheOrderTheyStand() throws {
        let old = "Alpha stands here.\n\nBeta stands here.\n\nGamma stands here."
        let new = "Alpha sits here.\n\nBeta stands here.\n\nGamma rests here."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        let told = changes(review, in: new)
        #expect(told.count == review.highlightedRanges(in: new).count)
        #expect(told.compactMap { $0?.before } == ["stands", "stands"])
        #expect(told.compactMap { $0?.now } == ["sits", "rests"])
    }

    @Test func theMarksAreReadAndCounted() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One deux three.\n\nFour cinq six."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 2 }
        #expect(session.ranges.map { (new as NSString).substring(with: $0) } == ["deux", "cinq"])
    }

    /// Review's case: the writer types into a marked passage and clears it
    /// before the save that would carry the marks. The clear still lands.
    @Test func aClearAfterTypingIntoAMarkStillClears() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(from: "One two three.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        session.clear(range: (typed as NSString).range(of: "gamma"))
        try await waitUntil {
            let review = try? store.review(writingID: "w")
            return review?.highlightedRanges(in: typed).map { (typed as NSString).substring(with: $0) } == ["alpha", "beta"]
        }
    }

    /// Codex's case: the ✓ is pressed on text the page holds but has not
    /// reported yet, twice, and typing goes on past both before the text is
    /// reported. Each clear lands, in the text it was made in.
    @Test func clearsAheadOfTheirTextLandAsTypingGoesOn() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha three.\n\nFour beta six.\n\nSeven gamma nine."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.\n\nSeven eight nine.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 3 }

        func marking(_ word: String, in text: String) -> String {
            text.replacingOccurrences(
                of: word, with: "\(LampWritingReview.markStart)\(word)\(LampWritingReview.markEnd)"
            )
        }
        let first = "One alpha three.\n\nFour beta six. More."
        session.clear(markedMarkdown: marking("beta", in: first), pageText: first)
        let second = "One alpha three.\n\nFour beta six. More.\n\nSeven gamma nine. And"
        session.clear(markedMarkdown: marking("alpha", in: second), pageText: second)
        let reported = "One alpha three.\n\nFour beta six. More.\n\nSeven gamma nine. And more."
        session.textChanged(reported)
        try await waitUntil {
            let review = try? store.review(writingID: "w")
            let known = WritingReviewTexts.shared.known(for: "w")
            return review?.carryingToText(reported, from: known).highlightedRanges(in: reported)
                .map { (reported as NSString).substring(with: $0) } == ["gamma"]
        }
        try await waitUntil { session.count == 1 }
    }

    /// A writer's edits kept as a copy, because a newer version came in,
    /// take their restores with them: written into the copy's marks by the
    /// same write that files them, worked out afresh by every pass of the
    /// keep, so a pass filing the copy again (typing went on, the copy was
    /// made anew, a failed pass was tried again) records each restore once,
    /// against its own text. Fable's design, after six rounds in which a
    /// restore moved to the copy was lost or left owed.
    @Test func aKeptCopyRecordsItsRestoresOnceEveryPass() throws {
        let old = "The quick brown fox jumps.\n\nAnd the slow dog sleeps."
        let new = "The fast red fox jumps.\n\nAnd the sleepy dog rests."
        let review = LampWritingReview(writingID: "w").markingAssistantChange(from: old, to: new)
        // The first marked passage, in the first paragraph; the second
        // paragraph's marks are left alone.
        let first = try #require(review.located(in: new).first?.id)
        guard case .plan(let plan) = review.restoring(marks: [first], in: new) else {
            Issue.record("the first passage can be put back")
            return
        }
        let held = plan.applied(to: new)
        let owed = WritingReviewSession.OwedRestore(
            restore: WritingReviewSession.PageRestore(base: new, restored: held, plan: plan), held: held
        )
        func pass(_ record: LampWritingReview, saved: String, as copy: String = "copy")
            -> (record: LampWritingReview?, waiting: [WritingReviewSession.OwedRestore], dormant: [UUID: Set<UUID>]) {
            WritingReviewSession.keptCopyRecord(
                of: record, as: copy, saved: saved, current: saved, text: saved, proseTexts: [new], known: [new],
                relinked: { $0 }, restores: [owed]
            )
        }
        func restored(_ record: LampWritingReview?) -> Int {
            record?.restorations.filter { $0.markID == first }.count ?? 0
        }

        // A pass, and a later one after more typing: each records it once,
        // and keeps the other passage marked.
        let once = pass(review, saved: held)
        let typed = held + "\n\nMore."
        let again = pass(review, saved: typed)
        #expect(restored(once.record) == 1 && restored(again.record) == 1)
        #expect(once.waiting.isEmpty && again.waiting.isEmpty)
        #expect(once.record?.writingID == "copy")
        let still = once.record?.highlightedRanges(in: held).map { (held as NSString).substring(with: $0) } ?? []
        #expect(still.contains { $0.contains("sleepy") } && !still.contains { $0.contains("fast") })

        // Made anew under another id: that copy records it too.
        #expect(restored(pass(review, saved: held, as: "another").record) == 1)

        // Already written down for the writing itself: not recorded twice,
        // which would mark the words it put back a second time.
        let recordedHere = review.restoringWording(plan, from: new, to: held, only: [first], carryingFrom: [new])
        let carriedOn = pass(recordedHere, saved: held).record
        #expect(restored(carriedOn) == 1)
        #expect(carriedOn?.marks.count == once.record?.marks.count)

        // Undone before the copy was saved: the copy's text does not hold
        // it, so nothing is recorded and nothing waits.
        let undone = pass(review, saved: new)
        #expect(restored(undone.record) == 0 && undone.waiting.isEmpty)
        // And it is said to be undone, so the keep lets it go for its
        // remaining passes: words pasted back later are not a redo.
        let undoneAsKept = WritingReviewSession.keptCopyRecord(
            of: review, as: "copy", saved: new, current: new, text: new, proseTexts: [new], known: [new],
            relinked: { $0 }, restores: [owed]
        )
        #expect(undoneAsKept.dormant[owed.id] == [first])
        // Undone in what the pass saved, but redone by the time the save was
        // done: it waits for a save that holds it, as the writing's does,
        // and is not let go.
        let redone = WritingReviewSession.keptCopyRecord(
            of: review, as: "copy", saved: new, current: held, text: new, proseTexts: [new], known: [new],
            relinked: { $0 }, restores: [owed]
        )
        #expect(redone.dormant.isEmpty)
        #expect(redone.waiting.contains { $0.id == owed.id && $0.pendingMarks.contains(first) })
    }

    /// From Codex's review of the kept copy's record: words a restore puts
    /// back that the writer had not read are marked again, and every pass
    /// gives that mark the same id, so a copy synced between passes and
    /// cleared elsewhere does not come back unread. And a restore the
    /// writing recorded for itself since it was asked still reaches a copy
    /// left with no marks at all.
    @Test func aKeptCopyMarksRestoredUnreadWordsAlikeEveryPass() throws {
        let first = "The cat sat."
        let second = "The dog sat."
        let third = "The bird sat."
        // The assistant's two turns: the second replaced words the writer
        // had not read yet, so putting them back marks them again.
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: first, to: second)
            .markingAssistantChange(from: second, to: third)
        let latest = try #require(review.located(in: third).first { located in
            located.ranges.contains { (third as NSString).substring(with: $0).contains("bird") }
        }?.id)
        guard case .plan(let plan) = review.restoring(marks: [latest], in: third) else {
            Issue.record("the second turn's passage can be put back")
            return
        }
        let held = plan.applied(to: third)
        #expect(held == second)
        let owed = WritingReviewSession.OwedRestore(
            restore: WritingReviewSession.PageRestore(base: third, restored: held, plan: plan), held: held
        )
        func pass(_ record: LampWritingReview, saved: String) -> LampWritingReview? {
            WritingReviewSession.keptCopyRecord(
                of: record, as: "copy", saved: saved, current: saved, text: saved, proseTexts: [third], known: [third],
                relinked: { $0 }, restores: [owed]
            ).record
        }
        let once = try #require(pass(review, saved: held))
        let again = try #require(pass(review, saved: held + " More."))
        let marked = once.highlightedRanges(in: held).map { (held as NSString).substring(with: $0) }
        #expect(marked.contains { $0.contains("dog") })
        #expect(Set(once.marks.map(\.id)) == Set(again.marks.map(\.id)))

        let filed = Set(once.marks.map(\.id)).subtracting(review.marks.map(\.id))
        #expect(!filed.isEmpty)
        func next(_ record: LampWritingReview, filed earlier: LampWritingReview?, saved: String,
                  restores: [WritingReviewSession.OwedRestore]) -> LampWritingReview? {
            WritingReviewSession.keptCopyRecord(
                of: record, filed: earlier, as: "copy", saved: saved, current: saved, text: saved,
                proseTexts: [third], known: [third, held], relinked: { $0 }, restores: restores
            ).record
        }
        func retires(_ r: LampWritingReview?) -> Bool { filed.isSubset(of: Set(r?.retired.map(\.id) ?? [])) }
        func marks(_ r: LampWritingReview?) -> Bool { r?.marks.contains { filed.contains($0.id) } == true }

        // Marked All as Reviewed while the keep ran, after a pass filed the
        // mark: the next pass retires it, as Mark All retires every mark in
        // the writing, so a copy synced with the earlier pass lets it go.
        var readAll = owed
        readAll.cleared = true
        readAll.clearedAll = true
        let afterClear = next(review, filed: once, saved: held, restores: [readAll])
        #expect(retires(afterClear) && !marks(afterClear))

        // A clear of some other passage leaves it: the writing's own save had
        // recorded the restore by then, and that clear does not touch it.
        var readOne = owed
        readOne.cleared = true
        let afterOther = next(review, filed: once, saved: held, restores: [readOne])
        #expect(!retires(afterOther) && marks(afterOther))

        // A selection over the restored words marked as reviewed: worked out
        // at the clear, from the restore itself, it reads the mark the
        // restore makes again, and a pass after one filed it retires it, as
        // the writing's own record, holding that mark, would clear it.
        let dog = (held as NSString).range(of: "dog")
        let reading = try #require(WritingReviewSession.remarksRead(by: dog, in: held, of: owed))
        #expect(reading.whole == filed)
        var readThere = owed
        readThere.cleared = true
        readThere.remarksRead = reading.whole
        readThere.remarkClearances = reading.parts
        let afterSelection = next(review, filed: once, saved: held, restores: [readThere])
        #expect(retires(afterSelection) && !marks(afterSelection))
        // Read in a later text, typed into elsewhere, it is the same mark.
        let typedOn = held + " And more."
        #expect(WritingReviewSession.remarksRead(by: dog, in: typedOn, of: owed)?.whole == filed)
        // A selection elsewhere reads none of it, and the mark stays.
        let elsewhere = (typedOn as NSString).range(of: "more")
        #expect(WritingReviewSession.remarksRead(by: elsewhere, in: typedOn, of: owed) == nil)
        // Nothing a clear read is retired where no pass filed it.
        #expect(!retires(next(review, filed: nil, saved: third, restores: [readThere])))
        // And a mark the writing gains after the clear, over the words it
        // covered, is the writing's to decide: the clear's result names only
        // the restore's own marks, so the pass leaves it.
        let gained = once.markingAssistantChange(from: held, to: "The dog stood.")
        let gainedIDs = Set(gained.marks.map(\.id)).subtracting(once.marks.map(\.id))
        let afterGain = next(gained, filed: once, saved: "The dog stood.", restores: [readThere])
        #expect(!gainedIDs.isEmpty && gainedIDs.isDisjoint(with: Set(afterGain?.retired.map(\.id) ?? [])))

        // Another device's recording reached the writing first, its mark
        // standing there: Mark All retires it all the same.
        let recordedElsewhere = review.restoringWording(plan, from: third, to: held, carryingFrom: [third])
        #expect(!Set(recordedElsewhere.marks.map(\.id)).isDisjoint(with: filed))
        let overThat = next(recordedElsewhere, filed: nil, saved: held, restores: [readAll])
        #expect(retires(overThat) && !marks(overThat))

        // Where nothing else is left to file, every mark read and this
        // restore not proved by the copy's text: the retirement is still
        // filed, not dropped with an empty record.
        let onlyTheClear = next(review.clearingAll(), filed: once, saved: third, restores: [readAll])
        #expect(retires(onlyTheClear))

        // Nothing retires a mark no pass filed: cleared and then undone
        // before any pass, the restore is only let go, as the writing's save
        // lets it go, and a later restore of the same words is marked.
        let neverFiled = next(review, filed: nil, saved: third, restores: [readAll])
        #expect(!retires(neverFiled))
        var hollow = readAll.pending([])
        hollow.clearedAll = true
        let later = next(review, filed: nil, saved: held, restores: [hollow, owed])
        #expect(!retires(later) && marks(later))
        // But one the keep let go after a pass filed its mark goes on
        // retiring it, under Mark All.
        var letGoHere = hollow
        letGoHere.keptLetGo = Set(plan.marks)
        #expect(retires(next(review, filed: once, saved: third, restores: [letGoHere])))

        // And restorations older than core keeps are not carried back in.
        var old = review
        old.restorations = [LampWritingReview.Restoration(
            markID: UUID(), turnID: nil, restored: "x", discarded: "y",
            restoredAt: Date().addingTimeInterval(-LampWritingReview.restorationWindow - 60)
        )]
        let pruned = next(old, filed: once, saved: held, restores: [owed])
        #expect(pruned?.restorations.allSatisfy { Date().timeIntervalSince($0.restoredAt) < LampWritingReview.restorationWindow } == true)

        // And with no restore owed at all, the writer having read every mark
        // while the keep ran: the record of that reading is filed.
        let everyMarkRead = review.clearingAll()
        #expect(everyMarkRead.marks.isEmpty && everyMarkRead.restorations.isEmpty && !everyMarkRead.retired.isEmpty)
        let readCopy = WritingReviewSession.keptCopyRecord(
            of: everyMarkRead, as: "copy", saved: third, current: third, text: third, proseTexts: [third], known: [third],
            relinked: { $0 }, restores: []
        ).record
        #expect(readCopy != nil)
        #expect(Set(everyMarkRead.retired.map(\.id)).isSubset(of: Set(readCopy?.retired.map(\.id) ?? [])))

        // Only the restored passage was marked, and the writing recorded
        // the restore itself in between: the copy still gets the record.
        let only = LampWritingReview(writingID: "w").markingAssistantChange(from: "One two.", to: "One alpha two.")
        let alpha = try #require(only.located(in: "One alpha two.").first?.id)
        guard case .plan(let deletion) = only.restoring(marks: [alpha], in: "One alpha two.") else {
            Issue.record("the insertion can be taken back out")
            return
        }
        let putBack = deletion.applied(to: "One alpha two.")
        let recorded = only.restoringWording(deletion, from: "One alpha two.", to: putBack, carryingFrom: ["One alpha two."])
        let owedDeletion = WritingReviewSession.OwedRestore(
            restore: WritingReviewSession.PageRestore(base: "One alpha two.", restored: putBack, plan: deletion), held: putBack
        )
        let copy = WritingReviewSession.keptCopyRecord(
            of: recorded, as: "copy", saved: putBack, current: putBack, text: putBack, proseTexts: ["One alpha two."],
            known: ["One alpha two."], relinked: { $0 }, restores: [owedDeletion]
        ).record
        #expect(copy?.restorations.contains { $0.markID == alpha } == true)
    }

    /// Each pass of a keep adds to the record the last one filed, as each
    /// save of the writing adds to its record: a restore one pass recorded
    /// stays recorded, and its mark retired, after the writer undoes it and
    /// a later pass saves the undone words, as two saves of the writing
    /// would leave it. And no pass drops what an earlier one filed: the
    /// earlier record joined into the later changes nothing.
    @Test func aKeptCopyAddsToWhatEarlierPassesFiled() throws {
        let first = "The cat sat."
        let second = "The dog sat."
        let third = "The bird sat."
        let review = LampWritingReview(writingID: "w")
            .markingAssistantChange(from: first, to: second)
            .markingAssistantChange(from: second, to: third)
        let latest = try #require(review.located(in: third).first { located in
            located.ranges.contains { (third as NSString).substring(with: $0).contains("bird") }
        }?.id)
        guard case .plan(let plan) = review.restoring(marks: [latest], in: third) else {
            Issue.record("the second turn's passage can be put back")
            return
        }
        let held = plan.applied(to: third)
        let owed = WritingReviewSession.OwedRestore(
            restore: WritingReviewSession.PageRestore(base: third, restored: held, plan: plan), held: held
        )
        func pass(filed: LampWritingReview?, saved: String) -> LampWritingReview? {
            WritingReviewSession.keptCopyRecord(
                of: review, filed: filed, as: "copy", saved: saved, current: saved, text: saved,
                proseTexts: [third], known: [third] + (filed == nil ? [] : [held]),
                relinked: { $0 }, restores: [owed]
            ).record
        }
        let once = try #require(pass(filed: nil, saved: held))
        #expect(once.restorations.contains { $0.markID == latest })

        // Undone, and the next pass saves the undone words.
        let undone = try #require(pass(filed: once, saved: third))
        #expect(undone.restorations.contains { $0.markID == latest })
        #expect(undone.retired.contains { $0.id == latest })
        #expect(!undone.marks.contains { $0.id == latest })
        // Nothing the first pass filed is dropped by the second: joining the
        // first's record into it adds no mark, retirement, restoration or
        // clearance it does not hold. (Which of two retirements' times a join
        // keeps is no part of that.)
        func holds(_ r: LampWritingReview) -> [String] {
            [
                r.marks.map { "\($0.id) v\($0.version)" }.sorted().joined(separator: ","),
                r.retired.map(\.id.uuidString).sorted().joined(separator: ","),
                r.restorations.map(\.markID.uuidString).sorted().joined(separator: ","),
                r.clearances.map(\.id.uuidString).sorted().joined(separator: ","),
            ]
        }
        #expect(holds(undone.merged(with: once)) == holds(undone))

        // And a pass that types on adds to the first likewise.
        let typed = try #require(pass(filed: once, saved: held + " More."))
        #expect(holds(typed.merged(with: once)) == holds(typed))
    }

    /// From Codex's review: a clear of part of a restore's words, worked out
    /// in the writing's own text, is rewritten into the copy's picture links
    /// before it is filed there, words, context and place, so it lands where
    /// the copy's own marks do.
    @Test func aPartClearanceIsRelinkedForTheCopy() {
        let held = "![p](lamp-media://W/p) dog dog"
        let second = (held as NSString).range(of: "dog", options: .backwards)
        let piece = LampWritingReview.Piece(
            text: "dog", before: "![p](lamp-media://W/p) dog ", after: "",
            hint: second.location, anchoredIn: LampWritingReview.digest(of: held)
        )
        let clearance = LampWritingReview.Clearance(markID: UUID(), pieces: [piece], clearedAt: Date())
        let relink: (String) -> String = { $0.replacingOccurrences(of: "lamp-media://W/", with: "lamp-media://copy-id/") }
        let moved = WritingReviewSession.relinked(clearance, from: held, by: relink)
        let target = relink(held)
        let p = moved.pieces[0]
        #expect(p.text == "dog" && p.before == "![p](lamp-media://copy-id/p) dog ")
        #expect(p.hint == (target as NSString).range(of: "dog", options: .backwards).location)
        #expect(p.anchoredIn == LampWritingReview.digest(of: target))
        #expect(moved.id == clearance.id && moved.markID == clearance.markID)
    }

    /// The page takes a block's marks off as its ✓ is pressed, so every
    /// clear from it is answered with the marks, drawn again and sent: one
    /// that changes nothing in the record, and one this cannot place,
    /// would otherwise leave whatever the page took off, off.
    @Test func aClearFromThePageIsAlwaysAnsweredWithTheMarks() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "answered-\(UUID().uuidString)"
        let new = "One alpha three.\n\nFour five six."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let session = WritingReviewSession()
        var sent = 0
        session.onMarksChanged = { _, _ in sent += 1 }
        let following = Task { await session.follow(writingID: id, text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 && sent > 0 }
        let before = try store.review(writingID: id)

        // A block with no marks in it: the record is unchanged.
        let settled = sent
        session.clear(
            markedMarkdown: new.replacingOccurrences(
                of: "Four five six.", with: "\(LampWritingReview.markStart)Four five six.\(LampWritingReview.markEnd)"
            ),
            pageText: new
        )
        try await waitUntil { sent > settled }
        #expect(try store.review(writingID: id) == before)

        // Text neither here nor the page's: nothing can be placed.
        let placed = sent
        session.clear(markedMarkdown: "Elsewhere \(LampWritingReview.markStart)entirely\(LampWritingReview.markEnd).")
        try await waitUntil { sent > placed }
        #expect(try store.review(writingID: id) == before)
    }

    /// Codex's case: markers can change how the page writes what is round
    /// them, so the marked Markdown with its markers taken out is text the
    /// page never held. A page that sends no text of its own clears only
    /// where its marked Markdown matches the writing here, and nothing is
    /// remembered from it.
    @Test func aClearWithNoPageTextIsMadeOnlyInTheWritingHere() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "no-page-text-\(UUID().uuidString)"
        let new = "One alpha three.\n\nFour beta six."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let before = try store.review(writingID: id)
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 2 }

        let ahead = "One alpha three.\n\nFour beta six. More."
        session.clear(markedMarkdown: ahead.replacingOccurrences(
            of: "beta", with: "\(LampWritingReview.markStart)beta\(LampWritingReview.markEnd)"
        ))
        try await Task.sleep(for: .milliseconds(300))
        #expect(try store.review(writingID: id) == before)
        #expect(!session.texts.contains(ahead))
    }

    /// Codex's case: a selection inside an autolink. The page (iOS a70d4db,
    /// its script in the Mac's copy) takes the whole link between its
    /// markers and writes it as it always does, and sends its own text
    /// beside it; the clear lands, from the writing here or from that text.
    @Test func aSelectionInsideAnAutolinkClears() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "autolink-\(UUID().uuidString)"
        let link = "<https://example.org>"
        let new = "See \(link) now."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(from: "See it now.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let marked = "See \(LampWritingReview.markStart)\(link)\(LampWritingReview.markEnd) now."
        session.clear(markedMarkdown: marked, pageText: new)
        try await waitUntil { (try? store.review(writingID: id))?.isEmpty == true }

        // Ahead of the writing here: made in the page's own text.
        try store.save(LampWritingReview(writingID: id + "-ahead").markingAssistantChange(from: "See it now.", to: new))
        let ahead = new + " More."
        let other = WritingReviewSession()
        let followingAhead = Task {
            await other.follow(writingID: id + "-ahead", text: new, libraryRootURL: root, isShown: true)
        }
        defer { followingAhead.cancel() }
        try await waitUntil { other.count == 1 }
        other.clear(
            markedMarkdown: "See \(LampWritingReview.markStart)\(link)\(LampWritingReview.markEnd) now. More.",
            pageText: ahead
        )
        try await waitUntil { (try? store.review(writingID: id + "-ahead"))?.isEmpty == true }
    }

    /// Codex's case: typing into a marked passage, not yet saved, splits it.
    /// Both halves are still counted and drawn, not nothing.
    @Test func unsavedTypingIntoAMarkKeepsItCounted() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let new = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: "w").markingAssistantChange(from: "One two three.", to: new))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        try await waitUntil {
            session.ranges.map { (typed as NSString).substring(with: $0) } == ["alpha", "beta gamma"]
        }
        #expect(session.count > 0)
    }

    /// Codex's case: another window took the assistant's draft in, and its
    /// marks are made, but its save has not landed. A clear in a window that
    /// still holds the text before carries nothing from the draft it never
    /// held, so the draft's new words keep their mark.
    @Test func aClearLeavesTheMarksOfADraftItsWindowNeverHeld() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "other-window-\(UUID().uuidString)"
        let held = "One alpha three.\n\nFour five six."
        let draft = "One alpha three.\n\nFour beta six."
        try store.save(
            LampWritingReview(writingID: id)
                .markingAssistantChange(from: "One two three.\n\nFour five six.", to: held)
                .markingAssistantChange(from: held, to: draft)
        )
        WritingReviewTexts.shared.remember(draft, for: id)
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: held, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.count == 1 }

        session.clear(range: (held as NSString).range(of: "alpha"))
        try await waitUntil {
            let review = try? store.review(writingID: id)
            return review?.highlightedRanges(in: draft).map { (draft as NSString).substring(with: $0) } == ["beta"]
        }
    }

    /// Codex's case: the window takes an assistant's draft in and the
    /// writer types into it before the text settles. The draft is held at
    /// once, so a clear still carries its mark from it.
    @Test func aDraftTakenInIsHeldBeforeTypingIntoIt() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LampWritingReviewStore(rootURL: root)
        let id = "draft-held-\(UUID().uuidString)"
        let before = "One two three."
        let draft = "One alpha beta gamma three."
        try store.save(LampWritingReview(writingID: id).markingAssistantChange(from: before, to: draft))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: id, text: before, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.texts == [before] }
        try await Task.sleep(for: .milliseconds(100))

        session.holds(draft)
        let typed = "One alpha mine beta gamma three."
        session.textChanged(typed)
        session.clear(range: (typed as NSString).range(of: "gamma"))
        try await waitUntil {
            let review = try? store.review(writingID: id)
            return review?.highlightedRanges(in: typed).map { (typed as NSString).substring(with: $0) } == ["alpha", "beta"]
        }
    }

    /// Codex's case: marks turned off and on again, with an edit between.
    /// The texts the editor held before are kept, to carry from.
    @Test func turningMarksOffAndOnKeepsTheTextsHeld() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "off-and-on-\(UUID().uuidString)"
        let session = WritingReviewSession()
        let first = Task { await session.follow(writingID: id, text: "One alpha three.", libraryRootURL: root, isShown: true) }
        try await waitUntil { session.texts == ["One alpha three."] }
        first.cancel()
        await session.follow(writingID: id, text: "One alpha three. More.", libraryRootURL: root, isShown: false)
        let again = Task { await session.follow(writingID: id, text: "One alpha three. More.", libraryRootURL: root, isShown: true) }
        defer { again.cancel() }
        #expect(session.texts == ["One alpha three.", "One alpha three. More."])

        let other = Task { await session.follow(writingID: "another-\(id)", text: "Else.", libraryRootURL: root, isShown: true) }
        defer { other.cancel() }
        try await waitUntil { session.texts == ["Else."] }
    }

    /// What `.lamp/editor.md` tells a Terminal agent: the passages still
    /// marked, that nothing is once the writer clears them, and that
    /// nothing is when no mark was ever made.
    @Test func theAgentIsToldWhatIsMarkedAsItIsDrawn() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let new = "One deux three.\n\nFour five six."
        try LampWritingReviewStore(rootURL: root).save(LampWritingReview(writingID: "w").markingAssistantChange(
            from: "One two three.\n\nFour five six.", to: new
        ))
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: new, libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote?.contains("- \"deux\"") == true }
        session.clearAll()
        try await waitUntil { session.agentNote?.contains("Everything in the writing has been read and cleared") == true }

        let unmarked = WritingReviewSession()
        let followingUnmarked = Task {
            await unmarked.follow(writingID: "never-marked", text: "Mine.", libraryRootURL: root, isShown: true)
        }
        defer { followingUnmarked.cancel() }
        try await waitUntil { unmarked.agentNote?.contains("Everything in the writing has been read and cleared") == true }
    }

    /// A marks file that cannot be read leaves the agent told marks are on
    /// but unread, never nothing (which it is told means off) nor that
    /// everything has been read.
    @Test func marksThatCannotBeReadAreSaidToBeUnread() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        #expect(files.count == 1)
        for file in files { try Data("not a review".utf8).write(to: file) }
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote != nil }
        try await Task.sleep(for: WritingReviewSession.checkInterval + .milliseconds(300))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote)
        // A draw before any read, as a rejection from the page asks for,
        // still says unread rather than that nothing is marked.
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote)
    }

    /// Read once, then unreadable: the agent is told the marks are unread,
    /// not the last note read, until a read succeeds again.
    @Test func marksThatBecomeUnreadableAreSaidToBeUnread() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let session = WritingReviewSession()
        let following = Task { await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: true) }
        defer { following.cancel() }
        try await waitUntil { session.agentNote?.contains("- \"c\"") == true }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        let saved = try files.map { ($0, try Data(contentsOf: $0)) }
        for file in files { try Data("not a review".utf8).write(to: file) }
        try await waitUntil { session.agentNote == WritingChatTurns.unreadReviewNote }
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == WritingChatTurns.unreadReviewNote, "a draw meanwhile still says unread")
        for (file, data) in saved { try data.write(to: file) }
        try await waitUntil { session.agentNote?.contains("- \"c\"") == true }
    }

    @Test func turnedOffNothingIsShown() async throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        try LampWritingReviewStore(rootURL: root).save(
            LampWritingReview(writingID: "w").markingAssistantChange(from: "a b", to: "a c")
        )
        let session = WritingReviewSession()
        var sent: [String?] = []
        session.onMarksChanged = { marked, _ in sent.append(marked) }
        await session.follow(writingID: "w", text: "a c", libraryRootURL: root, isShown: false)
        #expect(session.count == 0)
        #expect(sent == [nil])
        #expect(session.agentNote == nil, "the agent is told nothing of marks that are off")
        // A rejection the page sends after marks went off draws again, and
        // still says nothing.
        session.marksRejected()
        try await Task.sleep(for: WritingReviewSession.settleDelay + .milliseconds(200))
        #expect(session.agentNote == nil)
    }

    @Test func aPlaceInLineIsFilledInOrderAndGivingUpMovesTheLineOn() async {
        let log = Log()
        let first = WritingReviewWork.shared.reserve()
        WritingReviewWork.shared.run { await log.add("second") }
        let third = WritingReviewWork.shared.reserve()
        third.giveUp()
        first.fill { await log.add("first") }
        await WritingReviewWork.shared.drained()
        #expect(await log.entries == ["first", "second"])
    }

    @Test func workFilledInAfterItsPlaceGaveUpIsDroppedNotRunLate() async throws {
        let work = WritingReviewWork.shared
        let saved = work.reservationPatience
        defer { work.reservationPatience = saved }
        work.reservationPatience = .milliseconds(100)
        let log = Log()
        let late = work.reserve()
        work.run { await log.add("after") }
        await work.drained()
        late.fill { await log.add("late") }
        try await Task.sleep(for: .milliseconds(200))
        await work.drained()
        #expect(await log.entries == ["after"])
    }

    private actor Log {
        var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }
}
