import Foundation
import Pointing

/// Where a person's aimed pointer movement is, moment by moment, from one point to another:
/// a main movement that lands on the target, stops short, or overshoots, then as many
/// corrections onto it as its structure has, each slowing down for longer than it speeds
/// up, the main one bowing the way the forearm swings, and a faint tremor over the whole.
/// Pure: every draw is taken when it is made. `docs/design/human.md`, "The path".
public struct Trajectory: Sendable, Equatable {
    public let start: ScreenPoint
    /// The point drawn inside the target it was aimed at, where it ends.
    public let target: ScreenPoint
    /// The point or box it was aimed at, whose width its time was read off by Fitts' law.
    public let toward: Target
    /// How long the whole movement takes, by Fitts' law and a drawn pace.
    public let duration: Duration
    /// How much of each drawn deviation from the straight line the path kept to stay on the
    /// displays.
    public let kept: Kept
    /// Which corrections follow the main movement.
    public let structure: Structure
    /// The movements in order, with when each begins.
    private let chain: Chain
    /// The sideways shake laid over them, always whole.
    public let tremor: Tremor

    /// The movements in order, the main one first and the last ending on the target.
    public var strokes: [Submovement] { chain.strokes }

    /// How much of a drawn deviation a path kept to stay on the displays, one for all of it
    /// and zero for none, for each of the two it keeps apart: where its movements end off the
    /// straight line, which near an edge it is approached toward is the overshoot, and the
    /// bow, which near an edge it runs along is the curve. Kept apart, the one that would
    /// carry the path into an edge is cut without taking the other with it.
    public struct Kept: Sendable, Equatable {
        /// Of where its movements end past the target and beside the line.
        public let ends: Double
        /// Of the main movement's bow.
        public let bow: Double
    }

    /// Fitts' law, MT = a + b × log2(D/W + 1), with the constants of the human-like
    /// generator in Choudhary et al. W is the target's: `Target.width`.
    static let intercept: Duration = .milliseconds(50)
    static let slope: Duration = .milliseconds(150)
    /// What MT is multiplied by, so two moves of one distance do not take one time.
    static let pace = Normal(1, 0.15, within: 0.7 ... 1.3)
    /// How far short of the target a main movement that undershoots ends, as a fraction of D.
    static let short = Normal(0.05, 0.03, within: 0.01 ... 0.10)
    /// How far past it one that overshoots ends, as a fraction of D.
    static let over = Normal(0.04, 0.02, within: 0.01 ... 0.08)
    /// How much of the main movement's miss a first correction that also misses leaves, on
    /// a side drawn as a coin.
    static let miss = Normal(0.45, 0.15, within: 0.25 ... 0.80)
    /// How far off the line a movement that does not end on the target ends, as a fraction of D.
    static let offLine = Normal(0, 0.02, within: -0.04 ... 0.04)
    /// How far the main movement bows at its middle, as a fraction of D, before it is scaled
    /// by how much of the stroke lies across the forearm.
    static let bow = Normal(0.03, 0.01, within: 0.01 ... 0.06)
    /// The forearm, from the hand toward the elbow, as a unit vector in screen space, y
    /// down: 30° right of straight down, a right hand's on a mouse beside a keyboard.
    static let forearm = (x: sin(Double.pi / 6), y: cos(Double.pi / 6))

    /// How near the displays' edges a deviation may carry the path, in points, where the
    /// straight line keeps further off: a button's height of room. The steering follows the
    /// path to within a few points, so the cursor stays clear of an edge it does not mean to
    /// touch.
    static let margin = Target.button
    /// The shares of a drawn deviation tried, most first, until one keeps the path on the
    /// displays. The last, none of it, always does: it leaves the path as it was without it.
    static let shares = (0 ... 10).reversed().map { Double($0) / 10 }
    /// How many evenly spaced moments of the movement are checked against the displays:
    /// a few milliseconds apart on the longest move, closer than the steering's ticks.
    static let checks = 256

