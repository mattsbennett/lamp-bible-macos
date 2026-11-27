import Darwin
import Foundation
import Testing
@testable import LampBibleMac

/// A Claude Terminal holds its writing's chats from the hand-over until the
/// process Lamp started is gone, and nothing else lets it go
/// (`decisions/0042`).
@MainActor
@Suite(.serialized)
struct AgentTerminalHoldsTests {
    private let holds = AgentTerminalHolds.shared

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A process of the test's own, as the Terminal's would be.
    private func spawn(_ script: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        return process
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func heldFromTheHandOverBeforeAnyProcess() throws {
        let place = try workspace()
        let launch = UUID()
        holds.begin(launch, in: place)
        defer { holds.dropIfNotStarted(launch) }
        #expect(holds.isHeld(in: place))
    }

    @Test func onlyClaudesTerminalHolds() {
        #expect(AgentTerminalHolds.holds(.claude))
        #expect(!AgentTerminalHolds.holds(.codex))
        #expect(!AgentTerminalHolds.holds(.openCode))
    }

    @Test func anotherWritingIsNotHeldAndALinkedPathIsTheSame() throws {
        let place = try workspace(), other = try workspace()
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("holds-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: place)
        defer { try? FileManager.default.removeItem(at: link) }
        let launch = UUID()
        holds.begin(launch, in: place)
        defer { holds.dropIfNotStarted(launch) }
        #expect(!holds.isHeld(in: other))
        #expect(holds.isHeld(in: link))
    }

    /// Nothing but the process's end lets it go: not the view's going while
    /// it runs, which is only ever a `dropIfNotStarted`.
    @Test func aRunningProcessHoldsUntilKilledFromOutside() async throws {
        let place = try workspace()
        let process = try spawn("sleep 30")
        defer { if process.isRunning { process.terminate() } }
        let launch = UUID()
        holds.begin(launch, in: place)
        holds.started(launch, pid: process.processIdentifier)
        holds.dropIfNotStarted(launch)
        #expect(holds.isHeld(in: place))
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        #expect(!holds.isHeld(in: place))
        // And is let go of once found gone.
        await waitUntil { holds.launches[launch] == nil }
        #expect(holds.launches[launch] == nil)
    }

    @Test func twoTerminalsHoldUntilBothEnd() throws {
        let place = try workspace()
        let first = UUID(), second = UUID()
        holds.begin(first, in: place)
        holds.begin(second, in: place)
        holds.ended(first)
        #expect(holds.isHeld(in: place))
        holds.ended(second)
        #expect(!holds.isHeld(in: place))
    }

    @Test func aProcessThatCouldNotStartHoldsNothing() throws {
        let place = try workspace()
        let launch = UUID()
        holds.begin(launch, in: place)
        holds.started(launch, pid: 0)
        #expect(!holds.isHeld(in: place))
    }

    /// End asks it to stop, and a process that ignores that is held until
    /// it is killed.
    @Test func endStopsEvenAProcessThatIgnoresTerm() async throws {
        let place = try workspace()
        let process = try spawn("trap '' TERM; sleep 30 & wait")
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Its trap set before it is asked to stop.
        try await Task.sleep(for: .milliseconds(200))
        let launch = UUID()
        holds.begin(launch, in: place)
        holds.started(launch, pid: process.processIdentifier)
        holds.end(in: place, killAfter: 0.5)
        try await Task.sleep(for: .milliseconds(200))
        #expect(holds.isHeld(in: place), "held while it ignores the request to stop")
        await waitUntil { !process.isRunning }
        #expect(!process.isRunning)
        #expect(!holds.isHeld(in: place))
    }

    @Test func endClearsALaunchNotStartedYet() throws {
        let place = try workspace()
        let launch = UUID()
        holds.begin(launch, in: place)
        holds.end(in: place)
        #expect(!holds.isHeld(in: place))
    }

    /// The pid of a process gone and given to another doesn't hold.
    @Test func aReusedPidIsNotTheSameProcess() throws {
        let process = try spawn("sleep 30")
        defer { process.terminate() }
        let began = try #require(AgentTerminalHolds.beginning(of: process.processIdentifier))
        #expect(AgentTerminalHolds.isAlive(process.processIdentifier, began: began))
        #expect(!AgentTerminalHolds.isAlive(process.processIdentifier, began: began - 1))
    }

    /// The chat's model is the last line: nothing starts in a held writing,
    /// whoever asked.
    @Test func aHeldWritingsChatSendsNothing() async throws {
        let place = try workspace()
        let launch = UUID()
        holds.begin(launch, in: place)
        defer { holds.dropIfNotStarted(launch) }
        let model = KeptAgentChats.model(provider: .codex, workspace: place, mode: .writing)
        defer { KeptAgentChats.drop(model) }
        let taken = await model.send("Hello", contextualPrompt: "Hello", inConversation: model.conversationID)
        #expect(!taken)
        #expect(!model.isRunning)
        #expect(model.messages.isEmpty)
    }
}
