import Sparkle
import SwiftUI

/// Sparkle's updater, exposed to SwiftUI.
///
/// The updater only starts when the build carries both a feed URL and an EdDSA public key.
/// Without the key Sparkle rejects every update and alerts at launch, so a build that isn't
/// configured for distribution has updates switched off instead.
///
/// Sparkle asks for permission on the second launch before it checks automatically, which
/// keeps the app from contacting the network until the user has agreed to it.
@MainActor
final class SoftwareUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    let isConfigured: Bool
    private let controller: SPUStandardUpdaterController

    init(bundle: Bundle = .main) {
        isConfigured = Self.hasValue(for: "SUFeedURL", in: bundle)
            && Self.hasValue(for: "SUPublicEDKey", in: bundle)
        controller = SPUStandardUpdaterController(
            startingUpdater: isConfigured,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    private var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyDownloadsUpdates = newValue
        }
    }

    /// False when the feed or a system policy forbids silent installation.
    var allowsAutomaticUpdates: Bool { updater.allowsAutomaticUpdates }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    private static func hasValue(for key: String, in bundle: Bundle) -> Bool {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return false }
        return !value.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The app menu's "Check for Updates…" item.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: SoftwareUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
