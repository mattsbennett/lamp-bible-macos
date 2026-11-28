import Combine
import Darwin
import Foundation

/// The Claude sessions running in each writing's Terminal, which hold that
/// writing's chats until they end (`decisions/0042`).
///
/// Claude Code reloads its settings while it runs, so a rule a chat's agent
/// wrote into the writing's `.claude/settings.local.json` would apply in an
/// open Terminal at once, past the check made as it opened (`decisions/0038`).
/// While one runs, no chat in that writing starts a turn, from any pane or the
/// phone.
///
/// Held from the hand-over and released only when the process Lamp started
/// is gone: by its exit, which the Terminal's watch reports even once its
/// view is taken down, or found gone when asked. Never by time, by what the
/// capture files say (an agent could write them), by the pane being hidden or
/// by the mode: a Terminal switched away from is still running. A hold 0038
/// took out failed by guessing when the CLI had read its settings; this one
/// asks only whether the process Lamp started is alive.
///
/// The boundary: the process Lamp started. A shell profile that hands the
/// session to tmux puts Claude in a server Lamp never sees.
@MainActor
final class AgentTerminalHolds: ObservableObject {
    static let shared = AgentTerminalHolds()

    enum State: Equatable {
        /// Handed its command, its process not started yet.
        case starting
        /// Running as this process, which began at this time: a pid can be
        /// reused once the process has gone.
        case running(pid: pid_t, began: Double)
    }

    struct Launch {
        var workspace: String
        var state: State
        /// A Claude Terminal's, which holds the writing's chats; every
        /// provider's is kept, since an OpenCode turn starts beside none
        /// (`decisions/0043`).
        var holdsChats: Bool
    }

    @Published private(set) var launches: [UUID: Launch] = [:]
    /// Launches End was pressed for, still held until their process is
    /// gone: a login shell ignores the request to stop, and its command,
    /// typed a moment after it starts, mustn't be typed then.
    private(set) var endAsked: Set<UUID> = []

    /// Whether a Terminal of this provider holds its writing's chats: Claude
    /// Code's, which reloads its settings while it runs. Codex and OpenCode
    /// read theirs as they start, so the check made then covers them.
    nonisolated static func holds(_ provider: AIProviderCLI) -> Bool {
        provider == .claude
    }

    /// A writing's key, the same however its path is spelled.
    nonisolated static func key(_ workspace: URL) -> String {
        workspace.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// A Claude Terminal is handed its command in this writing: held from
    /// now, before its process exists.
    func begin(_ id: UUID, in workspace: URL, holdsChats: Bool = true) {
        launches[id] = Launch(workspace: Self.key(workspace), state: .starting, holdsChats: holdsChats)
    }

    /// Its process started. One that could not start ends the hold.
    func started(_ id: UUID, pid: pid_t) {
        guard var launch = launches[id] else { return }
        guard pid > 0, let began = Self.beginning(of: pid) else {
            launches[id] = nil
            return
        }
        launch.state = .running(pid: pid, began: began)
        launches[id] = launch
    }

    /// Its process exited.
    func ended(_ id: UUID) {
        if launches[id] != nil { launches[id] = nil }
        endAsked.remove(id)
    }

    /// Whether End was pressed for this launch.
    func isEndAsked(_ id: UUID) -> Bool { endAsked.contains(id) }

    /// Whether this launch is still waiting for its process: false once it
    /// was dropped or ended before it started, when it mustn't start at all.
    func isPending(_ id: UUID) -> Bool {
        launches[id]?.state == .starting
    }

    /// A launch whose process never started: its view went, or was never
    /// made, or a newer launch replaced it. One that started is ended by its
    /// exit alone.
    func dropIfNotStarted(_ id: UUID) {
        if launches[id]?.state == .starting { launches[id] = nil }
    }

    /// Whether a Claude Terminal holds this writing's chats now. A process
    /// found gone is let go, after this returns, so asking from a view's body
    /// changes nothing while it is drawn.
    func isHeld(in workspace: URL) -> Bool {
        isLive(in: workspace) { $0.holdsChats }
    }

    /// Whether any provider's Terminal runs in this writing now.
    func hasTerminal(in workspace: URL) -> Bool {
        isLive(in: workspace) { _ in true }
    }

    private func isLive(in workspace: URL, _ counts: (Launch) -> Bool) -> Bool {
        let key = Self.key(workspace)
        var held = false
        var gone: [UUID] = []
        for (id, launch) in launches where launch.workspace == key && counts(launch) {
            switch launch.state {
            case .starting:
                held = true
            case .running(let pid, let began):
                if Self.isAlive(pid, began: began) { held = true } else { gone.append(id) }
            }
        }
        if !gone.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for id in gone { self?.forgetIfGone(id) }
            }
        }
        return held
    }

    /// Ends every Claude Terminal session in this writing: asked to stop,
    /// then killed if it is still the same process a few seconds on. Its exit
    /// is reported as any exit is, which collects its last turns and lets the
    /// hold go. One not started yet is dropped.
    func end(in workspace: URL, killAfter seconds: Double = 3) {
        let key = Self.key(workspace)
        // Only those holding the chats: another provider's Terminal is left.
        for (id, launch) in launches where launch.workspace == key && launch.holdsChats {
            switch launch.state {
            case .starting:
                launches[id] = nil
            case .running(let pid, let began):
                endAsked.insert(id)
                if Self.isAlive(pid, began: began) { kill(pid, SIGTERM) }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    if Self.isAlive(pid, began: began) { kill(pid, SIGKILL) }
                }
            }
        }
    }

    private func forgetIfGone(_ id: UUID) {
        guard case .running(let pid, let began) = launches[id]?.state, !Self.isAlive(pid, began: began) else { return }
        launches[id] = nil
    }

    // MARK: - The process

    /// When a process began, from the kernel; nil if there is none.
    nonisolated static func beginning(of pid: pid_t) -> Double? {
        guard let info = processInfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }

    /// Whether the process that began at `began` is still running: not gone,
    /// not exited and waiting to be reaped, and not another process given
    /// the same pid since.
    nonisolated static func isAlive(_ pid: pid_t, began: Double) -> Bool {
        guard let info = processInfo(pid), info.kp_proc.p_stat != SZOMB,
              let now = beginning(of: pid) else { return false }
        return now == began
    }

    nonisolated private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }
}
