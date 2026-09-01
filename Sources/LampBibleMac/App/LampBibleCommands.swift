#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

private struct InstallModuleActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct WritingPreviewPlacementKey: FocusedValueKey {
    typealias Value = Binding<WritingPreviewPlacement>
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

    var writingPreviewPlacement: Binding<WritingPreviewPlacement>? {
        get { self[WritingPreviewPlacementKey.self] }
        set { self[WritingPreviewPlacementKey.self] = newValue }
    }
}

struct LampBibleCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.installModuleAction) private var installModule
    @FocusedValue(\.importStudyDataAction) private var importStudyData
    @FocusedValue(\.newReaderTabAction) private var newReaderTab
    @FocusedValue(\.writingPreviewPlacement) private var writingPreviewPlacement
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

            Button("New Book Reader Window") {
                openWindow(id: "book-reader", value: BookReaderRequest())
            }

            Button("New Devotional") {
                openWindow(id: "devotional-editor", value: DevotionalEditorRequest())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Presentation Deck") {
                openWindow(id: "slide-studio", value: SlideStudioRequest())
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])

            Button("Import or Create Content…") {
                openWindow(id: "add-to-library")
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

            // ⌘E is the binding Obsidian uses to swap between writing and reading,
            // and listing both here is what makes them findable at all.
            Button(writingPreviewPlacement?.wrappedValue.isVisible == true
                ? "Hide Writing Preview"
                : "Show Writing Preview") {
                guard let writingPreviewPlacement else { return }
                writingPreviewPlacement.wrappedValue = writingPreviewPlacement.wrappedValue.toggled()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(writingPreviewPlacement == nil)

            Button(writingPreviewPlacement?.wrappedValue == .full
                ? "Show Preview Beside Editor"
                : "Show Full-Width Preview") {
                guard let writingPreviewPlacement else { return }
                writingPreviewPlacement.wrappedValue = writingPreviewPlacement
                    .wrappedValue
                    .cycledPlacement()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(writingPreviewPlacement == nil)
        }

        SidebarCommands()
        InspectorCommands()
    }
}
