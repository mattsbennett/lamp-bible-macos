import Foundation
import Testing
@testable import LampBibleMacSupport

struct TextScaleSupportTests {
    private let scale = LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 16)

    @Test func clampingHoldsValuesInsideTheRange() {
        #expect(scale.clamped(9) == 13)
        #expect(scale.clamped(40) == 20)
        #expect(scale.clamped(15) == 15)
    }

    @Test func steppingMovesByWholeSteps() {
        #expect(scale.stepped(16, by: 1) == 17)
        #expect(scale.stepped(16, by: -1) == 15)
        #expect(scale.stepped(16, by: 3) == 19)
    }

    @Test func steppingStopsAtTheBounds() {
        #expect(scale.stepped(20, by: 1) == 20)
        #expect(scale.stepped(13, by: -1) == 13)
        #expect(scale.stepped(19, by: 5) == 20)
    }

    @Test func steppingSnapsAValueLeftBetweenGridPoints() {
        // A slider, or a stored size from an older step, can leave a half point
        // behind; travelling should land on the grid rather than carry it along.
        #expect(scale.stepped(16.5, by: 1) == 17)
        #expect(scale.stepped(16.5, by: -1) == 16)
    }

    @Test func steppingFromOutsideTheRangeReentersIt() {
        #expect(scale.stepped(40, by: 1) == 20)
        #expect(scale.stepped(40, by: -1) == 19)
        #expect(scale.stepped(2, by: 1) == 14)
    }

    @Test func boundsReportWhetherThereIsRoomToMove() {
        #expect(scale.canIncrease(19))
        #expect(!scale.canIncrease(20))
        #expect(scale.canDecrease(14))
        #expect(!scale.canDecrease(13))
        #expect(!scale.canIncrease(40))
        #expect(!scale.canDecrease(2))
    }

    @Test func initializerKeepsTheDefaultInsideTheRange() {
        let low = LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 4)
        let high = LampTextScale(minimum: 13, maximum: 20, step: 1, defaultValue: 99)

        #expect(low.defaultValue == 13)
        #expect(high.defaultValue == 20)
    }

    @Test func shippedScalesContainTheirDefaults() {
        for scale in [
            LampTextScale.readerText,
            .readerLineSpacing,
            .commentaryText,
            .commentaryLineSpacing,
            .quizText,
            .quizLineSpacing,
            .bookText,
            .bookLineSpacing,
        ] {
            #expect(scale.range.contains(scale.defaultValue))
        }
    }
}
