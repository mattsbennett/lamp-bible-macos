import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// Core's store errors carry no description, so one reached the user as
/// "LampSyncSettingsStore.StoreError error 2" — which says nothing about
/// what happened, whether anything was changed, or what to do. Every case
/// answers all three now, and these hold it.
struct LampSyncErrorTextTests {
    private let cases: [LampSyncSettingsStore.StoreError] = [
        .notMigrated(revision: "\"a-1\""),
        .unversioned,
        .tooManyAttempts,
        .unreadableVersion("a conflict copy"),
        .versionsNeedAMerge,
    ]

    @Test func noCaseReachesSomeoneAsAnEnumName() {
        for error in cases {
            let sentence = LampSyncErrorText.sentence(for: error)
            #expect(!sentence.contains("StoreError"))
            #expect(!sentence.contains("error 2"))
            #expect(sentence.count > 40, "a sentence, not a label: \(sentence)")
        }
    }

    /// The question someone actually has when a sync fails.
    @Test func everyCaseSaysWhetherAnythingWasChanged() {
        for error in cases {
            let sentence = LampSyncErrorText.sentence(for: error).lowercased()
            #expect(
                sentence.contains("nothing was changed") || sentence.contains("nothing was lost"),
                "\(error) does not say whether anything was changed"
            )
        }
    }

    @Test func theUnmigratedCaseSaysToUseTheMove() {
        let sentence = LampSyncErrorText.sentence(for: .notMigrated(revision: nil))
        #expect(sentence.contains("Sync Now"))
        #expect(sentence.contains("move"))
    }

    @Test func anythingElseKeepsItsOwnDescription() {
        struct Plain: LocalizedError {
            var errorDescription: String? { "The server could not be reached." }
        }
        #expect(
            LampSyncErrorText.sentence(for: Plain()) == "The server could not be reached."
        )
    }
}
