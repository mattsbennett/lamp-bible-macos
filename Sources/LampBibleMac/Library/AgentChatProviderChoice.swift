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

        func isSupported(_ provider: AgentChatWireProvider) -> Bool {
            switch self {
            case .model: true
            case .effort: AgentChatEffortChoice.isSupported(provider)
            }
        }
    }

    let kind: Kind
    let provider: AIProviderCLI

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

    @State private var isEditing = false
    @State private var typed = ""

    private var wire: AgentChatWireProvider { provider.wireProvider }

    private var value: String {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    private var storage: Binding<String> {
        switch (kind, wire) {
        case (.model, .claude): $claudeModel
        case (.model, .codex): $codexModel
        case (.model, .openCode): $openCodeModel
        case (.effort, .claude): $claudeEffort
        case (.effort, .codex): $codexEffort
        case (.effort, .openCode): $openCodeEffort
        }
    }

    private var offered: [String] { kind.offered(wire) }
    private var chosen: String? { AgentChatModelChoice.canonical(value) }

    var body: some View {
        // A provider without this setting is shown no control for it, rather
        // than one that would be ignored.
        if kind.isSupported(wire) {
            picker
        }
    }

    private var picker: some View {
        Menu {
            Button {
                value = ""
            } label: {
                Label("\(provider.shortName) default", systemImage: chosen == nil ? "checkmark" : "")
            }
            if !offered.isEmpty {
                Divider()
                ForEach(offered, id: \.self) { option in
                    Button {
                        value = option
                    } label: {
                        Label(option, systemImage: chosen == option ? "checkmark" : "")
                    }
                }
            }
            Divider()
            // Something the reader knows and this build does not: the only way
            // a picker outlives the list it was written with.
            Button(chosen == nil || offered.contains(chosen ?? "") ? "Other \(kind.title)…" : "Change…") {
                typed = value
                isEditing = true
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
        guard let chosen else {
            return "\(kind.title): whatever \(provider.shortName) uses by default"
        }
        return "\(kind.title): \(chosen)"
    }

    private func commit() {
        value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
    }
}
