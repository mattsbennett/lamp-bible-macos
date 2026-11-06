#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// One of the settings a chat hands to its provider's CLI: which model to run,
/// or how hard to think.
///
/// Lamp names nothing of its own here beyond what the provider itself
/// publishes. The menu offers the provider's default, the names the provider
/// stands behind, and whatever the reader has typed, which is passed on
/// untouched. A list of identifiers baked into an app goes stale the week
/// after it ships, and a reader whose provider has something newer would be
/// stuck with whatever was current when their build was made.
///
/// A choice belongs to the chat it was made in, so two windows can be reading
/// with two models at once. What the app remembers is the default a new chat
/// opens on; see `AgentChatChoices`.
struct AgentChatProviderChoice: View {
    enum Kind {
        case model
        case effort

        var title: String {
            switch self {
            case .model: "Model"
            case .effort: "Effort"
            }
        }

        /// What the button says when nothing has been picked.
        var defaultLabel: String {
            switch self {
            case .model: "Default model"
            case .effort: "Default effort"
            }
        }

        func defaultsKey(_ provider: AgentChatWireProvider) -> String {
            switch self {
            case .model: AgentChatModelChoice.defaultsKey(provider)
            case .effort: AgentChatEffortChoice.defaultsKey(provider)
            }
        }

        func offered(_ provider: AgentChatWireProvider) -> [String] {
            switch self {
            case .model: AgentChatModelChoice.aliases(provider)
            case .effort: AgentChatEffortChoice.levels(provider)
            }
        }

        func hint(_ provider: AgentChatWireProvider) -> String {
            switch self {
            case .model: AgentChatModelChoice.hint(provider)
            case .effort: AgentChatEffortChoice.hint(provider)
            }
        }
    }

    let kind: Kind
    let provider: AIProviderCLI
    /// The chat this setting belongs to, as its workspace on disk. The chat
    /// keeps its own choice beside its transcript, which is what lets one
    /// window run a model another window is not on.
    let workspace: URL?

    // One key per provider and kind, because a name means nothing to another
    // provider. Stored properties rather than one dynamic key: `@AppStorage`
    // binds to a key when the view is made, and a key that changed underneath
    // it would write the new provider's choice into the old provider's slot.
    @AppStorage(AgentChatModelChoice.defaultsKey(.claude)) private var claudeModel = ""
    @AppStorage(AgentChatModelChoice.defaultsKey(.codex)) private var codexModel = ""
    @AppStorage(AgentChatModelChoice.defaultsKey(.openCode)) private var openCodeModel = ""
    @AppStorage(AgentChatEffortChoice.defaultsKey(.claude)) private var claudeEffort = ""
    @AppStorage(AgentChatEffortChoice.defaultsKey(.codex)) private var codexEffort = ""
    @AppStorage(AgentChatEffortChoice.defaultsKey(.openCode)) private var openCodeEffort = ""

    /// This chat's own choices, held by the pane the chat is in so that the
    /// controls and the run all read one copy.
    @Binding var chatChoices: AgentChatChoices
    /// What the installed OpenCode says this model's variants are. Asked of
    /// the CLI, because they differ by model and are not Lamp's to name.
    @State private var variants: [String] = []
    @State private var isEditing = false
    @State private var typed = ""

    private var wire: AgentChatWireProvider { provider.wireProvider }

    private var appDefault: Binding<String> {
        switch (kind, wire) {
        case (.model, .claude): $claudeModel
        case (.model, .codex): $codexModel
        case (.model, .openCode): $openCodeModel
        case (.effort, .claude): $claudeEffort
        case (.effort, .codex): $codexEffort
        case (.effort, .openCode): $openCodeEffort
        }
    }

    private var modelAppDefault: Binding<String> {
        switch wire {
        case .claude: $claudeModel
        case .codex: $codexModel
        case .openCode: $openCodeModel
        }
    }

