import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import SwiftUI

/// A writing surface the find bar searches: the visual editor or the Markdown
/// text view. Results come back later, since the visual editor answers from
/// its web page.
@MainActor
protocol WritingFindTarget: AnyObject {
    /// Shows every match of `query` and makes current the first at or after
    /// the caret, scrolled into view, without moving the caret or taking focus
    /// from the find field.
    func setSearch(
        _ query: String,
        options: WritingFindOptions,
        completion: @escaping (WritingFindStatus) -> Void
    )
    func findNext(completion: @escaping (WritingFindStatus) -> Void)
    func findPrevious(completion: @escaping (WritingFindStatus) -> Void)
    /// Replaces the current match, as one change Undo takes back, and makes
    /// the next match after it current.
    func replaceCurrent(with replacement: String, completion: @escaping (WritingFindStatus) -> Void)
    /// Replaces every match as one change Undo takes back, and says how many.
    func replaceAll(with replacement: String, completion: @escaping (Int) -> Void)
    /// Takes the matches off the text. Selecting the current one leaves the
    /// found text selected with the caret back in the text, as a Mac find bar
    /// does when it closes.
    func endSearch(selectingCurrent: Bool)
    /// Told when editing changes the matches while a search is set.
    var onFindStatusChanged: ((WritingFindStatus) -> Void)? { get set }
}

/// The find bar of one writing window, and the surface it searches.
///
/// The bar keeps its query when the surface changes — from the visual editor
/// to the Markdown one, or to another document — and searches the new one.
@MainActor
@Observable
final class WritingFindController {
    var isVisible = false
    var isReplacing = false
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            search()
        }
    }
    var replacement = ""
    var options = WritingFindOptions() {
        didSet {
            guard options != oldValue else { return }
            search()
        }
    }
    /// Nil while there is nothing to search for, or nothing on screen to search.
    private(set) var status: WritingFindStatus?
    /// How many the last Replace All replaced, shown in place of the count
    /// until the bar is next used: a replacement that contains the query is
    /// found again, and its count alone would not say anything was replaced.
    private(set) var replacedCount: Int?
    /// Bumped to ask the bar to put the caret in its find field.
    private(set) var focusRequest = 0

    @ObservationIgnored private weak var target: (any WritingFindTarget)?
    /// Each request is numbered, so an answer to one the bar has moved on
    /// from is dropped.
    @ObservationIgnored private var requestNumber = 0

    var canStep: Bool { (status?.count ?? 0) > 0 }
    var canReplaceCurrent: Bool { (status?.current ?? 0) > 0 }

    func show(replacing: Bool) {
        if replacing { isReplacing = true }
        if !isVisible {
            isVisible = true
            search()
        }
        focusRequest += 1
    }

    /// Closes the bar, leaving the current match selected in the text.
    func close() {
        guard isVisible else { return }
        isVisible = false
        requestNumber += 1
        target?.endSearch(selectingCurrent: canReplaceCurrent)
        status = nil
        replacedCount = nil
    }

    func findNext() {
        guard isVisible else { return show(replacing: false) }
        guard let target, canStep else { return }
        request { target.findNext(completion: $0) }
    }

    func findPrevious() {
        guard isVisible else { return show(replacing: false) }
        guard let target, canStep else { return }
        request { target.findPrevious(completion: $0) }
    }

    func replaceCurrent() {
        guard let target, canReplaceCurrent else { return }
        let replacement = replacement
        request { target.replaceCurrent(with: replacement, completion: $0) }
    }

    func replaceAll() {
        guard let target, canStep else { return }
        requestNumber += 1
        let number = requestNumber
        target.replaceAll(with: replacement) { [weak self] count in
            guard let self, self.requestNumber == number else { return }
            self.search()
            self.replacedCount = count
        }
    }

    /// Points the bar at the surface now on screen. The search leaves the one
    /// before and is run again on this one.
    func attach(_ newTarget: (any WritingFindTarget)?) {
        guard newTarget !== target else { return }
        target?.onFindStatusChanged = nil
        target?.endSearch(selectingCurrent: false)
        target = newTarget
        newTarget?.onFindStatusChanged = { [weak self] status in
            guard let self, self.isVisible, !self.query.isEmpty else { return }
            self.status = status
        }
        search()
    }

    private func search() {
        guard isVisible, let target else {
            status = nil
            return
        }
        guard !query.isEmpty else {
            requestNumber += 1
            target.endSearch(selectingCurrent: false)
            status = nil
            replacedCount = nil
            return
        }
        let query = query
        let options = options
        request { target.setSearch(query, options: options, completion: $0) }
    }

    private func request(_ send: (@escaping (WritingFindStatus) -> Void) -> Void) {
        replacedCount = nil
        requestNumber += 1
        let number = requestNumber
        send { [weak self] status in
            guard let self, self.requestNumber == number else { return }
            self.status = status
        }
    }
}

/// The bar above a writing surface that finds, and replaces, text in it.
struct WritingFindBar: View {
    @Bindable var controller: WritingFindController
    @FocusState private var focusedField: Field?

    private enum Field {
        case find
        case replace
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Picker("Find or Replace", selection: $controller.isReplacing) {
                    Text("Find").tag(false)
                    Text("Replace").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Find, or find and replace")

                field(.find) {
                    optionsMenu
                    TextField("Find", text: $controller.query)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .find)
                        .onSubmit { controller.findNext() }
                    Text(statusText)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(isNotFound ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .fixedSize()
                }

                HStack(spacing: 8) {
                    ControlGroup {
                        Button("Previous", systemImage: "chevron.left") { controller.findPrevious() }
                            .help("Find previous (⇧⌘G)")
                        Button("Next", systemImage: "chevron.right") { controller.findNext() }
                            .help("Find next (⌘G)")
                    }
                    .fixedSize()
                    .disabled(!controller.canStep)

                    Button("Done") { controller.close() }
                }
            }

            if controller.isReplacing {
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    field(.replace) {
                        TextField("Replace", text: $controller.replacement)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .replace)
                    }
                    HStack(spacing: 8) {
                        Button("Replace") { controller.replaceCurrent() }
                            .disabled(!controller.canReplaceCurrent)
                            .help("Replace this match and find the next")
                        Button("Replace All") { controller.replaceAll() }
                            .disabled(!controller.canStep)
                            .help("Replace every match")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .onExitCommand { controller.close() }
        .onChange(of: controller.focusRequest, initial: true) {
            focusedField = .find
        }
    }

    /// A text field drawn as a search field is: the find field holds its
    /// options and its count beside the text, and the replace field matches it.
    private func field<Content: View>(_ which: Field, @ViewBuilder content: () -> Content) -> some View {
        let isFocused = focusedField == which
        return HStack(spacing: 4) { content() }
            .padding(.horizontal, 7)
            .frame(minWidth: 200, maxWidth: 520, minHeight: 24)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor),
                        lineWidth: isFocused ? 2 : 1
                    )
            }
            .contentShape(Rectangle())
            .onTapGesture { focusedField = which }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Match Case", isOn: $controller.options.matchesCase)
            Toggle("Whole Words", isOn: $controller.options.wholeWords)
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Find options")
        .accessibilityLabel("Find options")
    }

    private var isNotFound: Bool {
        controller.replacedCount == nil && controller.status == .noMatches
    }

    private var statusText: String {
        if let replacedCount = controller.replacedCount {
            return "Replaced \(replacedCount)"
        }
        return controller.status?.description ?? ""
    }
}
