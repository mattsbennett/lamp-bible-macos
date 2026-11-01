import Foundation
import LampCore
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// Telling Lamp's own reading plans from the reader's own, and knowing which
/// of them a Delete can be offered on.
///
/// A plan carries no sign of where it came from, so both answers are read off
/// the installed-module record. One lookup for both, because a plan listed
/// under "Your Plans" with no Delete, or a Delete that removes nothing, are
/// the same bug told two ways.
struct ReadingPlanGroupingTests {
    private func plan(_ id: String, _ name: String) -> LampReadingPlan {
        LampReadingPlan(id: id, name: name, duration: 30)
    }

    private func module(_ id: String, bundled: Bool) -> LampInstalledModule {
        LampInstalledModule(id: id, kind: .plan, name: id, isBundled: bundled)
    }

    @Test func abundledPlanIsIncludedAndTheReadersIsTheirs() {
        let groups = LampReadingPlanGrouping.split(
            [plan("mcheyne", "M'Cheyne"), plan("plan-abc", "The Gospels in a Month")],
            installed: [module("mcheyne", bundled: true), module("plan-abc", bundled: false)]
        )

        #expect(groups.included.map(\.id) == ["mcheyne"])
        #expect(groups.yours.map(\.id) == ["plan-abc"])
    }

    /// A plan file someone installed is theirs too: they put it there, and
    /// they can take it away again. Only what shipped with Lamp is included.
    @Test func aninstalledPlanFileCountsAsTheReadersOwn() {
        let groups = LampReadingPlanGrouping.split(
            [plan("someones-plan", "A Plan From A Friend")],
            installed: [module("someones-plan", bundled: false)]
        )

        #expect(groups.yours.map(\.id) == ["someones-plan"])
    }

    /// Both groups are always headed, so an empty one is a real answer: it
    /// says the reader has made none yet, and it is where New Plan lives.
    @Test func thereadersGroupIsEmptyRatherThanAbsent() {
        let groups = LampReadingPlanGrouping.split(
            [plan("mcheyne", "M'Cheyne")],
            installed: [module("mcheyne", bundled: true)]
        )

        #expect(groups.included.map(\.id) == ["mcheyne"])
        #expect(groups.yours.isEmpty)
    }

    @Test func theorderWithinEachGroupIsTheOrderGiven() {
        let groups = LampReadingPlanGrouping.split(
            [plan("a", "A"), plan("plan-1", "One"), plan("b", "B"), plan("plan-2", "Two")],
            installed: [
                module("a", bundled: true), module("b", bundled: true),
                module("plan-1", bundled: false), module("plan-2", bundled: false),
            ]
        )

        #expect(groups.included.map(\.id) == ["a", "b"])
        #expect(groups.yours.map(\.id) == ["plan-1", "plan-2"])
    }

    /// Shouldn't happen — the plans and the modules are read in one pass —
    /// but if it did, the plan is listed as included rather than offered a
    /// Delete there is no module to carry out.
    @Test func aplanWithNoModuleRecordIsListedAsIncluded() {
        let groups = LampReadingPlanGrouping.split([plan("orphan", "Orphan")], installed: [])

        #expect(groups.included.map(\.id) == ["orphan"])
        #expect(groups.yours.isEmpty)
    }

    // MARK: - What a Delete is offered on

    @Test func thereadersOwnPlanIsRemovableThroughItsModule() {
        let module = module("plan-abc", bundled: false)

        #expect(
            LampReadingPlanGrouping.removableModule(
                for: plan("plan-abc", "The Gospels in a Month"), installed: [module]
            ) == module
        )
    }

    @Test func abundledPlanIsNotRemovable() {
        #expect(
            LampReadingPlanGrouping.removableModule(
                for: plan("mcheyne", "M'Cheyne"), installed: [module("mcheyne", bundled: true)]
            ) == nil
        )
    }

    /// A module of another kind sharing the ID is not this plan.
    @Test func amoduleOfAnotherKindIsNotThePlan() {
        let book = LampInstalledModule(id: "plan-abc", kind: .book, name: "A Book")

        #expect(
            LampReadingPlanGrouping.removableModule(
                for: plan("plan-abc", "The Gospels"), installed: [book]
            ) == nil
        )
    }

    // MARK: - What the deletion carries to the other devices

    /// `LibraryModel.remove(_:)` records a removal through
    /// `LampSyncRemovedModules`, which refuses any path core's rule refuses —
    /// a tombstone one client obeys and another won't is how a notes
    /// collection gets emptied. A plan is never such a path: the rule reads
    /// the folder as well as the ID, so a plan called `notes` is still a
    /// plan. Checked because the plans are the first thing Lamp lets people
    /// make and delete themselves.
    @Test(arguments: ["plan-14772CA1-4CAC-48B5-BB19-A61F51A1390A", "notes", "devotionals"])
    func aplanRemovalIsADeletionEveryClientCarriesOut(id: String) throws {
        let path = try LampSyncFolderLayout.modulePath(
            kind: LampSyncContentKind(.plan), moduleID: id
        )

        #expect(LampSyncLocalDeletion.target(of: path) == .module(id))
        #expect(LampSyncLocalDeletion.target(of: path).isAllowed)
    }
}

/// How long a plan is, as the card says it.
///
/// The built-in plans are all 366 days — year-round plans keeping a slot for
/// 29 February whether or not the year has one. True, and not what anyone
/// means by it: people call a year 365 days, and three plans all reading
/// "366 days" looked like a bug rather than a fact.
struct ReadingPlanLengthTests {
    private func plan(days: Int) -> LampReadingPlan {
        LampReadingPlan(id: "p", name: "A Plan", duration: days)
    }

    @Test(arguments: [365, 366])
    func ayearRoundPlanSaysAYear(days: Int) {
        #expect(plan(days: days).lengthDescription == "A year")
    }

    @Test func ashorterPlanCountsItsDays() {
        #expect(plan(days: 22).lengthDescription == "22 days")
        #expect(plan(days: 90).lengthDescription == "90 days")
    }

    @Test func onedayIsNotOneDays() {
        #expect(plan(days: 1).lengthDescription == "1 day")
    }

    /// A plan just short of the year is still counted: "A year" is for the
    /// ones that fill it, not for anything near it.
    @Test func aplanJustShortOfAYearIsStillCounted() {
        #expect(plan(days: 364).lengthDescription == "364 days")
    }
}
