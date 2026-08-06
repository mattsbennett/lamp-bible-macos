import Foundation

/// A bounded, steppable text measurement — a point size or a line spacing — that
/// several controls have to agree on: a slider in Settings, the increase and
/// decrease buttons in a text-size menu, and the stored default they both reset
/// to. Keeping the bounds in one value means a size nudged to its limit in the
/// menu is still a size the slider can express.
public struct LampTextScale: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let step: Double
    public let defaultValue: Double

    public init(minimum: Double, maximum: Double, step: Double, defaultValue: Double) {
        self.minimum = minimum
        self.maximum = max(maximum, minimum)
        self.step = max(step, 0.01)
        self.defaultValue = min(max(defaultValue, minimum), max(maximum, minimum))
    }

    public var range: ClosedRange<Double> { minimum...maximum }

    public func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }

    /// Moves `value` by whole steps, snapping onto the step grid on the way. A
    /// stored size that predates a change of step — or that a slider left between
    /// grid points — otherwise carries its offset forward forever.
    public func stepped(_ value: Double, by steps: Int) -> Double {
        let current = clamped(value)
        guard steps != 0 else { return current }
        let offset = (current - minimum) / step
        // Snap toward the direction of travel first, so a nudge upward from 20.5
        // lands on 21 rather than 21.5, and a nudge downward lands on 20.
        let snapped = steps > 0 ? (offset + 1e-9).rounded(.down) : (offset - 1e-9).rounded(.up)
        return clamped(minimum + (snapped + Double(steps)) * step)
    }

    public func canIncrease(_ value: Double) -> Bool {
        clamped(value) < maximum - 1e-9
    }

    public func canDecrease(_ value: Double) -> Bool {
        clamped(value) > minimum + 1e-9
    }
}

public extension LampTextScale {
    /// Scripture is the one thing on screen a reader stares at for an hour, so it
    /// stretches further in both directions than the study panels beside it.
    static let readerText = LampTextScale(
        minimum: 14,
        maximum: 34,
        step: 1,
        defaultValue: 20
    )

    static let readerLineSpacing = LampTextScale(
        minimum: 2,
        maximum: 16,
        step: 1,
        defaultValue: 7
    )

    /// Commentary is prose about the text rather than the text itself, and it sits
    /// in a narrow panel, so it starts near the system body size.
    static let commentaryText = LampTextScale(
        minimum: 11,
        maximum: 26,
        step: 1,
        defaultValue: 13
    )

    /// Commentary runs to dense paragraphs of it; the default is deliberately
    /// looser than the near-zero spacing SwiftUI gives a plain `Text`.
    static let commentaryLineSpacing = LampTextScale(
        minimum: 0,
        maximum: 14,
        step: 1,
        defaultValue: 6
    )
}
