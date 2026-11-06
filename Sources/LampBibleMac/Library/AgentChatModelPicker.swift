#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// Chooses which model a chat's provider runs.
///
/// Lamp names no model of its own beyond the provider's standing aliases, so
/// the menu is those aliases, the provider's default, and whatever the reader
/// has typed. A name typed here is passed to the CLI untouched: the provider
/// knows what it has, and this app would only go out of date.
struct AgentChatModelPicker: View {
    let provider: AIProviderCLI

    // One key per provider, because a model name means nothing to another one.
    // Three stored properties rather than one dynamic key: `@AppStorage` binds
    // to a key when the view is made, and a key that changed underneath it
    // would write the new provider's choice into the old provider's slot.
    @AppStorage(AgentChatModelChoice.defaultsKey(.claude)) private var claudeModel = ""
    @AppStorage(AgentChatModelChoice.defaultsKey(.codex)) private var codexModel = ""
    @AppStorage(AgentChatModelChoice.defaultsKey(.openCode)) private var openCodeModel = ""

    @State private var isEditing = false
    @State private var typed = ""

    private var wire: AgentChatWireProvider { provider.wireProvider }

    private var model: String {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    private var storage: Binding<String> {
        switch wire {
        case .claude: $claudeModel
        case .codex: $codexModel
        case .openCode: $openCodeModel
        }
    }
    private var aliases: [String] { AgentChatModelChoice.aliases(wire) }
    private var chosen: String? { AgentChatModelChoice.canonical(model) }

    var body: some View {
        Menu {
            Button {
                model = ""
            } label: {
                Label("\(provider.shortName) default", systemImage: chosen == nil ? "checkmark" : "")
            }
            if !aliases.isEmpty {
                Divider()
                ForEach(aliases, id: \.self) { alias in
                    Button {
                        model = alias
                    } label: {
                        Label(alias, systemImage: chosen == alias ? "checkmark" : "")
                    }
                }
            }
            Divider()
            // A name the reader knows and this build does not: the only way a
            // picker can outlive the list it was written with.
            Button(chosen == nil || aliases.contains(chosen ?? "") ? "Other Model…" : "Change…") {
                typed = model
                isEditing = true
            }
        } label: {
            Text(label)
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
        .frame(maxWidth: 190)
        .help(helpText)
        .accessibilityLabel("Model")
        .accessibilityValue(chosen ?? "\(provider.shortName) default")
        .popover(isPresented: $isEditing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Model").font(.headline)
                TextField("Default", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit { commit() }
                Text(AgentChatModelChoice.hint(wire))
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

    private var label: String {
        guard let chosen else { return "Default model" }
        return chosen
    }

    private var helpText: String {
        guard let chosen else {
            return "Model: whatever \(provider.shortName) uses by default"
        }
        return "Model: \(chosen)"
    }

    private func commit() {
        model = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditing = false
    }
}
