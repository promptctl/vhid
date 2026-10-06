import Foundation
import Synchronization

/// SplitMix64: a seeded random number generator, so a run drawn from one seed can be drawn
/// again exactly. The verbs seed it from the system and record the seed; a test passes a
/// fixed one. `docs/design/human.md`, "The decisions".
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A normal distribution truncated to `bounds`: a draw outside them is drawn again, never
/// clamped, because clamping piles identical values at each bound - the uniform timing the
/// human model exists to remove.
///
/// [LAW:parse-dont-validate] `bounds` holds the mean, so at least half the distribution's
/// mass is inside and the redraw ends.
public struct Normal: Sendable, Equatable {
    public let mean: Double
    public let deviation: Double
    public let bounds: ClosedRange<Double>

    public init(_ mean: Double, _ deviation: Double, within bounds: ClosedRange<Double>) {
        precondition(bounds.contains(mean), "a truncated normal's bounds hold its mean")
        self.mean = mean
        self.deviation = deviation
        self.bounds = bounds
    }

    /// One draw, by the Box-Muller transform, redrawn until it is inside the bounds.
    public func draw(using generator: inout some RandomNumberGenerator) -> Double {
        while true {
            let u1 = 1 - Double.random(in: 0 ..< 1, using: &generator)
            let u2 = Double.random(in: 0 ..< 1, using: &generator)
            let drawn = mean + deviation * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            if bounds.contains(drawn) { return drawn }
        }
    }
}

/// The one seeded generator a pointer's moves draw from, in the order they are made.
///
/// [LAW:no-shared-mutable-globals] The generator advances with every draw, so it has one
/// owner - this - and is reached only through `draw`.
public final class RandomSource: Sendable {
    /// What the generator was seeded with, which is what reproduces a run.
    public let seed: UInt64
    private let generator: Mutex<SeededGenerator>

    public init(seed: UInt64) {
        self.seed = seed
        generator = Mutex(SeededGenerator(seed: seed))
    }

    /// Whatever `body` draws, drawn from this source's generator.
    public func draw<T>(_ body: (inout SeededGenerator) -> T) -> T {
        generator.withLock { body(&$0) }
    }
}
