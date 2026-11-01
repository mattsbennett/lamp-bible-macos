import Foundation
import LampCore

public extension LampReadingPlan {
    /// How long the plan is, in the words someone would use.
    ///
    /// A year-round plan is 366 days, because it keeps a slot for 29
    /// February whether or not this year has one — true, and not what anyone
    /// means by it. People say a year is 365 days, so a plan that fills the
    /// year says "A year" and leaves the arithmetic out of it. Every other
    /// length is a count, which is the useful thing about a plan of 22 days.
    var lengthDescription: String {
        switch duration {
        case 365, 366: "A year"
        case 1: "1 day"
        default: "\(duration) days"
        }
    }
}
