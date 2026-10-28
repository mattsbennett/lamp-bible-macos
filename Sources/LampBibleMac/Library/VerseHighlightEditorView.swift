import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampCore
import SwiftUI

struct VerseHighlightEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel

    let verse: LampVerse

    @State private var selection: NSRange
    @State private var color = StudyHighlightPalette.colors[0].hex
    @State private var style = LampHighlightStyle.highlight
    @State private var sets: [LampHighlightSet] = []
    @State private var selectedSetID = ""
    @State private var themes: [LampHighlightTheme] = []
    @State private var showingNewSet = false
    @State private var showingDeleteSet = false
    @State private var showingSaveTheme = false
    @State private var newSetName = ""
    @State private var newSetDescription = ""
    @State private var themeName = ""
    @State private var themeDescription = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    init(verse: LampVerse) {
        self.verse = verse
        _selection = State(initialValue: NSRange(location: 0, length: verse.text.utf16.count))
    }

    private var defaultSetID: String {
        "personal-highlights:\(model.selectedTranslationID ?? "translation")"
    }

    /// What is already highlighted here, and the way to remove one of them.
    ///
    /// Without this the editor could only add. A highlight over the wrong
    /// words could be covered by another or cleared along with every other
    /// highlight on the verse, but not taken off by itself.
    @ViewBuilder
    private var existingHighlights: some View {
        let highlights = model.personalHighlights(for: verse.id)
        if !highlights.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Already Highlighted")
                    .font(.headline)
                ForEach(highlights) { highlight in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(nsColor: readerColor(highlight.color) ?? .systemYellow))
                            .frame(width: 13, height: 13)
                        Text(words(of: highlight))
                            .lineLimit(1)
                        Text(setName(highlight.setID))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove", systemImage: "trash", role: .destructive) {
                            remove(highlight)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Remove this highlight")
                    }
                }
            }
        }
    }

    /// The words a highlight covers, for telling two of them apart.
    private func words(of highlight: LampVerseHighlight) -> String {
        let indices = Array(verse.text.indices) + [verse.text.endIndex]
        guard highlight.startOffset >= 0,
              highlight.endOffset > highlight.startOffset,
              highlight.endOffset < indices.count
        else { return verse.text }
        return String(verse.text[indices[highlight.startOffset]..<indices[highlight.endOffset]])
    }

    private func setName(_ setID: String) -> String {
        setID == defaultSetID ? "My Highlights" : (sets.first { $0.id == setID }?.name ?? "")
    }

    private func readerColor(_ hex: String?) -> NSColor? {
        guard let hex else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)
            .scanHexInt64(&value), hex.count >= 6 else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private func remove(_ highlight: LampVerseHighlight) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await model.deleteVerseHighlight(id: highlight.id, reference: verse.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSelectedSet() {
        let id = selectedSetID
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await model.deleteHighlightSet(id: id)
                selectedSetID = defaultSetID
                await loadSets()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var selectedCharacterRange: ReaderTextRange? {
        ReaderTextRangeMapper.characterRange(in: verse.text, utf16Range: selection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Highlight \(LampBibleReferenceFormatter.describeRange(from: verse.id, to: verse.id))")
                    .font(.title2.bold())
                Text("Select the exact words to highlight, then choose a set, color, and style.")
                    .foregroundStyle(.secondary)
            }

            SelectableVerseText(text: verse.text, selection: $selection)
                .frame(minHeight: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator)
                }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 14) {
                GridRow {
                    Text("Highlight Set")
                    HStack {
                        Picker("Highlight Set", selection: $selectedSetID) {
                            Text("My Highlights").tag(defaultSetID)
                            ForEach(sets.filter { $0.id != defaultSetID }) { set in
                                Text(set.name).tag(set.id)
                            }
                        }
                        .labelsHidden()
                        Button("New Set…", systemImage: "plus") { showingNewSet = true }
                        Button("Delete Set…", systemImage: "trash", role: .destructive) {
                            showingDeleteSet = true
                        }
                        // The default set is where an ordinary highlight goes,
                        // so deleting it would only mean the next highlight
                        // made it again, empty.
                        .disabled(selectedSetID == defaultSetID)
                    }
                }
                if !themes.isEmpty {
                    GridRow {
                        Text("Theme")
                        Menu("Apply a Theme") {
                            ForEach(themes) { theme in
                                Button(theme.name) {
                                    color = theme.color
                                    style = theme.style
                                }
                            }
                        }
                    }
                }
                GridRow {
                    Text("Style")
                    Picker("Style", selection: $style) {
                        ForEach(LampHighlightStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Color")
                    HStack(spacing: 12) {
                        ForEach(StudyHighlightPalette.colors) { item in
                            Button {
                                color = item.hex
                            } label: {
                                Circle()
                                    .fill(item.color.opacity(0.82))
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        if color == item.hex {
                                            Circle().stroke(.primary, lineWidth: 2).padding(2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(item.name)
                        }
                        Button("Save Theme…", systemImage: "bookmark") {
                            showingSaveTheme = true
                        }
                    }
                }
            }

            if selectedCharacterRange == nil {
                Label("Select one or more characters in the verse.", systemImage: "selection.pin.in.out")
                    .foregroundStyle(.orange)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            existingHighlights

            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isWorking ? "Saving…" : "Save Highlight") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCharacterRange == nil || isWorking)
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 500)
        .task { await loadSets() }
        .onChange(of: selectedSetID) { _, _ in Task { await loadThemes() } }
        .confirmationDialog(
            "Delete this highlight set?",
            isPresented: $showingDeleteSet,
            titleVisibility: .visible
        ) {
            Button("Delete Set", role: .destructive) { deleteSelectedSet() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every highlight in \(setName(selectedSetID)) goes with it, in this translation and any other. Highlights in your other sets are not affected.")
        }
        .sheet(isPresented: $showingNewSet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Highlight Set").font(.title2.bold())
                TextField("Name", text: $newSetName)
                TextField("Description (optional)", text: $newSetDescription)
                HStack {
                    Spacer()
                    Button("Cancel") { showingNewSet = false }
                    Button("Create") { createSet() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newSetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .sheet(isPresented: $showingSaveTheme) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save Highlight Theme").font(.title2.bold())
                TextField("Theme Name", text: $themeName)
                TextField("Description (optional)", text: $themeDescription)
                HStack {
                    Circle().fill((Color(lampHex: color) ?? .yellow).opacity(0.8))
                        .frame(width: 24, height: 24)
                    Text(style.displayName)
                    Spacer()
                    Button("Cancel") { showingSaveTheme = false }
                    Button("Save") { saveTheme() }
                        .buttonStyle(.borderedProminent)
                        .disabled(themeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 460)
        }
    }

    private func loadSets() async {
        guard let translationID = model.selectedTranslationID else { return }
        do {
            sets = try await model.library.highlightSets(translationID: translationID)
            if selectedSetID.isEmpty { selectedSetID = defaultSetID }
            await loadThemes()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadThemes() async {
        guard !selectedSetID.isEmpty else { return }
        themes = (try? await model.library.highlightThemes(setID: selectedSetID)) ?? []
    }

    private func saveTheme() {
        guard !selectedSetID.isEmpty else { return }
        isWorking = true
        Task {
            do {
                _ = try await model.library.saveHighlightTheme(LampHighlightTheme(
                    setID: selectedSetID,
                    color: color,
                    style: style,
                    name: themeName,
                    description: themeDescription
                ))
                await loadThemes()
                themeName = ""
                themeDescription = ""
                showingSaveTheme = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func createSet() {
        guard let translationID = model.selectedTranslationID else { return }
        isWorking = true
        Task {
            do {
                let saved = try await model.library.saveHighlightSet(LampHighlightSet(
                    name: newSetName,
                    description: newSetDescription,
                    translationID: translationID
                ))
                sets.append(saved)
                sets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                selectedSetID = saved.id
                newSetName = ""
                newSetDescription = ""
                showingNewSet = false
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func save() {
        guard let range = selectedCharacterRange else { return }
        isWorking = true
        Task {
            do {
                try await model.saveVerseHighlight(
                    reference: verse.id,
                    startOffset: range.startOffset,
                    endOffset: range.endOffset,
                    style: style,
                    color: color,
                    setID: selectedSetID.isEmpty ? defaultSetID : selectedSetID
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

private struct SelectableVerseText: NSViewRepresentable {
    let text: String
    @Binding var selection: NSRange

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.font = .systemFont(ofSize: 20)
        textView.string = text
        textView.setSelectedRange(selection)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        if textView.selectedRange() != selection { textView.setSelectedRange(selection) }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var selection: NSRange

        init(selection: Binding<NSRange>) {
            _selection = selection
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            selection = textView.selectedRange()
        }
    }
}

private extension LampHighlightStyle {
    var displayName: String {
        switch self {
        case .highlight: "Highlight"
        case .underlineSolid: "Underline"
        case .underlineDashed: "Dashed"
        case .underlineDotted: "Dotted"
        }
    }
}
