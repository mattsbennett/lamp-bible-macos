import SwiftUI

@main
struct LampBibleMacApp: App {
    @StateObject private var libraryModel = LibraryModel()

    var body: some Scene {
        WindowGroup("Lamp Bible", id: "reader") {
            LibraryRootView()
                .environmentObject(libraryModel)
        }
        .defaultSize(width: 1_240, height: 820)
        .commands {
            LampBibleCommands()
        }

        WindowGroup("Module Studio", id: "module-studio") {
            ModuleStudioView()
                .environmentObject(libraryModel)
        }
        .defaultSize(width: 1_080, height: 720)

        Settings {
            ReaderSettingsView()
        }
    }
}

private struct ReaderSettingsView: View {
    @AppStorage("reader.fontSize") private var fontSize = 20.0
    @AppStorage("reader.lineSpacing") private var lineSpacing = 7.0

    var body: some View {
        Form {
            Section("Reader") {
                LabeledContent("Text Size") {
                    HStack {
                        Slider(value: $fontSize, in: 15...32, step: 1)
                            .frame(width: 220)
                        Text(fontSize.formatted(.number.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                LabeledContent("Line Spacing") {
                    HStack {
                        Slider(value: $lineSpacing, in: 2...16, step: 1)
                            .frame(width: 220)
                        Text(lineSpacing.formatted(.number.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .frame(width: 28, alignment: .trailing)
                    }
                }
                Button("Restore Reader Defaults") {
                    fontSize = 20
                    lineSpacing = 7
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 280)
        .padding()
    }
}
