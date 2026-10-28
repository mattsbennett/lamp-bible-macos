import Foundation

/// What has been typed but not yet written, and the app's promise not to quit
/// on top of it.
///
/// Lamp's editors write on a short delay — long enough that typing never waits
/// on a disk — and that delay is spent inside a SwiftUI `.task`, which is
/// cancelled when its view goes away. A view can cover its own disappearance.
/// It cannot cover the process exiting: the save runs on a task of its own, and
/// nothing holds the app open for it.
///
/// So editors register here, the application delegate asks everything to write
/// before it lets the app close, and the count of writes in flight says when it
/// is safe to go.
@MainActor
public final class LampPendingWrites {
    public static let shared = LampPendingWrites()

    private var flushes: [UUID: () -> Void] = [:]
    private var inFlight = 0
    private var quietHandler: (() -> Void)?

    public init() {}

    /// Registers something holding unwritten work, keyed so that a view can
    /// take it back when it goes away.
    public func register(_ id: UUID, flush: @escaping () -> Void) {
        flushes[id] = flush
    }

    public func unregister(_ id: UUID) {
        flushes.removeValue(forKey: id)
    }

    public var registrationCount: Int { flushes.count }

    /// A write has started. The app should wait for it.
    public func begin() {
        inFlight += 1
    }

    /// A write has finished, whether it succeeded or failed. A failed write is
    /// still over, and holding the app open for it would only stop it quitting.
    public func end() {
        guard inFlight > 0 else { return }
        inFlight -= 1
        guard inFlight == 0, let waiting = quietHandler else { return }
        quietHandler = nil
        waiting()
    }

    public var isQuiet: Bool { inFlight == 0 }

    /// Asks everything registered to write what it is holding.
    ///
    /// Returns `true` when nothing is left to wait for — in that case
    /// `onQuiet` is never called, and the caller can go ahead. Otherwise
    /// `onQuiet` runs once the last write finishes.
    ///
    /// Flushing is what *starts* those writes, so the count is only meaningful
    /// after every flush has run.
    @discardableResult
    public func flushAll(onQuiet: @escaping () -> Void) -> Bool {
        for flush in flushes.values { flush() }
        if inFlight == 0 { return true }
        quietHandler = onQuiet
        return false
    }

    /// Drops a handler that is no longer wanted, so a later write cannot call
    /// it. Used when the wait has already been given up on.
    public func cancelQuietHandler() {
        quietHandler = nil
    }
}
