import SwiftUI
import UniformTypeIdentifiers

/// What a section of the library shows while it has nothing in it: three
/// cloth covers like the ones on the shelves, with the section's mark and
/// name on the middle one, then what the section is for and how to fill it.
/// Every section uses this one design, so an empty library looks like one
/// place and not a run of system placeholders.
struct LampEmptyState<Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    /// The section's mark, as the sidebar draws it.
    let systemImage: String
    /// The section's name, lettered on the middle cover.
    let caption: String
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        // Scrolls rather than clips in a short window, and stands centred in
        // a tall one: at least the pane's height, its content in the middle.
        // A default scroll anchor centred it by scrolling, which drew the
        // toolbar's scroll edge across the top third of an empty pane.
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 0) {
                illustration
                    .padding(.bottom, 34)
                Text(title)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(Color.lampSecondaryText)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
                HStack(spacing: 12) {
                    actions()
                }
                .controlSize(.large)
                .padding(.top, 26)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// A different run of cloths for each section, the same on every launch.
    private var firstShelfPosition: Int {
        caption.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF }
    }

    private var illustration: some View {
        ZStack {
            // The shadow the covers cast where they stand: dark on a light
            // window, and on a dark one a faint light, which a black shadow
            // there could not show. A pool of the accent read as a stain.
            Ellipse()
                .fill(colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.2))
                .frame(width: 250, height: 16)
                .blur(radius: 9)
                .offset(y: 80)
            sideCover(position: 1)
                .rotationEffect(.degrees(-12), anchor: .bottom)
                .offset(x: -62, y: 10)
            sideCover(position: 2)
                .rotationEffect(.degrees(12), anchor: .bottom)
                .offset(x: 62, y: 10)
            LibraryCover(
                monogram: nil,
                title: caption,
                caption: caption,
                systemImage: systemImage,
                seed: caption,
                width: 108,
                shelfPosition: firstShelfPosition
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        }
        .frame(width: 300, height: 170)
        .accessibilityHidden(true)
    }

    private func sideCover(position: Int) -> some View {
        LibraryCover(
            monogram: nil,
            title: "",
            seed: "\(caption)-\(position)",
            width: 84,
            shelfPosition: firstShelfPosition + position
        )
    }
}

/// Writing's empty state: a new writing, or writing already done elsewhere
/// brought in from Markdown. Its import is reviewed in the Import window,
/// whose sheet shows what each file becomes, so that window opens once the
/// files have been read.
struct WritingEmptyState: View {
    let newWriting: () -> Void

    @EnvironmentObject private var model: LibraryModel
    @Environment(\.openWindow) private var openWindow
    @State private var isChoosingFiles = false
    @State private var isAwaitingReview = false

    var body: some View {
        LampEmptyState(
            systemImage: "sun.max",
            caption: "Writing",
            title: "Nothing Written Yet",
            message: "Studies, talks and devotionals you write are kept here, with every passage they cite a click away."
        ) {
            Button("New Writing", systemImage: "square.and.pencil", action: newWriting)
                .buttonStyle(.lampProminent)
            Button("Import Writing…", systemImage: "square.and.arrow.down") {
                isChoosingFiles = true
            }
            .buttonStyle(.lampProminent)
            .help("Bring in writing from Markdown files or a folder of them")
        }
        .fileImporter(
            isPresented: $isChoosingFiles,
            allowedContentTypes: [.markdownFile, .folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            isAwaitingReview = true
            model.planWritingImport(urls)
        }
        .onChange(of: model.pendingWritingImport?.id) { _, id in
            guard isAwaitingReview, id != nil else { return }
            isAwaitingReview = false
            openWindow(id: "add-to-library")
        }
        .onChange(of: model.isImportingStudyData) { _, isImporting in
            // Read and found nothing to plan, or failed: the model says why.
            if !isImporting, model.pendingWritingImport == nil { isAwaitingReview = false }
        }
    }
}
