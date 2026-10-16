import LampCore
import SwiftUI

/// One writing that two devices changed at the same moment, with both versions
/// side by side and a choice to make.
///
/// Both are shown rather than summarised, because the modification times are
/// identical by definition — the text is the only thing left to tell them
/// apart, and a date would just print the same number twice.
struct SyncConflictRow: View {
    let conflict: LampSyncConflict
    let keep: (LampSyncConflict.Side) -> Void
    let dismiss: () -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(conflict.title)
                    .font(.headline)
                Spacer(minLength: 8)
                Button(isExpanded ? "Hide Versions" : "Compare Versions") {
                    isExpanded.toggle()
                }
                .buttonStyle(.link)
                .font(.callout)
            }

            Text(changedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if isExpanded {
                HStack(alignment: .top, spacing: 12) {
                    version("This Mac", conflict.thisDevicePreview)
                    version("The other device", conflict.otherDevicePreview)
                }
            }

            HStack {
                Button("Keep This Mac’s") { keep(.thisDevice) }
                Button("Keep the Other Device’s") { keep(.otherDevice) }
                Spacer()
                Button("Ask Me Later", action: dismiss)
                    .buttonStyle(.link)
                    .help("Leave this Mac’s copy as it is and stop showing this")
            }
        }
        .padding(.vertical, 4)
    }

    /// Identical text on both sides means the two versions differ somewhere a
    /// preview does not reach — a title, a date, a key scripture — so say that
    /// rather than show two panes that look the same.
    private var changedDescription: String {
        if conflict.differsBeyondBody {
            return "Both versions read the same here; they differ in their details. Keeping one drops the other’s."
        }
        return "Changed in both places at \(conflict.detected.formatted(date: .abbreviated, time: .shortened))."
    }

    private func version(_ label: String, _ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(preview.isEmpty ? "No text" : preview)
                .font(.callout)
                .foregroundStyle(preview.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
