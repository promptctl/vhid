import Foundation
import Pointing

/// Where a person's aimed pointer movement is, moment by moment, from one point to another:
/// a primary submovement that bows to one side and stops short, then a corrective one onto
/// the target, each with the bell-shaped speed profile of a minimum-jerk movement. Pure:
/// every draw is taken when it is made. `docs/design/human.md`, "The model".
public struct Trajectory: Sendable, Equatable {
    public let start: ScreenPoint
    public let target: ScreenPoint
    /// How long the whole movement takes, by Fitts' law and a drawn pace.
    public let duration: Duration
    /// The movement that gets most of the way.
    public let primary: Submovement
    /// The one that takes it the rest of the way, straight.
    public let correction: Submovement

    /// Fitts' law, MT = a + b × log2(D/W + 1), with the constants of the human-like
    /// generator in Choudhary et al. W is fixed: vhid is given a point, not a target, and
    /// 20 points is about a button's height or a line of text's.
    static let intercept: Duration = .milliseconds(50)
    static let slope: Duration = .milliseconds(150)
    static let width = 20.0
    /// What MT is multiplied by, so two moves of one distance do not take one time.
    static let pace = Normal(1, 0.15, within: 0.7 ... 1.3)
    /// The primary submovement's share of MT; the correction has the rest.
    static let primaryShare = 0.8
    /// How far short of the target the primary submovement aims, as a fraction of D.
    static let short = Normal(0.05, 0.03, within: 0.01 ... 0.10)
    /// How far off the line it aims, as a fraction of D.
    static let offLine = Normal(0, 0.02, within: -0.04 ... 0.04)
    /// How far its path bows to one side at the middle, as a fraction of D.
    static let bow = Normal(0, 0.03, within: -0.06 ... 0.06)

    /// A movement from `start` to `target` with every variable drawn from `generator`, in
    /// one fixed order whatever the distance, so one seed always means one movement.
    /// A movement under a point long takes no time: the closing loop has it all.
    public init(from start: ScreenPoint, to target: ScreenPoint, drawing generator: inout some RandomNumberGenerator) {
        let (pace, short, offLine, bow) = (Self.pace.draw(using: &generator), Self.short.draw(using: &generator),
                                           Self.offLine.draw(using: &generator), Self.bow.draw(using: &generator))
        let (dx, dy) = (target.x - start.x, target.y - start.y)
        let distance = hypot(dx, dy)
        let fitts = Self.intercept + Self.slope * log2(distance / Self.width + 1)
        let duration = distance < 1 ? .zero : fitts * pace
        // Along the line toward the target, and across it, as unit vectors; the zero vector
        // for a movement of no length, which then has no aim to set off either way.
        let (along, across) = distance > 0 ? ((dx / distance, dy / distance), (-dy / distance, dx / distance)) : ((0, 0), (0, 0))
        let aim = (x: target.x - along.0 * short * distance + across.0 * offLine * distance,
                   y: target.y - along.1 * short * distance + across.1 * offLine * distance)
        self.start = start
        self.target = target
        self.duration = duration
        primary = Submovement(from: (start.x, start.y), to: aim, bow: bow * distance, duration: duration * Self.primaryShare)
        correction = Submovement(from: aim, to: (target.x, target.y), bow: 0, duration: duration * (1 - Self.primaryShare))
    }

    /// Where the movement is `elapsed` after it began: the target from `duration` on.
    public func point(after elapsed: Duration) -> (x: Double, y: Double) {
        elapsed < primary.duration ? primary.point(after: elapsed) : correction.point(after: elapsed - primary.duration)
    }
}

/// One submovement: a minimum-jerk stroke from one point to another, bowing to one side by
/// `bow` points at its middle, along (−dy, dx) of its direction when positive and the
/// other way when negative.
public struct Submovement: Sendable, Equatable {
    public let from: Point
    public let to: Point
    public let bow: Double
    public let duration: Duration

    public typealias Point = (x: Double, y: Double)

    public static func == (a: Submovement, b: Submovement) -> Bool {
        a.from == b.from && a.to == b.to && a.bow == b.bow && a.duration == b.duration
    }

    /// The fraction of the distance a minimum-jerk movement has covered at fraction `t` of
    /// its time: 10t³ − 15t⁴ + 6t⁵, whose speed rises and falls in a bell (Flash and Hogan).
    static func covered(_ t: Double) -> Double { t * t * t * (10 - 15 * t + 6 * t * t) }

    /// Where the stroke is `elapsed` after it began: `to` from `duration` on, and `to` for
    /// a stroke that takes no time.
    func point(after elapsed: Duration) -> Point {
        let t = duration > .zero ? min(1, max(0, elapsed / duration)) : 1
        let u = Self.covered(t)
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        let length = hypot(dx, dy)
        let off = length > 0 ? bow * sin(.pi * u) / length : 0
        return (from.x + dx * u - dy * off, from.y + dy * u + dx * off)
    }
}