    /// How a movement is built: whether its main movement lands on the target, and how many
    /// corrections take it the rest of the way. `docs/design/human.md`, "The path".
    public enum Structure: String, Sendable, CaseIterable {
        case direct, undershoot, overshoot
        case twoCorrections = "two_corrections"

        /// The share of moves built this way: the last has what the others leave, so the
        /// shares sum to one however the others are set.
        var share: Double {
            switch self {
            case .direct: 0.25
            case .undershoot: 0.45
            case .overshoot: 0.15
            case .twoCorrections: 1 - Self.allCases.dropLast().map(\.share).reduce(0, +)
            }
        }

        /// One drawn as their shares have it: a pick past every other share is the last's.
        static func draw(using generator: inout some RandomNumberGenerator) -> Structure {
            let pick = Double.random(in: 0 ..< 1, using: &generator)
            var below = 0.0
            return allCases.dropLast().first { below += $0.share; return pick < below } ?? .twoCorrections
        }

        /// Where each movement ends, in space and in time: `past` the target along the line
        /// and `across` it, both as fractions of D, the second as a multiple of the drawn aim
        /// off the line; how much of the drawn bow it carries; and the share of MT gone when
        /// it ends. Measured from the target and up to the whole of MT, so the last movement,
        /// at zero, zero and one, ends on the target exactly and at the move's end exactly.
        /// [LAW:dataflow-not-control-flow] Every structure is one list of the same legs.
        func legs(short: Double, over: Double, miss: Double) -> [(past: Double, across: Double, bow: Double, until: Double)] {
            switch self {
            case .direct: [(0, 0, 1, 1)]
            case .undershoot: [(-short, 1, 1, 0.8), (0, 0, 0, 1)]
            case .overshoot: [(over, 1, 1, 0.8), (0, 0, 0, 1)]
            case .twoCorrections: [(-short, 1, 1, 0.7), (-miss * short, miss, 0, 0.88), (0, 0, 0, 1)]
            }
        }
    }

