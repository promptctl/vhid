import Foundation
import Pointing

/// What steering a trajectory knows between ticks: where the cursor was last read, the
/// reports sent that it has not yet shown, and the acceleration curve learned from those it
/// has. Pure. `docs/design/human.md`, "Steering the path".
///
/// A report the cursor has not shown is distance already covered, not distance to send
/// again, so a tick aims from the cursor as read plus the expected motion of every report
/// still unseen. Sending it again would overshoot by a tick's worth and turn back mid-move.
struct Tracking: Equatable {
    /// One report the cursor has not shown yet. What it is expected to carry the cursor is
    /// asked of the curve as it stands, not as it stood when the report went out: an
    /// expectation kept from a curve since corrected matches the next change to the wrong
    /// reports, and that error compounds.
    struct Unseen: Equatable {
        let counts: Move
        /// The tick it went out on.
        let tick: Int
    }

    private(set) var cursor: ScreenPoint
    private(set) var unseen: [Unseen] = []
    /// Points per count by report length, each length's latest showing, ascending.
    ///
    /// **A curve, not one gain.** macOS carries a long report further per count than a
    /// short one, and a path that speeds up asks each tick for a longer report than the
    /// last. One gain, read off the last report, sends the next too far; the tick after
    /// reads a high gain off that and sends too little; and the swing grows rather than dies
    /// away - on a curve shaped like the measured one it carried the cursor 260 points off its
    /// path mid-move (`SteeringTheTrajectoryTests`). A report's length is answered from the
    /// lengths the cursor has shown, as `Steering`'s table is, so a longer one is asked
    /// at the gain longer ones have had. [LAW:one-source-of-truth] The interpolation is
    /// `Steering.perCount`.
    private(set) var curve: [Steering.Sample] = []

    /// How much longer than the longest report the cursor has shown the next may be. The
    /// curve is known only as far as reports have gone, and beyond that `Steering.perCount`
    /// holds the last length's gain, which for a longer report is too low and throws it
    /// long; so a report reaches at most this far past what is known, the error that costs
    /// is bounded, and the tick after has learned the new length. A path that speeds up
    /// asks for only a little more each tick, so this binds at the start and seldom after.
    static let growth = 2.0

    /// Ticks after which an unseen report is taken to have moved the cursor nowhere:
    /// `Pointer.settle`, the time the closed loop gives one report. [LAW:one-source-of-truth]
    static let patience = Int((Pointer.settle / Pointer.tick).rounded(.up))

    init(at cursor: ScreenPoint) { self.cursor = cursor }

    /// Points per count for a report `counts` long: `Pointer.Gain.assumed` before any report
    /// has shown, the curve between the lengths that have, and past the longest, the slope
    /// of the last two carried on.
    ///
    /// **Past the longest, too high rather than too low.** A gain too low there throws the
    /// report long, and it also misleads the next match: a change then looks like more of
    /// the unseen reports than it is, one still in flight is taken as landed, and the next
    /// aim sends its motion again - a swing that grew to hundreds of points with every report
    /// a tick late. Carrying the slope on is exact for a curve that rises in a line and too
    /// high for one that levels off, which only shortens a report.
    func perCount(_ counts: Double) -> Double {
        guard let last = curve.last else { return Pointer.Gain.assumed.perCount }
        let slope = curve.count > 1 ? max(0, (last.perCount - curve[curve.count - 2].perCount) / (last.counts - curve[curve.count - 2].counts)) : 0
        return counts > last.counts ? last.perCount + slope * (counts - last.counts) : Steering.perCount(counts, curve)
    }

    /// The cursor as read on `tick`.
    ///
    /// A change means at least one report landed, so it is matched to the oldest one or
    /// more unseen reports whose expected motion sums closest to it; those are seen, and
    /// their mean length takes the gain the change over their counts shows. The rest stay
    /// unseen, except those older than `patience`, which moved nothing.
    mutating func saw(_ read: ScreenPoint, on tick: Int) {
        let change = (x: read.x - cursor.x, y: read.y - cursor.y)
        let candidates = read == cursor || unseen.isEmpty ? 0 ... 0 : 1 ... unseen.count
        let covered = candidates.min { miss(unseen.prefix($0), change) < miss(unseen.prefix($1), change) } ?? 0
        let counts = unseen.prefix(covered).reduce((x: 0.0, y: 0.0)) { ($0.x + Double($1.counts.x.value), $0.y + Double($1.counts.y.value)) }
        let asked = hypot(counts.x, counts.y)
        let shown = asked > 0 ? [Steering.Sample(counts: max(1, (asked / Double(covered)).rounded()), perCount: hypot(change.x, change.y) / asked)] : []
        curve = (curve.filter { sample in !shown.contains { $0.counts == sample.counts } } + shown).sorted { $0.counts < $1.counts }
        unseen = unseen.dropFirst(covered).filter { tick - $0.tick <= Self.patience }
        cursor = read
    }

    /// How far the expected motion of `reports` is from `change`.
    private func miss(_ reports: ArraySlice<Unseen>, _ change: (x: Double, y: Double)) -> Double {
        let expected = carried(reports)
        return hypot(expected.x - change.x, expected.y - change.y)
    }

    /// Where the cursor will be once every unseen report has landed.
    var expected: (x: Double, y: Double) {
        let carried = carried(unseen[...])
        return (cursor.x + carried.x, cursor.y + carried.y)
    }

    /// How far `reports` are expected to carry the cursor, together.
    private func carried(_ reports: ArraySlice<Unseen>) -> (x: Double, y: Double) {
        reports.reduce((x: 0.0, y: 0.0)) {
            let gain = perCount(hypot(Double($1.counts.x.value), Double($1.counts.y.value)))
            return ($0.x + Double($1.counts.x.value) * gain, $0.y + Double($1.counts.y.value) * gain)
        }
    }

    /// The report that carries the cursor from where it is expected to be to `aim`: the
    /// length, in whole counts up to `growth` past the longest shown and a report's limit,
    /// the curve says comes nearest, toward `aim`. None when that is nearer than a count's reach, as a still mouse sends nothing;
    /// what one tick leaves over the next takes up.
    func report(toward aim: (x: Double, y: Double)) -> Move {
        let from = expected
        let (dx, dy) = (aim.x - from.x, aim.y - from.y)
        let distance = hypot(dx, dy)
        // One count past the doubling, because a report is whole counts on each axis: on a
        // diagonal, two counts' length rounds back to (1, 1), the length already known, and
        // the curve would never be learned past it.
        let longest = Int((curve.last?.counts ?? 0) * Self.growth) + 1
        let length = (0 ... min(longest, Int(Count.limit))).min { abs(reach($0) - distance) < abs(reach($1) - distance) } ?? 0
        let scale = distance > 0 ? Double(length) / distance : 0
        return Move(x: Count(clamping: Int((dx * scale).rounded())), y: Count(clamping: Int((dy * scale).rounded())))
    }

    /// Points a report `length` counts long is expected to carry the cursor.
    private func reach(_ length: Int) -> Double { Double(length) * perCount(Double(length)) }

    /// `report` went out on `tick`.
    mutating func sent(_ report: Move, on tick: Int) {
        unseen.append(Unseen(counts: report, tick: tick))
    }
}
