import LampCore
import SwiftUI

/// One record that two devices changed at the same moment, with both versions
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

            Text("\(whatItIs) · \(changedDescription)")
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

    /// Notes outnumber writings and rarely carry a title, so the heading is
    /// often the verse itself; this line says which it is either way.
    private var whatItIs: String {
        switch conflict.kind {
        case .devotional: "Writing"
        case .note: conflict.subtitle.map { "Note on \($0)" } ?? "Note"
        }
    }

    /// Name what actually disagrees. Two panes of prose invite someone to read
    /// for a difference that may be a date or a tag, and when the words really
    /// are identical there is nothing to find by reading at all.
    private var changedDescription: String {
        if conflict.differsBeyondBody {
            return "Both versions read the same; they differ in \(conflict.differenceSummary). "
                + "Keeping one drops the other’s."
        }
        return "They differ in \(conflict.differenceSummary), found "
            + "\(conflict.detected.formatted(date: .abbreviated, time: .shortened))."
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
