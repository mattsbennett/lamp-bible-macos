import LampCore
import SwiftUI

/// Markdown files that have been read and planned, waiting for the person to
/// choose which become writing.
struct PendingWritingImport: Identifiable {
    let id = UUID()
    let sourceName: String
    let plan: LampWritingImportPlan
    /// Set when an agent asked for this import (`import_writings`), so what
    /// the person decides can be left for it to read.
    var requestID: String?
    /// What the agent wanted the person to know.
    var note: String?
}

/// Brings the Import window forward when an agent's import is waiting for
/// review, since its sheet is shown there. Put on each reader window.
struct WritingImportReviewOpener: ViewModifier {
    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingWritingImport?.requestID, initial: true) { _, requestID in
                if requestID != nil { openWindow(id: "add-to-library") }
            }
    }
}

/// What importing a folder or files of writing would do, file by file, with
/// nothing written until Import. New and updated writings come ticked; one
/// changed in Lamp since its file was saved waits to be chosen, and one that
/// cannot be imported says why.
struct WritingImportSheet: View {
    let pending: PendingWritingImport
    let onImport: (Set<String>) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String>
    @State private var onlyWithNotes = false

    init(
        pending: PendingWritingImport,
        onImport: @escaping (Set<String>) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.pending = pending
        self.onImport = onImport
        self.onCancel = onCancel
        _selection = State(initialValue: Set(
            pending.plan.items.filter(\.importsByDefault).map(\.id)
        ))
    }

    private var items: [LampWritingImportItem] { pending.plan.items }

    private var shownItems: [LampWritingImportItem] {
        onlyWithNotes ? items.filter(Self.hasNotes) : items
    }

    private var summary: String {
        let parts: [(LampWritingImportItem.Action, String)] = [
            (.create, "new"), (.update, "updated"), (.conflict, "changed in Lamp"),
            (.unchanged, "unchanged"), (.rejected, "can’t be imported"),
        ]
        return parts.compactMap { action, label in
            let count = pending.plan.count(action)
            return count == 0 ? nil : "\(count) \(label)"
        }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Writing from \(pending.sourceName)")
                    .font(.title2.bold())
                    .lineLimit(2)
                Text(summary)
                    .foregroundStyle(.secondary)
                if pending.requestID != nil {
                    Label(
                        pending.note.map { "Asked for by an agent: \($0)" }
                            ?? "Asked for by an agent.",
                        systemImage: "sparkles"
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }

            List {
                ForEach(shownItems) { item in
                    WritingImportRow(
                        item: item,
                        isSelected: Binding(
                            get: { selection.contains(item.id) },
                            set: { isOn in
                                if isOn { selection.insert(item.id) } else { selection.remove(item.id) }
                            }
                        )
                    )
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 280)

            HStack(spacing: 12) {
                Button("Tick New and Updated") {
                    selection = Set(items.filter(\.importsByDefault).map(\.id))
                }
                Button("Untick All") { selection = [] }
                Spacer()
                Toggle("Only files with notes", isOn: $onlyWithNotes)
                .tint(Color.lampAccentMuted)
                    .toggleStyle(.checkbox)
            }
            .controlSize(.small)

            Text("Nothing is written until you import. A file with no id of its own keeps one made from its path in the folder, so importing the folder again updates these writings rather than adding copies.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.lampSecondary)
                Button(importLabel) {
                    onImport(selection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.lampProminent)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640, height: 560)
    }

    private var importLabel: String {
        let decks = items.filter { $0.kind == .deck && selection.contains($0.id) }.count
        let writings = selection.count - decks
        let writing = writings == 1 ? "1 Writing" : "\(writings) Writings"
        guard decks > 0 else { return "Import \(writing)" }
        return "Import \(writing) and \(decks == 1 ? "1 Deck" : "\(decks) Decks")"
    }

    static func hasNotes(_ item: LampWritingImportItem) -> Bool {
        !item.errors.isEmpty || !item.warnings.isEmpty || item.action == .conflict
    }
}

private struct WritingImportRow: View {
    let item: LampWritingImportItem
    @Binding var isSelected: Bool

    private var canImport: Bool { item.canImport }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(isOn: $isSelected) { EmptyView() }
                .tint(Color.lampAccentMuted)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canImport)
                VStack(alignment: .leading, spacing: 1) {
                    if item.kind == .deck {
                        Label(item.title, systemImage: "rectangle.on.rectangle")
                            .lineLimit(1)
                    } else {
                        Text(item.title)
                            .lineLimit(1)
                    }
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 8)
                Text(actionLabel)
                    .font(.caption)
                    .foregroundStyle(item.action == .rejected ? Color.red : .secondary)
            }
            let notes = noteLines
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                        Text(note.text)
                            .foregroundStyle(note.isError ? Color.red : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.caption)
                .padding(.leading, 26)
            }
        }
        .padding(.vertical, 2)
        .opacity(canImport || item.action == .rejected ? 1 : 0.6)
    }

    private var actionLabel: String {
        switch item.action {
        case .create: item.kind == .deck ? "New Deck" : "New"
        case .update: "Update"
        case .conflict: item.kind == .deck ? "Changed in Slide Studio" : "Changed in Lamp"
        case .unchanged: "Unchanged"
        case .rejected: "Can’t import"
        }
    }

    private var noteLines: [(text: String, isError: Bool)] {
        var lines = item.errors.map { ($0, true) }
        if item.action == .conflict, item.kind == .deck {
            lines.append(("The deck in Lamp differs from this file, and may hold changes made in Slide Studio. Tick it to replace it with the file.", false))
        } else if item.action == .conflict {
            let when = item.libraryModified.map {
                " on \($0.formatted(date: .abbreviated, time: .shortened))"
            } ?? ""
            lines.append(("Lamp’s copy, last changed\(when), may hold edits made in Lamp. Tick it to replace Lamp’s copy with the file.", false))
        }
        if item.action == .update || item.action == .conflict, !item.changes.isEmpty {
            lines.append(("Differs in: \(item.changes.joined(separator: ", ")).", false))
        }
        lines += item.warnings.map { ($0, false) }
        return lines
    }
}
