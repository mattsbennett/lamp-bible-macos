import SwiftUI

private struct InstallModuleActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportStudyDataActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct NewReaderTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var installModuleAction: (() -> Void)? {
        get { self[InstallModuleActionKey.self] }
        set { self[InstallModuleActionKey.self] = newValue }
    }


    var importStudyDataAction: (() -> Void)? {
        get { self[ImportStudyDataActionKey.self] }
        set { self[ImportStudyDataActionKey.self] = newValue }
    }

    var newReaderTabAction: (() -> Void)? {
        get { self[NewReaderTabActionKey.self] }
        set { self[NewReaderTabActionKey.self] = newValue }
    }
}

struct LampBibleCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.installModuleAction) private var installModule
    @FocusedValue(\.importStudyDataAction) private var importStudyData
    @FocusedValue(\.newReaderTabAction) private var newReaderTab
    @FocusedObject private var scrollLink: ReaderScrollLink?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Install Module…") {
                installModule?()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(installModule == nil)

            Button("Import Personal Study Data…") {
                importStudyData?()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(importStudyData == nil)

            Button("New Reader Tab") {
                newReaderTab?()
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(newReaderTab == nil)

            Button("New Reader Window") {
                openWindow(id: "reader")
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("New Devotional") {
                openWindow(id: "devotional-editor", value: DevotionalEditorRequest())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Open Module Studio") {
                openWindow(id: "module-studio")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Toggle("Link Study Tool Scrolling", isOn: Binding(
                get: { scrollLink?.isLinked ?? false },
                set: { newValue in scrollLink?.isLinked = newValue }
            ))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(scrollLink == nil)
        }

        SidebarCommands()
        InspectorCommands()
    }
}
