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
        #expect(groups.isSplit)
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

    /// With nothing of the reader's own there is nothing to tell apart, and
    /// heading the list "Included" would name a distinction that isn't there.
    @Test func thelistIsNotSplitUntilThereIsAPlanOfTheReadersOwn() {
        let groups = LampReadingPlanGrouping.split(
            [plan("mcheyne", "M'Cheyne")],
            installed: [module("mcheyne", bundled: true)]
        )

        #expect(!groups.isSplit)
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
