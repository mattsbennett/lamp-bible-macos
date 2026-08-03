import SwiftUI

private struct InstallModuleActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct ImportStudyDataActionKey: FocusedValueKey {
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
}

struct LampBibleCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.installModuleAction) private var installModule
    @FocusedValue(\.importStudyDataAction) private var importStudyData

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

            Button("New Reader Window") {
                openWindow(id: "reader")
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Open Module Studio") {
                openWindow(id: "module-studio")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        SidebarCommands()
        InspectorCommands()
    }
}
