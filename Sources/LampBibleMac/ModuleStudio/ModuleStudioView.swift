import AppKit
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit
import SwiftUI
import UniformTypeIdentifiers

struct ModuleStudioView: View {
    @EnvironmentObject private var libraryModel: LibraryModel
    @StateObject private var model = ModuleStudioModel()
    @State private var showingImporter = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            Group {
                if model.documents.isEmpty {
                    dropPrompt
                        .padding(20)
                } else {
                    List(model.documents, selection: $model.selection) { document in
                        ModuleDocumentRow(document: document)
                            .tag(document.id)
                    }
                }
            }
            .navigationTitle("Sources")
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            if let document = model.selectedDocument {
                ModuleInspectionView(
                    document: document,
                    isBuilding: model.isBuilding,
                    compilationResult: model.compilationResult(for: document),
                    buildAction: { chooseBuildDestination(for: document) },
                    installAction: { libraryModel.install([$0]) }
                )
            } else {
                ContentUnavailableView(
                    "Drop Module JSON",
                    systemImage: "doc.badge.plus",
                    description: Text("Validate a Lamp module before building its .lamp package.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .dropDestination(for: URL.self) { urls, _ in
            model.inspect(urls)
            return urls.contains { $0.pathExtension.lowercased() == "json" }
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Add JSON Files", systemImage: "plus") {
                    showingImporter = true
                }
                if !model.documents.isEmpty {
                    Button("Clear", systemImage: "trash", role: .destructive) {
                        model.clear()
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                model.inspect(urls)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isWorking || model.isBuilding {
                ProgressView(model.isBuilding ? "Building…" : "Inspecting…")
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
        .alert(
            "Build Failed",
            isPresented: Binding(
                get: { model.buildErrorMessage != nil },
                set: { if !$0 { model.buildErrorMessage = nil } }
            )
        ) {
            Button("OK") { model.buildErrorMessage = nil }
        } message: {
            Text(model.buildErrorMessage ?? "The module could not be built.")
        }
    }

    private func chooseBuildDestination(for document: StudioDocument) {
        let panel = NSSavePanel()
        panel.title = "Build Lamp Module"
        panel.prompt = "Build"
        panel.nameFieldStringValue = document.suggestedOutputFilename
        panel.allowedContentTypes = [
            UTType(exportedAs: "com.neus.lamp-bible.lamp", conformingTo: .data),
        ]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        model.buildSelected(to: destinationURL)
    }

    private var dropPrompt: some View {
        Button {
            showingImporter = true
        } label: {
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 36))
                Text("Drop module JSON here")
                    .font(.headline)
                Text("or choose files")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ModuleDocumentRow: View {
    let document: StudioDocument

    var body: some View {
        HStack {
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading) {
                Text(document.displayName)
                Text(document.inspection?.kind?.rawValue.capitalized ?? "Unknown module")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusImage: String {
        if document.failureMessage != nil { return "xmark.circle.fill" }
        return document.isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if document.failureMessage != nil { return .red }
        return document.isValid ? .green : .orange
    }
}

private struct ModuleInspectionView: View {
    let document: StudioDocument
    let isBuilding: Bool
    let compilationResult: ModuleCompilationResult?
    let buildAction: () -> Void
    let installAction: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let failure = document.failureMessage {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                } else if let inspection = document.inspection {
                    statistics(inspection)
                    issues(inspection)
                    if let compilationResult {
                        buildResult(compilationResult)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(32)
        }
        .navigationTitle(document.displayName)
        .toolbar {
            Button("Build .lamp", systemImage: "shippingbox", action: buildAction)
                .disabled(!document.canBuild || isBuilding)
                .help(buildHelp)
        }
    }

    private var buildHelp: String {
        if document.canBuild { return "Compile this JSON source into an installable .lamp module." }
        if document.isValid { return "This module type is valid, but its compiler is not available yet." }
        return "Resolve validation errors before building."
    }

    private func buildResult(_ result: ModuleCompilationResult) -> some View {
        GroupBox("Built Module") {
            VStack(alignment: .leading, spacing: 10) {
                Label(result.outputURL.lastPathComponent, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(result.compressedByteCount),
                        countStyle: .file
                    )
                )
                .foregroundStyle(.secondary)
                Text(result.sha256)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                Button("Install in Library", systemImage: "square.and.arrow.down") {
                    installAction(result.outputURL)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(document.inspection?.metadata.name ?? document.displayName)
                .font(.largeTitle.bold())
            HStack {
                if let kind = document.inspection?.kind {
                    Text(kind.rawValue.capitalized)
                }
                if let version = document.inspection?.metadata.schemaVersion {
                    Text("Schema \(version)")
                }
                if let id = document.inspection?.metadata.id {
                    Text(id)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func statistics(_ inspection: ModuleInspection) -> some View {
        GroupBox("Contents") {
            HStack(spacing: 28) {
                ForEach(inspection.statistics.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    VStack(alignment: .leading) {
                        Text(value.formatted())
                            .font(.title2.bold())
                        Text(key.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func issues(_ inspection: ModuleInspection) -> some View {
        if inspection.issues.isEmpty {
            ContentUnavailableView(
                "Validation Passed",
                systemImage: "checkmark.seal.fill",
                description: Text("This source is ready for .lamp compilation.")
            )
            .foregroundStyle(.green)
        } else {
            GroupBox("Validation") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(inspection.issues) { issue in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: issue.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(issue.severity == .error ? .red : .orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.message)
                                Text(issue.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        if issue.id != inspection.issues.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
