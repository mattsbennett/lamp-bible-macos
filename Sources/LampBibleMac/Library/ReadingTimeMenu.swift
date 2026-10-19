#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// How long the writing takes, at the pace it will actually be met at.
///
/// One figure at one pace answers "how long is this to read" and not "how long
/// will this take me to deliver" — which is the question someone writing a talk
/// is asking, and the pace that matters is half as long again. The estimate is
/// the control: clicking it chooses between the two, and each keeps its own
/// words-a-minute rate in Settings.
struct ReadingTimeMenu: View {
    let statistics: WritingStatistics
    /// Shown with the clock or microphone beside it, as in a detail list.
    var showsIcon = false

    @AppStorage(LampReadingMode.defaultsKey) private var storedMode = LampReadingMode.silent.rawValue
    @AppStorage(LampReadingMode.silent.wordsPerMinuteKey)
    private var silentWordsPerMinute = LampReadingMode.silent.defaultWordsPerMinute
    @AppStorage(LampReadingMode.aloud.wordsPerMinuteKey)
    private var aloudWordsPerMinute = LampReadingMode.aloud.defaultWordsPerMinute

    private var mode: LampReadingMode { LampReadingMode(storedValue: storedMode) }

    private func rate(for mode: LampReadingMode) -> Int {
        switch mode {
        case .silent: silentWordsPerMinute
        case .aloud: aloudWordsPerMinute
        }
    }

    private func description(for mode: LampReadingMode) -> String {
        statistics.readingTimeDescription(mode: mode, wordsPerMinute: rate(for: mode))
    }

    var body: some View {
        Menu {
            Picker("Reading pace", selection: $storedMode) {
                ForEach(LampReadingMode.allCases) { option in
                    // Each choice shows what it would say, so the two can be
                    // compared without picking one to find out.
                    Label(
                        "\(option.title) — \(description(for: option))",
                        systemImage: option.systemImage
                    )
                    .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text("\(rate(for: mode)) words a minute. Change this in Settings › Writing.")
        } label: {
            if showsIcon {
                Label(description(for: mode), systemImage: mode.systemImage)
                    .monospacedDigit()
            } else {
                Text(description(for: mode))
                    .monospacedDigit()
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mode.explanation)
    }
}
