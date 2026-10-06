import Foundation
import Pointing

/// Where a person's aimed pointer movement is, moment by moment, from one point to another:
/// a primary submovement that bows to one side and stops short, then a corrective one onto
/// the target, each with the bell-shaped speed profile of a minimum-jerk movement. Pure:
/// every draw is taken when it is made. `docs/design/human.md`, "The model".
public struct Trajectory: Sendable, Equatable {
    public let start: ScreenPoint
    /// The point drawn inside the target it was aimed at, where it ends.
    public let target: ScreenPoint
    /// The point or box it was aimed at, whose width its time was read off by Fitts' law.
    public let toward: Target
    /// How long the whole movement takes, by Fitts' law and a drawn pace.
    public let duration: Duration
    /// How much of its drawn bow and aim off the line the path kept to stay on the
    /// displays: one for all of it, zero for the straight line.
    public let kept: Double
    /// The movement that gets most of the way.
    public let primary: Submovement
    /// The one that takes it the rest of the way, straight.
    public let correction: Submovement

    /// Fitts' law, MT = a + b × log2(D/W + 1), with the constants of the human-like
    /// generator in Choudhary et al. W is the target's: `Target.width`.
    static let intercept: Duration = .milliseconds(50)
    static let slope: Duration = .milliseconds(150)
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

    /// How near the displays' edges a bow may carry the path, in points, where the straight
    /// line keeps further off: a button's height of room. The steering follows the path to
    /// within a few points, so the cursor stays clear of an edge it does not mean to touch.
    static let margin = Target.button
    /// The shares of the drawn deviation tried, most first, until one keeps the path on the
    /// displays; none fitting leaves the straight line.
    static let shares = stride(from: 1.0, to: 0.05, by: -0.1).map { $0 }
    /// How many evenly spaced moments of the movement are checked against the displays:
    /// a few milliseconds apart on the longest move, closer than the steering's ticks.
    static let checks = 256

    /// A movement from `start` to a point aimed at inside `target` with every variable drawn
    /// from `generator`, in one fixed order whatever the distance, the aim first, so one seed
    /// always means one movement. A movement under a point long takes no time: the closing
    /// loop has it all.
    ///
    /// **The bow and the aim off the line are drawn whole and kept in part.** A path that
    /// bows by up to a tenth of its length runs into the edge beside a target approached
    /// along it: an auto-hidden Dock rises and covers the target, a corner fires, and while
    /// the cursor is held at the edge the curve is learned from reports macOS clamped. So
    /// the path keeps the largest of `shares` of its deviation under which, at every check,
    /// it is no nearer an edge than the straight line is there, to within `margin`; a
    /// straight line between two points on one display is on it, and the share is a value
    /// rather than a branch, so a path far from every edge keeps it all.
    /// [LAW:dataflow-not-control-flow]
    public init(from start: ScreenPoint, toward aimed: Target, within displays: Displays, drawing generator: inout some RandomNumberGenerator) {
        let target = aimed.aim(drawing: &generator)
        let (pace, short, offLine, bow) = (Self.pace.draw(using: &generator), Self.short.draw(using: &generator),
                                           Self.offLine.draw(using: &generator), Self.bow.draw(using: &generator))
        let (dx, dy) = (target.x - start.x, target.y - start.y)
        let distance = hypot(dx, dy)
        let fitts = Self.intercept + Self.slope * log2(distance / aimed.width + 1)
        let duration = distance < 1 ? .zero : fitts * pace
        // Along the line toward the target, and across it, as unit vectors; the zero vector
        // for a movement of no length, which then has no aim to set off either way.
        let (along, across) = distance > 0 ? ((dx / distance, dy / distance), (-dy / distance, dx / distance)) : ((0, 0), (0, 0))
        func path(keeping share: Double) -> (primary: Submovement, correction: Submovement) {
            let aim = (x: target.x - along.0 * short * distance + across.0 * offLine * share * distance,
                       y: target.y - along.1 * short * distance + across.1 * offLine * share * distance)
            return (Submovement(from: (start.x, start.y), to: aim, bow: bow * share * distance, duration: duration * Self.primaryShare),
                    Submovement(from: aim, to: (target.x, target.y), bow: 0, duration: duration * (1 - Self.primaryShare)))
        }
        let moments = (0 ... Self.checks).map { duration * (Double($0) / Double(Self.checks)) }
        let straight = path(keeping: 0)
        let depths = moments.map { displays.depth(of: Self.point(after: $0, on: straight), upTo: Self.margin) }
        let kept = Self.shares.first { share in
            let bowed = path(keeping: share)
            return zip(moments, depths).allSatisfy { moment, depth in
                depth.map { displays.covers(Self.point(after: moment, on: bowed), by: $0) } ?? true
            }
        } ?? 0
        self.start = start
        self.target = target
        toward = aimed
        self.duration = duration
        self.kept = kept
        (primary, correction) = path(keeping: kept)
    }

    /// Where the movement is `elapsed` after it began: the target from `duration` on.
    public func point(after elapsed: Duration) -> (x: Double, y: Double) {
        Self.point(after: elapsed, on: (primary, correction))
    }

    private static func point(after elapsed: Duration, on path: (primary: Submovement, correction: Submovement)) -> Submovement.Point {
        elapsed < path.primary.duration ? path.primary.point(after: elapsed) : path.correction.point(after: elapsed - path.primary.duration)
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
