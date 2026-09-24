import Foundation
import LampCore
import LampBibleMacSupport
import LampModuleKit
import SQLite3
import Testing

@Suite struct SyncSupportTests {
    @Test func archivesAndExtractsNestedPortableBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-sync-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let nested = source.appendingPathComponent("Study/Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let data = Data("{\"note\":true}".utf8)
        try data.write(to: nested.appendingPathComponent("notes.json"))

        let archive = try LampSyncArchive.create(from: source)
        #expect(archive.formatVersion == LampSyncArchive.currentFormatVersion)
        #expect(archive.entries.map(\.path) == ["Study/Notes/notes.json"])
        let decoded = try LampSyncArchive.decode(compressedData: archive.compressedData())
        #expect(decoded.entries.first?.data == data)

        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        try decoded.extract(to: destination)
        #expect(try Data(contentsOf: destination.appendingPathComponent("Study/Notes/notes.json")) == data)
    }

    @Test func buildsAuthenticatedWebDAVRequests() throws {
        let client = LampWebDAVClient(
            baseURL: try #require(URL(string: "https://dav.example.com/Lamp Bible/")),
            credentials: LampWebDAVCredentials(username: "reader", password: "secret")
        )
        let request = try client.makeRequest(method: "PUT", filename: "library.lampsync")

        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "https://dav.example.com/Lamp%20Bible/library.lampsync")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic cmVhZGVyOnNlY3JldA==")
        #expect(throws: LampSyncError.self) {
            _ = try client.makeRequest(method: "GET", filename: "../secrets")
        }
    }

    @Test func rewritesPersonalArchiveModuleIDForIOS() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-ios-archive-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let sourceURL = root.appendingPathComponent("source.sqlite")
        var sourceDatabase: OpaquePointer?
        #expect(sqlite3_open(sourceURL.path, &sourceDatabase) == SQLITE_OK)
        let setup = """
            CREATE TABLE module_format (module_id TEXT NOT NULL);
            CREATE TABLE module_meta (id TEXT NOT NULL);
            CREATE TABLE note_entries (id TEXT NOT NULL, module_id TEXT NOT NULL);
            CREATE TABLE highlight_meta (id TEXT NOT NULL);
            INSERT INTO module_format VALUES ('personal-notes');
            INSERT INTO module_meta VALUES ('personal-notes');
            INSERT INTO note_entries VALUES ('note-1', 'personal-notes');
            INSERT INTO highlight_meta VALUES ('set-1');
            """
        #expect(sqlite3_exec(sourceDatabase, setup, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(sourceDatabase)

        let sourceData = try Data(contentsOf: sourceURL)
        let compressed = try #require(
            try? (sourceData as NSData).compressed(using: .zlib) as Data
        )
        #expect(try LampWebDAVPersonalArchiveAdapter.highlightSetID(in: compressed) == "set-1")
        let adapted = try LampWebDAVPersonalArchiveAdapter.archive(
            compressed,
            replacingModuleIDWith: "notes",
            kind: .notes
        )
        let databaseData = try #require(
            try? (adapted as NSData).decompressed(using: .zlib) as Data
        )
        let adaptedURL = root.appendingPathComponent("adapted.sqlite")
        try databaseData.write(to: adaptedURL)
        var adaptedDatabase: OpaquePointer?
        #expect(sqlite3_open_v2(adaptedURL.path, &adaptedDatabase, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(adaptedDatabase) }

        func value(_ sql: String) -> String? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(adaptedDatabase, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }

        #expect(value("SELECT module_id FROM module_format") == "notes")
        #expect(value("SELECT id FROM module_meta") == "notes")
        #expect(value("SELECT module_id FROM note_entries") == "notes")
    }

    @Test func expandsIOSDevotionalModuleJSONIntoPersonalDocuments() throws {
        let source: [String: Any] = [
            "id": "devotionals",
            "name": "My Writing",
            "type": "devotional",
            "entries": [
                [
                    "meta": ["id": "morning", "title": "Morning", "type": "devotional"],
                    "content": [["type": "paragraph", "content": ["text": "First entry"]]],
                    "markdownContent": "Preferred Markdown",
                ],
                [
                    "id": "evening",
                    "title": "Evening",
                    "content": "Second entry",
                ],
                [
                    "meta": ["id": "outline", "title": "Title-only Outline"],
                    "content": [],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: source)
        let documents = try LampWebDAVModuleJSONAdapter.documents(
            from: data,
            kind: .devotional,
            fallbackModuleID: "devotionals"
        )

        #expect(documents.map(\.moduleID) == ["morning", "evening", "outline"])
        let chosen = LampSyncModuleFiles.preferredPathsByIdentity(
            documents.map { .init(identity: $0.syncIdentity, path: "Devotionals/devotionals.json") }
                + [.init(identity: "morning", path: "Devotionals/morning.lamp")]
        )
        #expect(chosen["morning"] == "Devotionals/morning.lamp")
        #expect(chosen["evening"] == "Devotionals/devotionals.json")
        #expect(chosen["outline"] == "Devotionals/devotionals.json")
        let afterArchive = LampSyncModuleFiles.preferredPathsByIdentity(
            documents.map { .init(identity: $0.syncIdentity, path: "Devotionals/devotionals.json") }
                + [.init(
                    identity: "morning", path: "Devotionals/morning.lamp",
                    isSuperseded: true
                )]
        )
        #expect(afterArchive["morning"] == "Devotionals/devotionals.json")
        for document in documents {
            let root = try #require(
                JSONSerialization.jsonObject(with: document.data) as? [String: Any]
            )
            let meta = try #require(root["meta"] as? [String: Any])
            #expect(meta["id"] as? String == document.moduleID)
            #expect(meta["type"] as? String == "devotional")
            #expect(meta["schemaVersion"] as? String == "1.0")
            #expect(root["content"] != nil)
            if document.moduleID == "morning" {
                #expect(root["content"] as? String == "Preferred Markdown")
            }
            if document.moduleID != "outline" {
                #expect(try ModuleJSONInspector().inspect(document.data).canCompile)
            }
        }
    }

    @Test func convertsIOSNotesAndHighlightsJSONToCanonicalDocuments() throws {
        let notes: [String: Any] = [
            "id": "notes",
            "name": "My Notes",
            "type": "notes",
            "entries": [
                ["verseId": 1_001_001, "title": "Genesis", "content": "A note"],
                ["verseId": 43_003_016, "content": "Another note"],
            ],
        ]
        let noteDocuments = try LampWebDAVModuleJSONAdapter.documents(
            from: JSONSerialization.data(withJSONObject: notes),
            kind: .notes,
            fallbackModuleID: "notes"
        )
        #expect(noteDocuments.map(\.moduleID) == ["notes-1", "notes-43"])
        #expect(noteDocuments.map(\.syncIdentity) == ["notes", "notes"])
        let chosenNotes = LampSyncModuleFiles.preferredPathsByIdentity(
            noteDocuments.map {
                .init(identity: $0.syncIdentity, path: "Notes/notes.json")
            } + [.init(identity: "notes", path: "Notes/notes.lamp")]
        )
        #expect(chosenNotes["notes"] == "Notes/notes.lamp")
        let firstNote = try #require(
            JSONSerialization.jsonObject(with: noteDocuments[0].data) as? [String: Any]
        )
        #expect(firstNote["book"] as? String == "Gen")
        #expect(firstNote["bookNumber"] as? Int == 1)
        #expect((firstNote["chapters"] as? [Any])?.count == 1)
        #expect(try ModuleJSONInspector().inspect(noteDocuments[0].data).canCompile)

        let highlights: [String: Any] = [
            "id": "yellow",
            "name": "Yellow",
            "type": "highlights",
            "translationId": "KJV",
            "highlights": [
                ["ref": 43_003_016, "sc": 0, "ec": 5, "style": 0, "color": "FFFF00"],
                ["ref": 43_003_016, "sc": 8, "ec": 12, "style": 1],
            ],
        ]
        let highlightDocument = try #require(
            LampWebDAVModuleJSONAdapter.documents(
                from: JSONSerialization.data(withJSONObject: highlights),
                kind: .highlights,
                fallbackModuleID: "yellow"
            ).first
        )
        let highlightRoot = try #require(
            JSONSerialization.jsonObject(with: highlightDocument.data) as? [String: Any]
        )
        let highlightMeta = try #require(highlightRoot["meta"] as? [String: Any])
        #expect(highlightMeta["translationId"] as? String == "KJV")
        #expect((highlightRoot["verses"] as? [Any])?.count == 1)
        #expect(try ModuleJSONInspector().inspect(highlightDocument.data).canCompile)
    }

    @Test func exportsAndImportsPortableWorkspaceContent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-workspace-sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceLibrary = root.appendingPathComponent("Source Library", isDirectory: true)
        let workspace = sourceLibrary
            .appendingPathComponent("AgentWorkspaces/Devotionals/talk-123", isDirectory: true)
        let context = workspace.appendingPathComponent("context/Research", isDirectory: true)
        let customSkill = workspace.appendingPathComponent(
            ".agents/skills/series-planner/references",
            isDirectory: true
        )
        let bundledSkill = workspace.appendingPathComponent(
            ".agents/skills/build-lamp-deck",
            isDirectory: true
        )
        let revisions = workspace.appendingPathComponent(".lamp/revisions", isDirectory: true)
        for directory in [workspace, context, customSkill, bundledSkill, revisions] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try Data("Outline".utf8).write(to: workspace.appendingPathComponent("outline.md"))
        try Data("Series notes".utf8).write(to: workspace.appendingPathComponent("series.txt"))
        try Data("Primary prose".utf8).write(to: workspace.appendingPathComponent("draft.md"))
        try Data("Generated context".utf8).write(
            to: workspace.appendingPathComponent("DEVOTIONAL_CONTEXT.md")
        )
        try Data("Generated instructions".utf8).write(to: workspace.appendingPathComponent("AGENTS.md"))
        try Data("Generated provider config".utf8).write(to: workspace.appendingPathComponent(".mcp.json"))
        try Data("Source material".utf8).write(to: context.appendingPathComponent("source.pdf"))
        try Data("Skill".utf8).write(
            to: customSkill.deletingLastPathComponent().appendingPathComponent("SKILL.md")
        )
        try Data("Reference".utf8).write(to: customSkill.appendingPathComponent("format.md"))
        try Data("Bundled".utf8).write(to: bundledSkill.appendingPathComponent("SKILL.md"))
        try Data("Revision".utf8).write(to: revisions.appendingPathComponent("123.json"))
        try Data("Internal state".utf8).write(
            to: revisions.deletingLastPathComponent().appendingPathComponent("draft-sync.json")
        )

        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        try LampWorkspaceSync.prepareLibraryForSync(at: sourceLibrary)
        try LampWorkspaceSync.exportPortableWorkspaces(from: sourceLibrary, to: backup)
        let portableWorkspace = backup.appendingPathComponent(
            "Workspaces/Devotionals/talk-123",
            isDirectory: true
        )
        #expect(try String(
            contentsOf: portableWorkspace.appendingPathComponent("Documents/outline.md"),
            encoding: .utf8
        ) == "Outline")
        #expect(try String(
            contentsOf: portableWorkspace.appendingPathComponent("Context/Research/source.pdf"),
            encoding: .utf8
        ) == "Source material")
        #expect(try String(
            contentsOf: backup.appendingPathComponent("Workspaces/Skills/series-planner/SKILL.md"),
            encoding: .utf8
        ) == "Skill")
        let exportedSelection = try JSONDecoder().decode(
            WorkspaceSkillSelection.self,
            from: Data(contentsOf: portableWorkspace.appendingPathComponent("EnabledSkills.json"))
        )
        #expect(exportedSelection.names == ["series-planner"])
        #expect(try String(
            contentsOf: portableWorkspace.appendingPathComponent("Revisions/123.json"),
            encoding: .utf8
        ) == "Revision")
        #expect(!FileManager.default.fileExists(
            atPath: portableWorkspace.appendingPathComponent("Documents/draft.md").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: portableWorkspace.appendingPathComponent("Documents/AGENTS.md").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: backup.appendingPathComponent("Workspaces/Skills/build-lamp-deck/SKILL.md").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: portableWorkspace.appendingPathComponent("Revisions/draft-sync.json").path
        ))

        // The portable names are intentionally non-hidden so the WebDAV archive
        // includes canonical skills and revisions.
        let archivedPaths = try LampSyncArchive.create(from: backup).entries.map(\.path)
        #expect(archivedPaths.contains("Workspaces/Skills/series-planner/SKILL.md"))
        #expect(archivedPaths.contains("Workspaces/Devotionals/talk-123/EnabledSkills.json"))
        #expect(archivedPaths.contains("Workspaces/Devotionals/talk-123/Revisions/123.json"))

        let destinationLibrary = root.appendingPathComponent("Destination Library", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationLibrary, withIntermediateDirectories: true)
        try LampWorkspaceSync.importPortableWorkspaces(from: backup, into: destinationLibrary)
        let importedWorkspace = destinationLibrary.appendingPathComponent(
            "AgentWorkspaces/Devotionals/talk-123",
            isDirectory: true
        )
        #expect(try String(
            contentsOf: importedWorkspace.appendingPathComponent("outline.md"),
            encoding: .utf8
        ) == "Outline")
        #expect(try String(
            contentsOf: importedWorkspace.appendingPathComponent("context/Research/source.pdf"),
            encoding: .utf8
        ) == "Source material")
        #expect(try String(
            contentsOf: importedWorkspace.appendingPathComponent(
                ".agents/skills/series-planner/references/format.md"
            ),
            encoding: .utf8
        ) == "Reference")
        #expect(try String(
            contentsOf: importedWorkspace.appendingPathComponent(".lamp/revisions/123.json"),
            encoding: .utf8
        ) == "Revision")
        #expect(!FileManager.default.fileExists(
            atPath: importedWorkspace.appendingPathComponent("draft.md").path
        ))
        #expect(try String(
            contentsOf: importedWorkspace.appendingPathComponent(
                ".claude/skills/series-planner/references/format.md"
            ),
            encoding: .utf8
        ) == "Reference")
        #expect(try String(
            contentsOf: destinationLibrary.appendingPathComponent(
                "AgentSkills/series-planner/SKILL.md"
            ),
            encoding: .utf8
        ) == "Skill")
    }

    @Test func workspaceImportUsesNewestFileAndConvergesEqualTimestamps() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-workspace-merge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backupDocuments = root.appendingPathComponent(
            "Backup/Workspaces/Devotionals/talk-123/Documents",
            isDirectory: true
        )
        let localWorkspace = root.appendingPathComponent(
            "Library/AgentWorkspaces/Devotionals/talk-123",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: backupDocuments, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localWorkspace, withIntermediateDirectories: true)

        let remoteWins = backupDocuments.appendingPathComponent("remote-wins.md")
        let localRemoteWins = localWorkspace.appendingPathComponent("remote-wins.md")
        let localWins = backupDocuments.appendingPathComponent("local-wins.md")
        let localLocalWins = localWorkspace.appendingPathComponent("local-wins.md")
        let tied = backupDocuments.appendingPathComponent("tied.md")
        let localTied = localWorkspace.appendingPathComponent("tied.md")
        try Data("remote newer".utf8).write(to: remoteWins)
        try Data("local older".utf8).write(to: localRemoteWins)
        try Data("remote older".utf8).write(to: localWins)
        try Data("local newer".utf8).write(to: localLocalWins)
        try Data("zeta".utf8).write(to: tied)
        try Data("alpha".utf8).write(to: localTied)

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let new = old.addingTimeInterval(60)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: remoteWins.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: localRemoteWins.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: localWins.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: localLocalWins.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: tied.path)
        try FileManager.default.setAttributes([.modificationDate: new], ofItemAtPath: localTied.path)

        try LampWorkspaceSync.importPortableWorkspaces(
            from: root.appendingPathComponent("Backup", isDirectory: true),
            into: root.appendingPathComponent("Library", isDirectory: true)
        )
        #expect(try String(contentsOf: localRemoteWins, encoding: .utf8) == "remote newer")
        #expect(try String(contentsOf: localLocalWins, encoding: .utf8) == "local newer")
        #expect(try String(contentsOf: localTied, encoding: .utf8) == "zeta")
    }

    @Test func stagedWorkspaceImportLeavesLiveLibraryUntouchedAfterLateFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-staged-workspace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let liveRoot = root.appendingPathComponent("Library", isDirectory: true)
        let library = LampLibrary(rootURL: liveRoot)
        let liveWorkspace = liveRoot.appendingPathComponent(
            "AgentWorkspaces/Devotionals/talk-123", isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: liveWorkspace, withIntermediateDirectories: true
        )
        let localFile = liveWorkspace.appendingPathComponent("local.md")
        try Data("local document".utf8).write(to: localFile)

        let backupWorkspace = root.appendingPathComponent(
            "Backup/Workspaces/Devotionals/talk-123", isDirectory: true
        )
        let backupDocuments = backupWorkspace.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: backupDocuments, withIntermediateDirectories: true
        )
        try Data("incoming document".utf8).write(
            to: backupDocuments.appendingPathComponent("remote.md")
        )
        let selection = backupWorkspace.appendingPathComponent("EnabledSkills.json")
        try Data("damaged selection".utf8).write(to: selection)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3_600)],
            ofItemAtPath: selection.path
        )

        let backup = root.appendingPathComponent("Backup", isDirectory: true)
        await #expect(throws: DecodingError.self) {
            try await library.withStagedChanges { staged in
                try LampWorkspaceSync.importPortableWorkspaces(
                    from: backup, into: staged.rootURL
                )
            }
        }
        #expect(try Data(contentsOf: localFile) == Data("local document".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: liveWorkspace.appendingPathComponent("remote.md").path
        ))

        try FileManager.default.removeItem(at: selection)
        try await library.withStagedChanges { staged in
            try LampWorkspaceSync.importPortableWorkspaces(
                from: backup, into: staged.rootURL
            )
        }
        #expect(try Data(contentsOf: localFile) == Data("local document".utf8))
        #expect(try Data(contentsOf: liveWorkspace.appendingPathComponent("remote.md"))
            == Data("incoming document".utf8))
    }

    @Test func importsLegacyPerWorkspaceSkillsIntoTheSharedCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-legacy-skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacySkill = root.appendingPathComponent(
            "Backup/Workspaces/Devotionals/talk-123/Skills/lesson-builder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: legacySkill, withIntermediateDirectories: true)
        try """
        ---
        name: lesson-builder
        description: "Builds lessons"
        ---

        Build a lesson.
        """.write(
            to: legacySkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let library = root.appendingPathComponent("Library", isDirectory: true)
        try LampWorkspaceSync.importPortableWorkspaces(
            from: root.appendingPathComponent("Backup", isDirectory: true),
            into: library
        )

        let workspace = library.appendingPathComponent(
            "AgentWorkspaces/Devotionals/talk-123",
            isDirectory: true
        )
        #expect(FileManager.default.fileExists(
            atPath: library.appendingPathComponent("AgentSkills/lesson-builder/SKILL.md").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(
                ".agents/skills/lesson-builder/SKILL.md"
            ).path
        ))
        #expect(try WorkspaceSkillStore.enabledSkillNames(
            in: workspace,
            libraryRootURL: library
        ) == Set(["lesson-builder"]))
    }

    @Test func uploadsDownloadsAndHandlesMissingWebDAVArchive() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = try #require(URL(string: "https://dav.example.com/sync/"))
        let client = LampWebDAVClient(baseURL: baseURL, session: session)
        let payload = Data("archive".utf8)

        TestURLProtocol.handler = { request in
            if request.httpMethod == "PUT" {
                #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            }
            let status = request.httpMethod == "PUT" ? 201 : 200
            let body = request.httpMethod == "GET" ? payload : Data()
            return (HTTPURLResponse(
                url: try #require(request.url),
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!, body)
        }
        try await client.upload(payload, filename: "lamp-bible.lampsync")
        #expect(try await client.download(filename: "lamp-bible.lampsync") == payload)

        TestURLProtocol.handler = { request in
            let url = try #require(request.url)
            if request.httpMethod == "GET" {
                return (HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil,
                    headerFields: ["ETag": "\"archive-v1\""]
                )!, payload)
            }
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"archive-v1\"")
            return (HTTPURLResponse(
                url: url, statusCode: 412, httpVersion: nil, headerFields: nil
            )!, Data())
        }
        let remote = try #require(try await client.read(path: "lamp-bible.lampsync"))
        #expect(remote.revision == "\"archive-v1\"")
        do {
            _ = try await client.write(
                payload, to: "lamp-bible.lampsync",
                condition: .ifRevision(try #require(remote.revision))
            )
            Issue.record("Expected the stale archive write to fail")
        } catch LampSyncError.remoteChanged {
            // The archive changed between the read and write.
        }

        TestURLProtocol.handler = { request in
            #expect(request.httpMethod == "PROPFIND")
            #expect(request.url?.absoluteString == "https://dav.example.com/sync/Notes/")
            let body = Data(#"""
                <?xml version="1.0" encoding="UTF-8"?>
                <d:multistatus xmlns:d="DAV:">
                  <d:response><d:href>/sync/Notes/</d:href></d:response>
                  <d:response><d:href>/sync/Notes/notes.lamp</d:href></d:response>
                  <d:response><d:href>/sync/Notes/My%20Study.lamp</d:href></d:response>
                  <d:response><d:href>/sync/Notes/readme.txt</d:href></d:response>
                  <d:response><d:href>/sync/Notes/folder.lamp/</d:href>
                    <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
                  </d:response>
                </d:multistatus>
                """#.utf8)
            return (HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 207,
                httpVersion: nil,
                headerFields: nil
            )!, body)
        }
        #expect(try await client.listModuleFilenames(directory: "Notes") == ["notes.lamp", "My Study.lamp"])

        TestURLProtocol.handler = { request in
            #expect(request.url?.path == "/sync/Notes/notes.lamp")
            return (HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!, payload)
        }
        #expect(try await client.download(relativePath: "Notes/notes.lamp") == payload)
        #expect(throws: LampSyncError.self) {
            _ = try client.makeRequest(method: "GET", filename: "../secrets")
        }

        TestURLProtocol.handler = { request in
            (HTTPURLResponse(
                url: try #require(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!, Data())
        }
        #expect(try await client.download(filename: "lamp-bible.lampsync") == nil)
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler?(request)
                ?? { throw URLError(.badServerResponse) }()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
