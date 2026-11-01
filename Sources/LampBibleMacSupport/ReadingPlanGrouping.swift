import Foundation
import LampCore
import LampModuleKit

/// Which reading plans came with Lamp, and which the reader has of their own.
///
/// A `LampReadingPlan` doesn't say where it came from. The installed-module
/// record does, and that same record is what a removal is made through, so
/// the heading a plan is listed under and the Delete it offers answer to one
/// lookup rather than two that could disagree.
///
/// A plan with no record of its own is listed as included. It cannot be
/// removed either way — there is nothing to remove it by — and listing it
/// under the reader's own plans would promise a Delete that isn't there.
public enum LampReadingPlanGrouping {
    public struct Groups: Equatable, Sendable {
        /// The plans that came with Lamp.
        public let included: [LampReadingPlan]
        /// The ones made here, added by another app, or installed as a module.
        public let yours: [LampReadingPlan]

        public init(included: [LampReadingPlan], yours: [LampReadingPlan]) {
            self.included = included
            self.yours = yours
        }

        /// Whether to head the two lists at all. Until there is a plan of the
        /// reader's own, naming the other group "Included" says nothing: the
        /// list is the same list it has always been.
        public var isSplit: Bool { !included.isEmpty && !yours.isEmpty }
    }

    public static func split(
        _ plans: [LampReadingPlan],
        installed: [LampInstalledModule]
    ) -> Groups {
        let mine = Set(
            installed.lazy.filter { $0.kind == .plan && !$0.isBundled }.map(\.id)
        )
        return Groups(
            included: plans.filter { !mine.contains($0.id) },
            yours: plans.filter { mine.contains($0.id) }
        )
    }

    /// The module record `plan` is removed through, or nil when it came with
    /// Lamp and so cannot be removed.
    public static func removableModule(
        for plan: LampReadingPlan,
        installed: [LampInstalledModule]
    ) -> LampInstalledModule? {
        installed.first { $0.kind == .plan && $0.id == plan.id && !$0.isBundled }
    }
}
