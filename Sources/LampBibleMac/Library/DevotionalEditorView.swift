import AppKit
import LampCore
import SwiftUI
import UniformTypeIdentifiers

struct DevotionalEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: LibraryModel

    private let original: LampDevotional?
    private let onSave: (LampDevotional) -> Void

    @State private var identifier: String
    @State private var title: String
    @State private var subtitle: String
    @State private var author: String
    @State private var date: String
    @State private var tags: String
    @State private var category: String
    @State private var seriesName: String
    @State private var seriesOrder: Int
    @State private var summary: String
    @State private var content: String
    @State private var footnotes: String
    @State private var keyScriptures: [LampScriptureLink]
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showingAudioRecorder = false

    init(
        devotional: LampDevotional? = nil,
        onSave: @escaping (LampDevotional) -> Void
    ) {
        original = devotional
        self.onSave = onSave
        _identifier = State(initialValue: devotional?.id ?? UUID().uuidString)
        _title = State(initialValue: devotional?.title ?? "")
        _subtitle = State(initialValue: devotional?.subtitle ?? "")
        _author = State(initialValue: devotional?.author ?? "")
        _date = State(initialValue: devotional?.date ?? Self.today)
        _tags = State(initialValue: devotional?.tags.joined(separator: ", ") ?? "")
        _category = State(initialValue: devotional?.category ?? "devotional")
        _seriesName = State(initialValue: devotional?.seriesName ?? "")
        _seriesOrder = State(initialValue: devotional?.seriesOrder ?? 0)
        _summary = State(initialValue: devotional?.summary ?? "")
        _content = State(initialValue: devotional?.content ?? "")
        _footnotes = State(initialValue: devotional?.footnotes ?? "")
        _keyScriptures = State(initialValue: devotional?.keyScriptures ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                    TextField("Subtitle", text: $subtitle)
                    TextField("Author", text: $author)
                    TextField("Date (YYYY-MM-DD)", text: $date)
                    TextField("Tags (comma separated)", text: $tags)
                    Picker("Category", selection: $category) {
                        ForEach(Self.categories, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("Series", text: $seriesName)
                    Stepper("Series Order: \(seriesOrder)", value: $seriesOrder, in: 0...10_000)
                }

                Section("Key Scripture") {
                    if keyScriptures.isEmpty {
                        Text("No key scripture added")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(keyScriptures) { scripture in
                            HStack {
                                Text(scripture.displayDescription)
                                Spacer()
                                Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                    keyScriptures.removeAll { $0.id == scripture.id }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    if let reference = model.selectedVerseReference {
                        Button("Add Current Verse", systemImage: "book") {
                            guard !keyScriptures.contains(where: { $0.startReference == reference }) else { return }
                            keyScriptures.append(LampScriptureLink(startReference: reference))
                        }
                    }
                }

                Section("Summary") {
                    TextEditor(text: $summary)
                        .font(.body)
                        .frame(minHeight: 70)
                }

                Section {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .serif))
                        .frame(minHeight: 260)
                        .textSelection(.enabled)
                } header: {
                    HStack {
                        Text("Content (Markdown)")
                        Spacer()
                        Button("Heading", systemImage: "textformat.size") { insert("\n## Heading\n") }
                        Button("Quote", systemImage: "text.quote") { insert("\n> Quote\n") }
                        Button("List", systemImage: "list.bullet") { insert("\n- Item\n") }
                        Button("Attach…", systemImage: "paperclip") { attachMedia() }
                        Button("Record…", systemImage: "mic") { showingAudioRecorder = true }
                    }
                    .buttonStyle(.borderless)
                }

                Section("Footnotes") {
                    TextEditor(text: $footnotes)
                        .font(.body)
                        .frame(minHeight: 90)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(original == nil ? "New Devotional" : "Edit Devotional")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSaving)
                }
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.08)
                        ProgressView("Saving…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .alert("Devotional", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "The devotional could not be saved.")
            }
        }
        .frame(minWidth: 720, minHeight: 720)
        .sheet(isPresented: $showingAudioRecorder) {
            DevotionalAudioRecorderView(devotionalID: identifier) { storedURL in
                let label = storedURL.deletingPathExtension().lastPathComponent
                insert("[▶︎ \(label)](lamp-media://\(identifier)/\(storedURL.lastPathComponent))")
            }
            .environmentObject(model)
        }
    }

    private func save() {
        let devotional = LampDevotional(
            id: identifier,
            moduleID: "personal-devotionals",
            moduleName: "My Devotionals",
            title: title,
            subtitle: subtitle,
            author: author,
            date: date,
            tags: tags.split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty },
            category: category,
            seriesName: seriesName,
            seriesOrder: seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : seriesOrder,
            keyScriptures: keyScriptures,
            summary: summary,
            content: content,
            footnotes: footnotes,
            created: original?.created ?? Date(),
            lastModified: Date(),
            isEditable: true
        )
        isSaving = true
        Task {
            do {
                let saved = try await model.savePersonalDevotional(devotional)
                onSave(saved)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func insert(_ markdown: String) {
        if !content.isEmpty, !content.hasSuffix("\n") { content += "\n" }
        content += markdown.trimmingCharacters(in: .newlines) + "\n"
    }

    private func attachMedia() {
        let panel = NSOpenPanel()
        panel.title = "Attach Image or Audio"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .audio]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        Task {
            do {
                let storedURL = try await model.library.storePersonalDevotionalMedia(
                    from: sourceURL,
                    devotionalID: identifier
                )
                let isImage = UTType(filenameExtension: storedURL.pathExtension)?.conforms(to: .image) == true
                let label = storedURL.deletingPathExtension().lastPathComponent
                let portableURL = "lamp-media://\(identifier)/\(storedURL.lastPathComponent)"
                insert(isImage
                    ? "![\(label)](\(portableURL))"
                    : "[▶︎ \(label)](\(portableURL))")
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static var today: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: Date())
    }

    private static let categories = [
        "devotional", "sermon", "reflection", "study", "prayer", "testimony", "other",
    ]
}
