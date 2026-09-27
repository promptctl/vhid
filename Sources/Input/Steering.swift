import Foundation
import Pointing

/// Points per count by report length, at one report interval: what macOS's acceleration
/// made of reports that size, measured, and the reports that carry the cursor a given
/// distance without reading it back.
///
/// Recorded `at` lines come every few milliseconds, faster than a report is seen to land,
/// so the player cannot learn from the cursor between them the way `Pointer.move(to:)`
/// does: a read taken before the last report landed would send the same motion twice.
/// This is learned once instead, before the clock starts, and between clicks the cursor
/// goes where the table says. Error can build up; the closed loop before every button
/// line takes it out where it matters. `docs/design/replay.md`, "Replaying at lines".
///
/// [LAW:parse-dont-validate] A `Steering` that exists has at least one sample and every
/// sample moved the cursor, so there is always a gain to divide by.
public struct Steering: Hashable, Sendable {
    /// Ascending by `counts`.
    public let samples: [Sample]
    /// Points a report of each length from 0 through 127 counts is expected to carry the
    /// cursor, worked out once: the table is fixed, and it is read on every at line.
    private let covers: [Double]

    public struct Sample: Hashable, Sendable {
        /// The report's length, in counts.
        public let counts: Double
        /// Points the cursor moved per count, at that length.
        public let perCount: Double

        public init(counts: Double, perCount: Double) {
            self.counts = counts
            self.perCount = perCount
        }
    }

    /// The samples that moved the cursor, or `Unmoved` when none did: a cursor pinned in
    /// place steers nowhere, and a table of zeros would ask for infinite counts.
    public init(_ samples: [Sample]) throws {
        let moved = samples.filter { $0.perCount > 0 }.sorted { $0.counts < $1.counts }
        guard !moved.isEmpty else { throw Unmoved(reports: samples.count) }
        self.samples = moved
        covers = (0...Int(Count.limit)).map { Double($0) * Self.perCount(Double($0), moved) }
    }

    /// No report of the calibration moved the cursor.
    public struct Unmoved: Error, CustomStringConvertible {
        public let reports: Int
        public var description: String { "the cursor did not move for any of \(reports) calibration report sizes, so at lines cannot be steered" }
    }

    /// Points per count for a report `counts` long: straight lines between the samples,
    /// and the nearest sample's value beyond them.
    public func perCount(_ counts: Double) -> Double { Self.perCount(counts, samples) }

    private static func perCount(_ counts: Double, _ samples: [Sample]) -> Double {
        guard counts > samples[0].counts else { return samples[0].perCount }
        for (low, high) in zip(samples, samples.dropFirst()) where counts <= high.counts {
            return low.perCount + (high.perCount - low.perCount) * (counts - low.counts) / (high.counts - low.counts)
        }
        return samples[samples.count - 1].perCount
    }

    /// The reports that carry the cursor from `from` to `to`, and where they are expected to
    /// leave it. One report when the distance fits in one, and otherwise as many as it
    /// takes, each as long as a report carries. What no whole count covers is left over
    /// in the expected point, so the next line's reports make it up rather than lose it.
    public func reports(from: ScreenPoint, to: ScreenPoint) -> (reports: [Move], lands: ScreenPoint) {
        var at = (x: from.x, y: from.y)
        var reports: [Move] = []
        while true {
            let (move, counts, moved) = report(dx: to.x - at.x, dy: to.y - at.y)
            guard move != .none else { break }
            reports.append(move)
            at = (at.x + moved.x, at.y + moved.y)
            // The longest report there is, in any direction, and still short: another.
            guard counts == Int(Count.limit) else { break }
        }
        return (reports, ScreenPoint(x: at.x, y: at.y) ?? from)
    }

    /// The one report whose expected motion comes nearest `dx, dy`, its length in counts,
    /// and that motion.
    private func report(dx: Double, dy: Double) -> (Move, Int, (x: Double, y: Double)) {
        let distance = hypot(dx, dy)
        guard distance > 0 else { return (.none, 0, (0, 0)) }
        let counts = covers.indices.min { abs(covers[$0] - distance) < abs(covers[$1] - distance) } ?? 0
        let move = Move(x: Count(clamping: Int((dx / distance * Double(counts)).rounded())),
                        y: Count(clamping: Int((dy / distance * Double(counts)).rounded())))
        let gain = perCount(hypot(Double(move.x.value), Double(move.y.value)))
        return (move, counts, (Double(move.x.value) * gain, Double(move.y.value) * gain))
    }
}

extension Pointer {
    /// The report lengths calibration measures, shortest first, stopping at the first
    /// that covers the longest step the script asks for.
    static let ladder = [1, 2, 4, 8, 16, 32, 64, Int(Count.limit)]
    /// Reports in the longer of each length's two runs. The first report of a run comes
    /// after a pause and is accelerated as a slow one, so a run of one is measured too and
    /// taken away: what is left is what the reports at the script's own pace did.
    static let burst = 3

    /// Measures what reports of each length do at `interval` apart, each burst starting
    /// from `start` and heading for `toward`, which is a point the script visits, so the
    /// cursor stays where the recording went.
    ///
    /// The clock paces the bursts and the wait after them, so a test runs it on a clock of
    /// its own. [LAW:effects-at-boundaries]
    func calibrate<C: Clock>(_ calibration: Schedule.Calibration, from start: ScreenPoint, clock: C) async throws -> Steering where C.Duration == Duration {
        let away = hypot(calibration.toward.x - start.x, calibration.toward.y - start.y)
        let unit = away > 0 ? ((calibration.toward.x - start.x) / away, (calibration.toward.y - start.y) / away) : (1.0, 0.0)
        var samples: [Steering.Sample] = []
        for size in Self.ladder {
            let step = Move(x: Count(clamping: Int((unit.0 * Double(size)).rounded())), y: Count(clamping: Int((unit.1 * Double(size)).rounded())))
            let long = try await run(step, times: Self.burst, from: start, every: calibration.interval, clock: clock)
            let short = try await run(step, times: 1, from: start, every: calibration.interval, clock: clock)
            // The screen is only known to go as far as the recording went. A burst carried
            // past its farthest point may have been stopped at a screen edge and measured
            // short, so it is not taken, and nothing longer is tried: the table holds the
            // last length it trusts for every longer report. The shortest is always taken,
            // since a table needs one sample.
            guard long < away || samples.isEmpty else { break }
            let counts = hypot(Double(step.x.value), Double(step.y.value))
            let sample = Steering.Sample(counts: counts, perCount: (long - short) / (counts * Double(Self.burst - 1)))
            samples.append(sample)
            if sample.counts * sample.perCount >= calibration.reach { break }
        }
        return try Steering(samples)
    }

    /// How far `times` reports of `step`, `every` apart from `start`, carried the cursor.
    private func run<C: Clock>(_ step: Move, times: Int, from start: ScreenPoint, every interval: Duration, clock: C) async throws -> Double where C.Duration == Duration {
        try await move(to: start)
        let before = try cursor()
        for _ in 0..<times {
            try Task.checkCancellation()
            try await mouse.move(by: step)
            try await clock.sleep(until: clock.now.advanced(by: interval), tolerance: .zero)
        }
        try await clock.sleep(until: clock.now.advanced(by: Self.settle), tolerance: .zero)
        let after = try cursor()
        return hypot(after.x - before.x, after.y - before.y)
    }
}
