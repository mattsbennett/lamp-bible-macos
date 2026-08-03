import Foundation
import LampModuleKit

public struct StudioDocument: Identifiable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let inspection: ModuleInspection?
    public let failureMessage: String?

    public var displayName: String {
        sourceURL.deletingPathExtension().lastPathComponent
    }

    public var isValid: Bool {
        inspection?.canCompile == true
    }

    public var canBuild: Bool {
        guard isValid, let kind = inspection?.kind else { return false }
        return LampModuleCompiler.supportedKinds.contains(kind)
    }

    public var suggestedOutputFilename: String {
        let moduleID = inspection?.metadata.id ?? displayName
        return "\(moduleID).lamp"
    }

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        inspection: ModuleInspection?,
        failureMessage: String?
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.inspection = inspection
        self.failureMessage = failureMessage
    }
}

public enum StudioDocumentLoader {
    public static func load(from url: URL) -> StudioDocument {
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            return inspect(data: data, sourceURL: url)
        } catch {
            return StudioDocument(
                sourceURL: url,
                inspection: nil,
                failureMessage: error.localizedDescription
            )
        }
    }

    public static func inspect(data: Data, sourceURL: URL) -> StudioDocument {
        do {
            let inspection = try ModuleJSONInspector().inspect(data)
            return StudioDocument(sourceURL: sourceURL, inspection: inspection, failureMessage: nil)
        } catch {
            return StudioDocument(
                sourceURL: sourceURL,
                inspection: nil,
                failureMessage: error.localizedDescription
            )
        }
    }
}
