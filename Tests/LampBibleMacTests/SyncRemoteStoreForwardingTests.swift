import Foundation
import LampBibleMacSupport
import LampModuleKit
import Testing

/// `LampSyncRemoteStore`'s streaming members and its delete have default
/// implementations, so a store that forwards none of them still compiles and
/// still passes every other test. The defaults are not equivalent: they hold a
/// whole body in memory, and the delete throws, which means a tombstoned file
/// is never reaped and its bytes stay on the server for good. Both failures are
/// silent, so they are held here.
///
/// Serialized because the stub protocol's handler is necessarily static, and
/// parallel cases would answer each other's requests.
@Suite(.serialized)
struct SyncRemoteStoreForwardingTests {
    private func client(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data))
        throws -> LampWebDAVClient
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ForwardingTestURLProtocol.self]
        ForwardingTestURLProtocol.handler = handler
        return LampWebDAVClient(
            baseURL: try #require(URL(string: "https://dav.example.com/sync/")),
            session: URLSession(configuration: configuration)
        )
    }

    private func response(
        _ request: URLRequest,
        _ status: Int,
        _ headers: [String: String]? = nil
    ) throws -> HTTPURLResponse {
        let url = try #require(request.url)
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    @Test func everyStoreMethodIsForwardedRatherThanLeftToItsDefault() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/LampBibleMacSupport/SyncSupport.swift"),
            encoding: .utf8
        )
        // Declared on the client, so the protocol's default never stands in.
        for declaration in [
            "public func read(path: String, into url: URL) async throws -> LampSyncDownloadedFile?",
            "public func write(\n        fileAt url: URL,",
            "public func delete(path: String, condition: LampSyncWriteCondition) async throws",
        ] {
            #expect(
                source.contains(declaration),
                "LampWebDAVClient must forward this itself: \(declaration)"
            )
        }
    }

    @Test func aBodyIsReadIntoAFileWithItsRevision() async throws {
        let payload = Data("a module's bytes".utf8)
        let client = try client { request in
            #expect(request.httpMethod == "GET")
            return (try self.response(request, 200, ["ETag": "\"module-v3\""]), payload)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-forwarding-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let downloaded = try #require(
            try await client.read(path: "Translations/kjv.lamp", into: destination)
        )
        #expect(downloaded.url == destination)
        #expect(downloaded.revision == "\"module-v3\"")
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func aFileIsWrittenFromDiskUnderItsCondition() async throws {
        let payload = Data("the bytes to publish".utf8)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-forwarding-\(UUID().uuidString)")
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let client = try client { request in
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"module-v3\"")
            return (try self.response(request, 204, ["ETag": "\"module-v4\""]), Data())
        }
        let revision = try await client.write(
            fileAt: source,
            to: "Translations/kjv.lamp",
            condition: .ifRevision("\"module-v3\"")
        )
        #expect(revision == "\"module-v4\"")
    }

    @Test func aDeleteIsSentUnderItsConditionAndAnAbsentFileCountsAsDone() async throws {
        var methods: [String] = []
        let client = try client { request in
            methods.append(request.httpMethod ?? "?")
            #expect(request.value(forHTTPHeaderField: "If-Match") == "\"reaped-v1\"")
            return (try self.response(request, 404), Data())
        }
        // A file already gone is the outcome a reap wanted, not a failure.
        try await client.delete(
            path: "Translations/gone.lamp",
            condition: .ifRevision("\"reaped-v1\"")
        )
        #expect(methods == ["DELETE"])
    }

    /// The one that matters most, and the one that would have been silent:
    /// `LampWebDAVClient` translates the storage layer's errors into
    /// `LampSyncError` for the user's sake, and `isRefusal` recognises the
    /// storage error rather than the translation. Unrecognised, a refusal
    /// reads as an ordinary failure, so the settings bundle's read-merge-retry
    /// would abandon the pass instead of reading again — exactly the case it
    /// exists to recover from.
    @Test func aRefusedWriteIsStillRecognisedAsARefusalAfterTranslation() async throws {
        let client = try client { request in
            (try self.response(request, 412), Data())
        }
        await #expect(throws: (any Error).self) {
            _ = try await client.write(
                Data("settings".utf8),
                to: "lamp-bible.lampsync",
                condition: .ifRevision("\"bundle-v9\"")
            )
        }
        do {
            _ = try await client.write(
                Data("settings".utf8),
                to: "lamp-bible.lampsync",
                condition: .ifRevision("\"bundle-v9\"")
            )
            Issue.record("a 412 must not read as a successful write")
        } catch {
            #expect(
                LampSyncConditionalWrite.isRefusal(error),
                "a translated 412 must still be a refusal, or update() gives up instead of retrying"
            )
        }
    }

    @Test func aRefusedDeleteIsStillRecognisedAsARefusal() async throws {
        let client = try client { request in
            (try self.response(request, 412), Data())
        }
        do {
            try await client.delete(
                path: "Translations/kjv.lamp",
                condition: .ifRevision("\"module-v3\"")
            )
            Issue.record("a 412 must not read as a successful delete")
        } catch {
            #expect(!(error is LampSyncRemoteStoreError), "the delete must be forwarded, not defaulted")
            #expect(LampSyncConditionalWrite.isRefusal(error))
        }
    }
}

private final class ForwardingTestURLProtocol: URLProtocol, @unchecked Sendable {
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
