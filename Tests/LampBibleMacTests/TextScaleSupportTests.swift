import Foundation
import LampModuleKit
import Testing
@testable import LampBibleMacSupport

/// `LampTextScale` itself is core's, and core tests how it clamps and steps.
/// What is this app's own is the nine scales it ships beyond the two the phone
/// shares, and a scale whose default sits outside its own range is a control
/// that cannot be returned to its default.
struct TextScaleSupportTests {
    @Test func shippedScalesContainTheirDefaults() {
        for scale in [
            LampTextScale.readerText,
            .readerLineSpacing,
            .commentaryText,
            .commentaryLineSpacing,
            .quizText,
            .quizLineSpacing,
            .writingReadingText,
            .writingReadingLineSpacing,
            .writingEditorText,
        ] {
            #expect(scale.range.contains(scale.defaultValue))
        }
    }
}