    /// A movement from `start` to a point aimed at inside `target` with every variable drawn
    /// from `generator`, in one fixed order whatever the distance or the structure, the aim
    /// first, so one seed always means one movement. A movement under a point long takes no
    /// time: the closing loop has it all.
    ///
    /// **The deviation is drawn whole and kept in part.** A path that bows or overshoots by
    /// a tenth of its length runs into the edge beside a target approached along it or
    /// toward it: an auto-hidden Dock rises and covers the target, a corner fires, and while
    /// the cursor is held at the edge the curve is learned from reports macOS clamped. So
    /// the path keeps the largest of `shares` of where its movements end off the line, then
    /// the largest of its bow, under which, at every check, it is no nearer an edge than the
    /// straight line is there, to within `margin`; a straight line between two points on one
    /// display is on it, and each share is a value rather than a branch, so a path far from
    /// every edge keeps it all. [LAW:dataflow-not-control-flow] The tremor is not checked
    /// and always whole: at most 1.6 points, under the few the steering follows the path to,
    /// it swings toward every edge it runs beside, and checking it would cut every other
    /// deviation with it.
    public init(from start: ScreenPoint, toward aimed: Target, within displays: Displays, drawing generator: inout some RandomNumberGenerator) {
        let target = aimed.aim(drawing: &generator)
        let pace = Self.pace.draw(using: &generator)
        let structure = Structure.draw(using: &generator)
        let (short, over) = (Self.short.draw(using: &generator), Self.over.draw(using: &generator))
        let miss = Self.miss.draw(using: &generator) * (Bool.random(using: &generator) ? 1 : -1)
        let (offLine, bowing) = (Self.offLine.draw(using: &generator), Self.bow.draw(using: &generator))
        let (dx, dy) = (target.x - start.x, target.y - start.y)
        let distance = hypot(dx, dy)
        let fitts = Self.intercept + Self.slope * log2(distance / aimed.width + 1)
        let duration = distance < 1 ? .zero : fitts * pace
        // Along the line toward the target, and across it, as unit vectors; the zero vector
        // for a movement of no length, which then has no aim to set off either way.
        let (along, across) = distance > 0 ? ((dx / distance, dy / distance), (-dy / distance, dx / distance)) : ((0, 0), (0, 0))
        // The bow away from the elbow, by the sine of the angle between the stroke and the
        // forearm: the stroke's component across the forearm, signed so that a positive one
        // bows toward `across` and the elbow is always on the inside of the arc.
        let bow = -bowing * distance * (along.0 * Self.forearm.y - along.1 * Self.forearm.x)
        let tremor = Tremor(across: across, drawing: &generator)
        let legs = structure.legs(short: short, over: over, miss: miss)
        func drawn(ends kept: Double, bow bowKept: Double) -> Chain {
            let ends: [Submovement.Point] = legs.map { leg in
                // Short of the target is on the straight line; past it is off it, kept as the aim beside it is.
                let past = (min(leg.past, 0) + max(leg.past, 0) * kept) * distance
                let off = leg.across * offLine * kept * distance
                return (target.x + along.0 * past + across.0 * off, target.y + along.1 * past + across.1 * off)
            }
            let froms = [(start.x, start.y)] + ends.dropLast()
            let begins = [0] + legs.dropLast().map(\.until)
            return Chain(zip(zip(froms, ends), zip(legs, begins)).map { stroke, timed in
                Submovement(from: stroke.0, to: stroke.1, bow: bow * timed.0.bow * bowKept, duration: duration * timed.0.until - duration * timed.1)
            })
        }
        let moments = (0 ... Self.checks).map { duration * (Double($0) / Double(Self.checks)) }
        let straight = drawn(ends: 0, bow: 0)
        let depths = moments.map { displays.depth(of: straight.point(after: $0), upTo: Self.margin) }
        // The largest share whose chain is no nearer an edge than the straight line, and that
        // chain. One is always found, at none if not before: the ends kept at none are the
        // straight line itself, and the bow kept at none is the chain whose ends were kept.
        func largest(_ keeping: @escaping (Double) -> Chain) -> (share: Double, chain: Chain) {
            Self.shares.lazy.map { ($0, keeping($0)) }.first { _, kept in
                zip(moments, depths).allSatisfy { moment, depth in depth.map { displays.covers(kept.point(after: moment), by: $0) } ?? true }
            }!
        }
        let ends = largest { drawn(ends: $0, bow: 0) }.share
        let (bowKept, chosen) = largest { drawn(ends: ends, bow: $0) }
        self.start = start
        self.target = target
        toward = aimed
        self.duration = duration
        kept = Kept(ends: ends, bow: bowKept)
        self.structure = structure
        self.chain = chosen
        self.tremor = tremor
    }

    /// Where the movement is `elapsed` after it began: the target from `duration` on.
    public func point(after elapsed: Duration) -> (x: Double, y: Double) {
        let (point, shake) = (unshaken(after: elapsed), tremor.offset(after: elapsed, lasting: duration))
        return (point.x + shake.x, point.y + shake.y)
    }

    /// Where the strokes alone put it `elapsed` after it began, without the tremor.
    func unshaken(after elapsed: Duration) -> Submovement.Point {
        chain.point(after: elapsed)
    }

    /// The strokes in order and when each begins, summed once rather than on every read.
    private struct Chain: Sendable, Equatable {
        let strokes: [Submovement]
        let begins: [Duration]

        init(_ strokes: [Submovement]) {
            self.strokes = strokes
            begins = strokes.dropLast().reduce(into: [.zero]) { $0.append($0.last! + $1.duration) }
        }

        /// Where the stroke under way at `elapsed`, the last one that has begun, is.
        func point(after elapsed: Duration) -> Submovement.Point {
            let under = begins.lastIndex { $0 <= elapsed } ?? 0
            return strokes[under].point(after: elapsed - begins[under])
        }
    }
}

