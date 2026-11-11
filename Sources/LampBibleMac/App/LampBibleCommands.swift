#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

private struct InstallModuleActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct WritingFindKey: FocusedValueKey {
    typealias Value = WritingFindController
}

private struct ImportStudyDataActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct NewReaderTabActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// Opens the reader's passage field, which takes a reference, a Strong's key
/// or words to search for. A menu item because the toolbar button cannot say
/// all that, and the menu is where someone looks for it.
struct GoToPassageActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// ⌘K: the palette that goes anywhere in Lamp, in the window in front.
struct CommandPaletteActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension Notification.Name {
    /// ⌘K when no scene has published `commandPaletteAction`: the library
    /// window it names (`object`) answers it.
    static let lampToggleCommandPalette = Notification.Name("lampToggleCommandPalette")
}

extension FocusedValues {
    var commandPaletteAction: (() -> Void)? {
        get { self[CommandPaletteActionKey.self] }
        set { self[CommandPaletteActionKey.self] = newValue }
    }

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

    var goToPassageAction: (() -> Void)? {
        get { self[GoToPassageActionKey.self] }
        set { self[GoToPassageActionKey.self] = newValue }
    }

    var writingFind: WritingFindController? {
        get { self[WritingFindKey.self] }
        set { self[WritingFindKey.self] = newValue }
    }
}

struct LampBibleCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.installModuleAction) private var installModule
    @FocusedValue(\.commandPaletteAction) private var commandPalette
    @FocusedValue(\.importStudyDataAction) private var importStudyData
    @FocusedValue(\.newReaderTabAction) private var newReaderTab
    @FocusedValue(\.goToPassageAction) private var goToPassage
    @FocusedValue(\.writingFind) private var writingFind
    @FocusedObject private var scrollLink: ReaderScrollLink?

    let softwareUpdater: SoftwareUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updater: softwareUpdater)
        }

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

            Button("New Writing") {
                openWindow(id: "devotional-editor", value: DevotionalEditorRequest())
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Presentation Deck") {
                openWindow(
                    id: "slide-studio",
                    value: SlideStudioRequest(newDeckID: UUID().uuidString)
                )
            }
            .keyboardShortcut("n", modifiers: [.command, .option, .shift])

            Button("Import or Create Content…") {
                openWindow(id: "add-to-library")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        // Only a writing window has a find bar, so elsewhere these stay off.
        CommandGroup(after: .textEditing) {
            Menu("Find") {
                Button("Find…") { writingFind?.show(replacing: false) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Find and Replace…") { writingFind?.show(replacing: true) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Find Next") { writingFind?.findNext() }
                    .keyboardShortcut("g", modifiers: .command)
                Button("Find Previous") { writingFind?.findPrevious() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
            .disabled(writingFind == nil)
        }

        CommandGroup(after: .sidebar) {
            // Never disabled: the focused value can be missing while the
            // window has nothing focused in it, which left ⌘K dead exactly
            // when it is wanted. Then a library window is named and asked,
            // and raised, since the palette lives in it: from Settings, ⌘K
            // brings the library forward with the palette open. With no
            // library window at all, it opens one, and the palette with it.
            Button("Go to Anything…") {
                if let commandPalette {
                    commandPalette()
                } else if let window = CommandPaletteWindows.target() {
                    window.makeKeyAndOrderFront(nil)
                    NotificationCenter.default.post(name: .lampToggleCommandPalette, object: window)
                } else {
                    CommandPaletteWindows.opensPaletteInNextWindow = true
                    openWindow(id: "reader")
                }
            }
                .keyboardShortcut("k", modifiers: .command)
            Button("Go to Passage or Search…") { goToPassage?() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(goToPassage == nil)
            Divider()

            Toggle("Link Study Tool Scrolling", isOn: Binding(
                get: { scrollLink?.isLinked ?? false },
                set: { newValue in scrollLink?.isLinked = newValue }
            ))
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(scrollLink == nil)
        }

        CommandGroup(after: .help) {
            Button("Third-Party Notices") {
                if let readme = Bundle.main.url(
                    forResource: "README",
                    withExtension: "txt",
                    subdirectory: "Third Party Licenses"
                ) {
                    NSWorkspace.shared.open(readme)
                }
            }
        }

        SidebarCommands()
        InspectorCommands()
    }
}
