import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LampBibleMacSupport

/// A file an agent links to: a bare path is a file, which macOS refused to
/// open (-50); a picture, a video, sound or a PDF opens as a clone of what
/// was checked; everything else is shown in Finder.
struct AgentChatFileLinkTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("links \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The kinds, given here so the rule is tested apart from the type
    /// registry a machine happens to have; `theSystemsKinds` checks that.
    private func viewed(_ url: URL) -> Bool {
        ["png", "mp4", "m4a", "pdf"].contains(url.pathExtension)
    }

    @Test func aBarePathIsAFileAsAFileLinkIs() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let picture = root.appendingPathComponent("test.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        // As Codex wrote it, spaces escaped and no scheme.
        let bare = try #require(URL(string: picture.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!))
        #expect(bare.scheme == nil)
        #expect(AgentChatFileLink.file(for: bare)?.path == picture.path)
        #expect(AgentChatFileLink.file(for: picture)?.path == picture.path)
        #expect(AgentChatFileLink.file(for: URL(fileURLWithPath: picture.path + ":12"))?.path == picture.path)
        #expect(AgentChatFileLink.file(for: URL(string: "https://example.com/a.png")!) == nil)
        #expect(AgentChatFileLink.file(for: URL(string: "draft.md")!) == nil)
        // Another computer's file is not this one's.
        #expect(AgentChatFileLink.file(for: URL(string: "//example.com/notes.txt")!) == nil)
        #expect(AgentChatFileLink.file(for: URL(string: "file://example.com/notes.txt")!) == nil)
        // Answered here, so never handed to macOS, but not this Mac's file.
        #expect(AgentChatFileLink.namesAFile(URL(string: "file://example.com/notes.txt")!))
        #expect(AgentChatFileLink.file(for: URL(string: "file://LOCALHOST" + picture.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)!)?.path == picture.path)
        #expect(!AgentChatFileLink.namesAFile(URL(string: "lamp://passage/John.3.16")!))
        #expect(AgentChatFileLink.namesAFile(bare))
        // A dangling link is there, and keeps its name.
        let dangling = root.appendingPathComponent("gone.png:3")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nowhere/at/all")
        #expect(AgentChatFileLink.file(for: dangling)?.path == dangling.path)
    }

    @Test func aPictureOpensAsACloneOfWhatWasChecked() throws {
        let root = try folder()
        let cache = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        let picture = root.appendingPathComponent("test.png")
        try Data("the picture".utf8).write(to: picture)
        guard case .open(let copy) = AgentChatFileLink.action(for: picture, cache: cache, viewedBy: viewed, selfContained: { _ in true }) else {
            Issue.record("not opened"); return
        }
        #expect(copy.path.hasPrefix(cache.path))
        #expect(copy.lastPathComponent == "test.png")
        #expect(try Data(contentsOf: copy) == Data("the picture".utf8))
        // Changing the workspace's file afterwards changes nothing opened.
        try Data("something else".utf8).write(to: picture)
        #expect(try Data(contentsOf: copy) == Data("the picture".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o400)
        // Its extended attributes stay behind: an "open with" choice, an
        // alias's mark.
        let marked = root.appendingPathComponent("marked.png")
        try Data("x".utf8).write(to: marked)
        #expect(setxattr(marked.path, "com.apple.LaunchServices.OpenWith", "Terminal", 8, 0, 0) == 0)
        guard case .open(let clean) = AgentChatFileLink.action(for: marked, cache: cache, viewedBy: viewed, selfContained: { _ in true }) else {
            Issue.record("not opened"); return
        }
        let left = open(clean.path, O_RDONLY)
        defer { close(left) }
        #expect(AgentChatFileLink.attributeNames(left)?.filter { $0 != "com.apple.provenance" } == [])
        // Quarantine stays, for the viewer to heed.
        let downloaded = root.appendingPathComponent("downloaded.png")
        try Data("x".utf8).write(to: downloaded)
        let mark = "0081;00000000;Safari;"
        #expect(setxattr(downloaded.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)
        guard case .open(let marked2) = AgentChatFileLink.action(for: downloaded, cache: cache, viewedBy: viewed, selfContained: { _ in true }) else {
            Issue.record("not opened"); return
        }
        #expect(getxattr(marked2.path, "com.apple.quarantine", nil, 0, 0, 0) > 0)
        // A locked file's clone is unlocked, so it can be pruned.
        let locked = root.appendingPathComponent("locked.png")
        try Data("x".utf8).write(to: locked)
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        guard case .open(let lockedCopy) = AgentChatFileLink.action(for: locked, cache: cache, viewedBy: viewed, selfContained: { _ in true }) else {
            Issue.record("not opened"); return
        }
        var flags = stat()
        #expect(lstat(lockedCopy.path, &flags) == 0 && flags.st_flags & UInt32(UF_IMMUTABLE) == 0)
    }

    @Test func allElseIsShownInFinder() throws {
        let root = try folder()
        let cache = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: cache) }
        func make(_ name: String, executable: Bool = false) throws -> URL {
            let file = root.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
            return file
        }
        func action(_ url: URL) -> AgentChatFileLink.Action { AgentChatFileLink.action(for: url, cache: cache, viewedBy: viewed, selfContained: { _ in true }) }
        for name in ["clip.mp4", "sound.m4a", "page.pdf"] {
            if case .open = action(try make(name)) {} else { Issue.record("\(name) not opened") }
        }
        // Text, which an editor would change in the copy; what runs; what
        // can't be told.
        for name in ["notes.md", "deck.json", "page.html", "go.sh", "build.py", "thing.zqxv", "art.svg", "talk.lampdeck", "kjv.lamp"] {
            let file = try make(name)
            #expect(action(file) == .reveal(file), "\(name)")
        }
        // A program by its mode, whatever its name.
        let disguised = try make("picture.png", executable: true)
        #expect(action(disguised) == .reveal(disguised))
        // A folder, and an app, which is one.
        #expect(action(root) == .reveal(root))
        let app = root.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(action(app) == .reveal(app))
        // A link is judged as itself, never as where it leads.
        let link = root.appendingPathComponent("innocent.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: try make("real.png"))
        #expect(action(link) == .reveal(link))
        let dangling = root.appendingPathComponent("gone.png")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: "/nowhere/at/all")
        #expect(action(dangling) == .reveal(dangling))
        // A Finder alias named as a picture is shown, never viewed.
        let alias = root.appendingPathComponent("sample.png")
        try URL.writeBookmarkData(try app.bookmarkData(options: .suitableForBookmarkFile), to: alias)
        #expect(action(alias) == .reveal(alias))
        #expect(action(root.appendingPathComponent("missing.png")) == .missing)
    }

    /// The kinds the system's own types give, where the machine has a type
    /// registry to ask.
    @Test(.enabled(if: UTType.png.conforms(to: .image), "no type registry here"))
    func theSystemsKinds() {
        for name in ["a.png", "a.jpg", "a.heic", "a.mp4", "a.mov", "a.m4a", "a.pdf"] {
            #expect(AgentChatFileLink.isViewed(URL(fileURLWithPath: "/x/" + name)), "\(name)")
        }
        for name in ["a.svg", "a.html", "a.md", "a.json", "a.sh", "a.py", "a.command", "a.app", "a.lamp", "a.lampdeck", "a.zqxv", "a",
                     "a.asx", "a.m3u", "a.m3u8", "a.pls", "a.webloc"] {
            #expect(!AgentChatFileLink.isViewed(URL(fileURLWithPath: "/x/" + name)), "\(name)")
        }
    }

    /// The cache is Lamp's: a link in its place is refused, and only folders
    /// Lamp named are ever pruned.
    @Test func aRedirectedCacheIsRefusedAndOnlyLampsFoldersArePruned() throws {
        let root = try folder()
        let elsewhere = try folder()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: elsewhere) }
        let picture = root.appendingPathComponent("test.png")
        try Data("x".utf8).write(to: picture)
        let redirected = root.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: elsewhere)
        #expect(AgentChatFileLink.action(for: picture, cache: redirected, viewedBy: viewed, selfContained: { _ in true }) == .reveal(picture))

        let cache = try folder()
        defer { try? FileManager.default.removeItem(at: cache) }
        let old = Date().addingTimeInterval(-3 * 86_400)
        let mine = cache.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let theirs = cache.appendingPathComponent("Keep", isDirectory: true)
        for made in [mine, theirs] {
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: made.path)
        }
        _ = AgentChatFileLink.action(for: picture, cache: cache, viewedBy: viewed, selfContained: { _ in true })
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: theirs.path))
    }
}