    /// For OpenCode this control is the model's variant rather than a setting
    /// of its own. That is the only place OpenCode reads effort from, and one
    /// place for it means the control can never show a level the run would not
    /// use.
    private var editsTheModelsVariant: Bool {
        kind == .effort && AgentChatEffortChoice.isCarriedByTheModel(wire)
    }

    /// The model this chat is on.
    private func model(in choices: AgentChatChoices) -> String {
        choices.value(
            for: AgentChatModelChoice.defaultsKey(wire),
            orAppDefault: modelAppDefault.wrappedValue
        ) ?? ""
    }

    private var chatModel: String { model(in: chatChoices) }

    private var value: String {
        if editsTheModelsVariant {
            return AgentChatOpenCodeVariants.chosen(in: chatModel) ?? ""
        }
        return chatChoices.value(
            for: kind.defaultsKey(wire), orAppDefault: appDefault.wrappedValue
        ) ?? ""
    }

    private var offered: [String] {
        editsTheModelsVariant ? variants : kind.offered(wire)
    }

    private var chosen: String? { AgentChatModelChoice.canonical(value) }

    /// Whether this setting can reach the provider as things stand.
    private var isAvailable: Bool {
        switch kind {
        case .model: true
        case .effort: AgentChatEffortChoice.isAvailable(provider: wire, model: chatModel)
        }
    }

    var body: some View {
        // Always drawn, even where it cannot be set yet: a control that came
        // and went as a model was named would leave the row jumping about, and
        // what it would say instead is worth saying.
        picker
            .task(id: variantRequest) { await loadVariants() }
    }

