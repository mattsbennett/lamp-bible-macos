import Foundation
#if canImport(LampBibleMacSupport)
import LampBibleMacSupport
#endif
import LampModuleKit

private enum ModuleBuildOutcome: Sendable {
    case success(ModuleCompilationResult)
    case failure(String)
}

@MainActor
final class ModuleStudioModel: ObservableObject {
    @Published private(set) var documents: [StudioDocument] = []
    @Published var selection: StudioDocument.ID?
    @Published private(set) var isWorking = false
    @Published private(set) var isBuilding = false
    @Published private(set) var compilationResults: [StudioDocument.ID: ModuleCompilationResult] = [:]
    @Published var buildErrorMessage: String?

    var selectedDocument: StudioDocument? {
        documents.first { $0.id == selection }
    }

    func compilationResult(for document: StudioDocument) -> ModuleCompilationResult? {
        compilationResults[document.id]
    }

    func inspect(_ urls: [URL]) {
        let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
        guard !jsonURLs.isEmpty else { return }

        isWorking = true
        Task {
            var loaded: [StudioDocument] = []
            for url in jsonURLs {
                let document = await Task.detached(priority: .userInitiated) {
                    StudioDocumentLoader.load(from: url)
                }.value
                loaded.append(document)
            }

            documents.append(contentsOf: loaded)
            if selection == nil {
                selection = loaded.first?.id
            }
            isWorking = false
        }
    }

    func clear() {
        documents.removeAll()
        selection = nil
        compilationResults.removeAll()
        buildErrorMessage = nil
    }

    func buildSelected(to destinationURL: URL) {
        guard let document = selectedDocument, document.canBuild, !isBuilding else { return }

        isBuilding = true
        buildErrorMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                do {
                    return ModuleBuildOutcome.success(
                        try LampModuleCompiler().compile(
                            sourceURL: document.sourceURL,
                            destinationURL: destinationURL
                        )
                    )
                } catch {
                    return ModuleBuildOutcome.failure(error.localizedDescription)
                }
            }.value

            switch outcome {
            case .success(let result):
                compilationResults[document.id] = result
            case .failure(let message):
                buildErrorMessage = message
            }
            isBuilding = false
        }
    }
}
