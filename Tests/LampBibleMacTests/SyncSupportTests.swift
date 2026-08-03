import Foundation
import LampBibleMacSupport
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

    @Test func uploadsDownloadsAndHandlesMissingWebDAVArchive() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let baseURL = try #require(URL(string: "https://dav.example.com/sync/"))
        let client = LampWebDAVClient(baseURL: baseURL, session: session)
        let payload = Data("archive".utf8)

        TestURLProtocol.handler = { request in
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