/// One submovement: a stroke from one point to another on the minimum-jerk curve with its
/// time warped so it slows down for longer than it speeds up, bowing to one side by `bow`
/// points at its middle, along (−dy, dx) of its direction when positive and the other way
/// when negative.
public struct Submovement: Sendable, Equatable {
    public let from: Point
    public let to: Point
    public let bow: Double
    public let duration: Duration

    public typealias Point = (x: Double, y: Double)

    /// The fraction of its time at which a stroke has covered half its distance.
    static let halfway = 0.45
    /// The warp τ = t^k that puts the minimum-jerk curve's middle at `halfway`.
    static let warp = log(0.5) / log(halfway)

    public static func == (a: Submovement, b: Submovement) -> Bool {
        a.from == b.from && a.to == b.to && a.bow == b.bow && a.duration == b.duration
    }

    /// The fraction of the distance covered at fraction `t` of the stroke's time: the
    /// minimum-jerk curve 10τ³ − 15τ⁴ + 6τ⁵ (Flash and Hogan) at τ = t^`warp`. Its speed
    /// rises and falls once, peaking at 43% of the time rather than the middle.
    static func covered(_ t: Double) -> Double {
        let tau = pow(t, warp)
        return tau * tau * tau * (10 - 15 * tau + 6 * tau * tau)
    }

    /// Where the stroke is `elapsed` after it began: `to` from `duration` on, and `to` for
    /// a stroke that takes no time. Measured back from `to`, so the end is exact.
    func point(after elapsed: Duration) -> Point {
        let t = duration > .zero ? min(1, max(0, elapsed / duration)) : 1
        let u = Self.covered(t)
        let (dx, dy) = (to.x - from.x, to.y - from.y)
        let length = hypot(dx, dy)
        let off = length > 0 ? bow * sin(.pi * u) / length : 0
        return (to.x - dx * (1 - u) - dy * off, to.y - dy * (1 - u) + dx * off)
    }
}

/// A hand's physiological tremor, as a sideways wobble across the line of the move: a sine
/// of drawn amplitude, frequency and phase, faded in at the start and out at the end so the
/// path begins where the cursor is and ends on the target. `docs/design/human.md`, "A faint
/// tremor".
public struct Tremor: Sendable, Equatable {
    /// Points either side of the path at its widest.
    public let amplitude: Double
    /// Hertz.
    public let frequency: Double
    /// Radians at the start of the move.
    public let phase: Double
    /// The unit vector across the line of the move it wobbles along.
    public let across: Submovement.Point

    static let amplitudes = Normal(1, 0.3, within: 0.4 ... 1.6)
    static let frequencies = Normal(10, 1.5, within: 7 ... 13)
    /// How long it takes to fade in at the start and out at the end.
    static let fade: Duration = .milliseconds(80)

    /// One across the line `across`, its amplitude, frequency and phase drawn in that order.
    init(across: Submovement.Point, drawing generator: inout some RandomNumberGenerator) {
        amplitude = Tremor.amplitudes.draw(using: &generator)
        frequency = Tremor.frequencies.draw(using: &generator)
        phase = Double.random(in: 0 ..< 2 * .pi, using: &generator)
        self.across = across
    }

    public static func == (a: Tremor, b: Tremor) -> Bool {
        a.amplitude == b.amplitude && a.frequency == b.frequency && a.phase == b.phase && a.across == b.across
    }

    /// How far off the strokes the hand is `elapsed` into a move `lasting` this long: none
    /// at either end, nor after it.
    func offset(after elapsed: Duration, lasting duration: Duration) -> Submovement.Point {
        let fade = max(0, min(1, elapsed / Self.fade, (duration - elapsed) / Self.fade))
        let size = amplitude * fade * sin(2 * .pi * frequency * (elapsed / .seconds(1)) + phase)
        return (across.x * size, across.y * size)
    }
}