    private var picker: some View {
        Menu {
            if isAvailable {
                Button {
                    choose("")
                } label: {
                    Label("\(provider.shortName) default", systemImage: chosen == nil ? "checkmark" : "")
                }
                if !offered.isEmpty {
                    Divider()
                    ForEach(offered, id: \.self) { option in
                        Button {
                            choose(option)
                        } label: {
                            Label(option, systemImage: chosen == option ? "checkmark" : "")
                        }
                    }
                }
                Divider()
                // Something the reader knows and this build does not: the only
                // way a picker outlives the list it was written with.
                Button(chosen == nil || offered.contains(chosen ?? "") ? "Other \(kind.title)…" : "Change…") {
                    typed = value
                    isEditing = true
                }
            } else {
                Text(unavailableReason)
            }
        } label: {
            Text(chosen ?? kind.defaultLabel)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Capped rather than sized to its content: a qualified model name runs
        // to forty characters, and in the reader's sidebar that would push
        // what sits beside it off the edge. A clipped name is still readable
        // from its start, and the tooltip carries the whole of it.
        .frame(maxWidth: kind == .model ? 190 : 140)
        .help(helpText)
        .accessibilityLabel(kind.title)
        .accessibilityValue(chosen ?? "\(provider.shortName) default")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.title).font(.headline)
                TextField("Default", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { commit() }
                Text(kind.hint(wire))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 260, alignment: .leading)
                HStack {
                    Button("Use Default") {
                        typed = ""
                        commit()
                    }
                    Spacer()
                    Button("Done") { commit() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private var helpText: String {
        guard isAvailable else { return unavailableReason }
        guard let chosen else {
            return "\(kind.title): whatever \(provider.shortName) uses by default"
        }
        return "\(kind.title): \(chosen)"
    }

    /// Why this control cannot be set. OpenCode has no effort setting of its
    /// own — a variant of the model is where it reads one — so until a model
    /// is named there is nothing to name a variant of.
    private var unavailableReason: String {
        "Name a model first: \(provider.shortName) sets effort as a variant of the model."
    }

    private func commit() {
        choose(typed)
        isEditing = false
    }

    /// Which choice this control writes, and what the app remembers of it. For
    /// OpenCode's effort that is the model, because the variant it sets lives
    /// on the model's own name.
    private var writtenKey: String {
        editsTheModelsVariant ? AgentChatModelChoice.defaultsKey(wire) : kind.defaultsKey(wire)
    }

    private var writtenAppDefault: Binding<String> {
        editsTheModelsVariant ? modelAppDefault : appDefault
    }

    private func choose(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let written = editsTheModelsVariant
            ? AgentChatOpenCodeVariants.applying(variant: trimmed, to: chatModel)
            : trimmed
        var updated = chatChoices
        updated.set(written, for: writtenKey)
        if let workspace { try? AgentChatChoicesStore.save(updated, in: workspace) }
        chatChoices = updated
        // And what the app remembers, so the next new chat opens on this one's
        // choice rather than on the provider's default. Chats already open keep
        // what was pinned into them.
        writtenAppDefault.wrappedValue = written
    }

    private func loadVariants() async {
        guard editsTheModelsVariant else { return }
        variants = await OpenCodeVariantCatalogue.variants(of: chatModel, workspace: workspace)
    }

    /// Asked again whenever the answer could differ: another model has another
    /// model's variants, and another project directory another OpenCode
    /// configuration.
    private var variantRequest: String {
        "\(workspace?.path ?? "")|\(chatModel)"
    }
}

/// A chat's own choices, read from beside its transcript and pinned to what
/// the chat is running with.
///
/// Pinned when a chat is first shown and again when it changes provider: each
/// provider has a model and an effort of its own, which were never pinned
/// while another was current. Without pinning, a chat is still only following
/// what the app remembers — and the app remembers whatever was picked last in
/// any window, so a pick made in a second window would move the first with it.
@MainActor
enum AgentChatOwnChoices {
    static func pinned(in workspace: URL, appProviderID: String) -> AgentChatChoices {
        let loaded = AgentChatChoicesStore.load(in: workspace)
        let current = AIProviderCLI(
            rawValue: loaded.value(
                for: AgentChatChoices.providerKey, orAppDefault: appProviderID
            ) ?? appProviderID
        ) ?? .codex
        let wire = current.wireProvider
        let result = AgentChatChoicesPin.pinning(
            loaded,
            providerID: current.rawValue,
            provider: wire,
            model: UserDefaults.standard.string(forKey: AgentChatModelChoice.defaultsKey(wire)) ?? "",
            effort: UserDefaults.standard.string(forKey: AgentChatEffortChoice.defaultsKey(wire)) ?? ""
        )
        if result.changed { try? AgentChatChoicesStore.save(result.choices, in: workspace) }
        return result.choices
    }
}

/// What the installed OpenCode says each of its models can vary.
///
/// Asked of the CLI once per project directory for the app's run: `opencode
/// api GET /api/model` is its published list, a CLI does not change under a
/// running app, and the alternative is a process launch every time a menu is
/// drawn. A failed or empty answer is not kept, so a reader who signs OpenCode
/// in while Lamp is open is not told for the rest of the session that their
/// models have no variants.
@MainActor
enum OpenCodeVariantCatalogue {
    private static var byDirectory: [String: [String: [String]]] = [:]

    static func variants(of model: String?, workspace: URL?) async -> [String] {
        guard AgentChatModelChoice.canonical(model) != nil else { return [] }
        let directory = workspace ?? FileManager.default.homeDirectoryForCurrentUser
        if let known = byDirectory[directory.path] {
            return AgentChatOpenCodeVariants.variants(of: model, in: known)
        }
        let result = await AgentCLIProcessRunner().run(
            executableName: AIProviderCLI.openCode.executable,
            arguments: AgentChatOpenCodeVariants.probeArguments,
            workingDirectory: directory
        )
        guard result.exitCode == 0 else { return [] }
        let catalogue = AgentChatOpenCodeVariants.parse(result.output)
        guard !catalogue.isEmpty else { return [] }
        byDirectory[directory.path] = catalogue
        return AgentChatOpenCodeVariants.variants(of: model, in: catalogue)
    }
}
