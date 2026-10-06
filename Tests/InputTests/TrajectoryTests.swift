import Foundation
import OwnThread
import Pointing
import Synchronization
import TestClock
import Testing
@testable import Input

/// The trajectory model of `docs/design/human.md`, on fixed seeds: how long a move takes,
/// the shape of its path, and the draws behind both.
@Suite struct TrajectoryTests {
    static let start = ScreenPoint(x: 100, y: 300)!
    static let across = ScreenPoint(x: 840, y: 300)!

    static func trajectory(seed: UInt64, from start: ScreenPoint = start, to target: ScreenPoint = across) -> Trajectory {
        var generator = SeededGenerator(seed: seed)
        return Trajectory(from: start, to: target, within: .vast, drawing: &generator)
    }

    /// MT = 50 ms + 150 ms × log2(D/20 + 1), times the pace drawn first: about 0.84 s
    /// across 740 points before the pace.
    @Test func aMoveTakesFittsTimeTimesItsDrawnPace() {
        var generator = SeededGenerator(seed: 7)
        let pace = Trajectory.pace.draw(using: &generator)
        let fitts = Duration.milliseconds(50) + .milliseconds(150) * log2(740.0 / 20 + 1)
        #expect(Self.trajectory(seed: 7).duration == fitts * pace)
        #expect(abs(fitts / .milliseconds(1) - 837.2) < 0.1)
    }

    /// The pace is cut to 0.7–1.3, and two seeds give two times for one distance.
    @Test func thePaceVariesWithinItsBounds() {
        let fitts = Duration.milliseconds(50) + .milliseconds(150) * log2(740.0 / 20 + 1)
        let paces = (0 ..< 500).map { Self.trajectory(seed: $0).duration / fitts }
        #expect(paces.allSatisfy { (0.7 ... 1.3).contains($0) })
        #expect(Set(paces).count == paces.count)
    }

    /// A move under a point long takes no time: it is all the closing loop's.
    @Test func aMoveUnderAPointTakesNoTime() {
        let near = Self.trajectory(seed: 1, to: ScreenPoint(x: 100.8, y: 300.4)!)
        #expect(near.duration == .zero)
        #expect(near.point(after: .zero) == (100.8, 300.4))
        #expect(Self.trajectory(seed: 1, to: Self.start).duration == .zero)
    }

    /// The primary submovement ends short of the target by 1–10% of D and within 4% of D
    /// of the line; the correction ends on the target exactly. Over 500 seeds.
    @Test func thePrimaryStopsShortAndTheCorrectionLands() {
        for seed in UInt64(0) ..< 500 {
            let path = Self.trajectory(seed: seed)
            let aim = path.point(after: path.primary.duration)
            #expect((840 - 74.0 ... 840 - 7.4).contains(aim.x), "seed \(seed): \(aim)")
            #expect(abs(aim.y - 300) <= 29.6, "seed \(seed): \(aim)")
            #expect(path.point(after: path.duration) == (840, 300))
            #expect(path.primary.duration == path.duration * 0.8)
        }
    }

    /// The path leaves the line by at most the bow and the aim's offset together, 10% of D,
    /// and does bow: over 500 seeds some leave it by more than 2% of D on either side.
    @Test func thePathBowsWithinItsBounds() {
        var widest = (above: 0.0, below: 0.0)
        for seed in UInt64(0) ..< 500 {
            let path = Self.trajectory(seed: seed)
            for ms in stride(from: 0, through: Int(path.duration / .milliseconds(1)), by: 4) {
                let off = path.point(after: .milliseconds(ms)).y - 300
                #expect(abs(off) <= 74, "seed \(seed) at \(ms) ms: \(off)")
                widest = (max(widest.above, -off), max(widest.below, off))
            }
        }
        #expect(widest.above > 14.8 && widest.below > 14.8)
    }

    /// Speed rises and falls once in each submovement, the bell of a minimum-jerk
    /// movement: step lengths 8 ms apart climb to one peak and then only fall.
    @Test func speedRisesThenFallsInEachSubmovement() {
        let path = Self.trajectory(seed: 3)
        for stroke in [path.primary, path.correction] {
            let ticks = Int(stroke.duration / Pointer.tick)
            let points = (0 ... ticks).map { stroke.point(after: Pointer.tick * $0) }
            let steps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            let peak = steps.indices.max { steps[$0] < steps[$1] }!
            #expect(peak > 0 && peak < steps.count - 1)
            #expect(zip(steps[..<peak], steps[1 ... peak]).allSatisfy { $0 <= $1 })
            #expect(zip(steps[peak...], steps[(peak + 1)...]).allSatisfy { $0 >= $1 })
        }
    }

    /// One seed, one movement.
    @Test func oneSeedDrawsOneMovement() {
        #expect(Self.trajectory(seed: 42) == Self.trajectory(seed: 42))
        #expect(Self.trajectory(seed: 42) != Self.trajectory(seed: 43))
    }

    /// A truncated normal is redrawn, never clamped: nothing lands on a bound, and the
    /// draws keep the distribution's mean.
    @Test func aTruncatedNormalRedrawsRatherThanClamps() {
        var generator = SeededGenerator(seed: 9)
        let normal = Normal(250, 80, within: 120 ... 500)
        let draws = (0 ..< 10_000).map { _ in normal.draw(using: &generator) }
        #expect(draws.allSatisfy { $0 > 120 && $0 < 500 })
        #expect(abs(draws.reduce(0, +) / Double(draws.count) - 260) < 5)
    }
}

/// A trajectory kept on the displays: beside an edge it never runs nearer the edge than the
/// straight line does, and away from every edge it keeps its whole bow. Over 500 seeds each,
/// seconds of work that would hold `make test`'s one-thread pool, hence its own thread.
@Suite(.ownThread) struct TrajectoryOnTheDisplaysTests {
    static let screen = Displays(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])!
    /// Ten points above the bottom edge, where an auto-hidden Dock waits, and across it.
    static let alongTheEdge = (ScreenPoint(x: 100, y: 1070)!, ScreenPoint(x: 1800, y: 1070)!)

    static func trajectory(seed: UInt64, from start: ScreenPoint, to target: ScreenPoint, within displays: Displays = screen) -> Trajectory {
        var generator = SeededGenerator(seed: seed)
        return Trajectory(from: start, to: target, within: displays, drawing: &generator)
    }

    /// Every millisecond of every path along the bottom edge is on the screen and no lower
    /// than the line it was drawn about, to the few hundredths `Displays.depth` finds; and the paths still differ, some bowing up and away
    /// with all their curve kept.
    @Test func aPathAlongAnEdgeNeverRunsIntoIt() {
        var kept: [Double] = []
        var highest = 1070.0
        for seed in UInt64(0) ..< 500 {
            let path = Self.trajectory(seed: seed, from: Self.alongTheEdge.0, to: Self.alongTheEdge.1)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let point = path.point(after: .milliseconds(ms))
                #expect(point.y <= 1070.05, "seed \(seed) at \(ms) ms: \(point)")
                #expect(Self.screen.covers(point, by: 0), "seed \(seed) at \(ms) ms: \(point)")
                highest = min(highest, point.y)
            }
            kept.append(path.kept)
        }
        #expect(kept.contains(1) && kept.contains { $0 < 1 })
        #expect(highest < 1070 - 50)
    }

    /// A path the drawn bow would carry into a corner keeps less of it and is still on the
    /// screen: a target ten points from both edges, approached along the diagonal.
    @Test func aPathIntoACornerStaysOffIt() {
        var kept: [Double] = []
        for seed in UInt64(0) ..< 500 {
            let path = Self.trajectory(seed: seed, from: ScreenPoint(x: 900, y: 500)!, to: ScreenPoint(x: 1910, y: 1070)!)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let point = path.point(after: .milliseconds(ms))
                #expect(point.x <= 1910.05 && point.y <= 1070.05, "seed \(seed) at \(ms) ms: \(point)")
                #expect(Self.screen.covers(point, by: 0), "seed \(seed) at \(ms) ms: \(point)")
            }
            kept.append(path.kept)
        }
        #expect(kept.contains { $0 < 1 })
    }

    /// Far from every edge, and across the seam between two displays side by side, the whole
    /// drawn path is kept: the same path as on a screen with no edges near.
    @Test func aPathFarFromTheEdgesKeepsItsWholeBow() {
        let pair = Displays(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1920, height: 1080)])!
        for seed in UInt64(0) ..< 500 {
            let across = Self.trajectory(seed: seed, from: TrajectoryTests.start, to: TrajectoryTests.across)
            #expect(across == TrajectoryTests.trajectory(seed: seed), "seed \(seed)")
            #expect(across.kept == 1)
            let seam = Self.trajectory(seed: seed, from: ScreenPoint(x: 1000, y: 540)!, to: ScreenPoint(x: 2800, y: 540)!, within: pair)
            #expect(seam.kept == 1, "seed \(seed)")
        }
    }

    /// Steered by the pointer on a curved mouse, along the bottom edge: the cursor never comes
    /// within a few points of the edge, and the move still lands on its target.
    @Test(arguments: 1 ... 20)
    func aSteeredMoveAlongTheEdgeNeverReachesIt(seed: UInt64) async throws {
        let (start, target) = Self.alongTheEdge
        let mouse = CurvedMouse(at: start, lateEvery: 0)
        let trace = SteeringTheTrajectoryTests.Trace(), clock = ManualClock()
        let pointer = Pointer(mouse: mouse, cursor: { trace.read(mouse.cursor(), at: clock.now.offset) }, displays: { Self.screen },
                              clock: clock, randomness: RandomSource(seed: seed), hand: .macOSDefault, traced: { _ in })
        try await pointer.move(to: target)
        #expect(trace.all.allSatisfy { $0.point.y < 1075 }, "lowest \(trace.all.map(\.point.y).max()!)")
        #expect(abs(mouse.position.x - target.x) <= 0.5 && abs(mouse.position.y - target.y) <= 0.5)
    }
}

/// The trajectory steered on a fake screen with a fake curve: each tick's report, the
/// cursor following the path, and the landing `home` guarantees.
@Suite @MainActor struct SteeringTheTrajectoryTests {
    /// Every read of the cursor and when it was made.
    final class Trace: Sendable {
        private let reads = Mutex<[(at: Duration, point: ScreenPoint)]>([])
        var all: [(at: Duration, point: ScreenPoint)] { reads.withLock { $0 } }
        func read(_ point: ScreenPoint, at: Duration) -> ScreenPoint {
            reads.withLock { $0.append((at, point)) }
            return point
        }
    }

    static let start = ScreenPoint(x: 100, y: 300)!
    static let target = ScreenPoint(x: 840.4, y: 300)!
    /// Moves to steer: across the screen, back, up a diagonal, and a short hop.
    static let moves = [(start, target), (target, start), (ScreenPoint(x: 900, y: 700)!, ScreenPoint(x: 300.5, y: 120)!), (start, ScreenPoint(x: 160, y: 330)!)]

    /// One move of `moves` on `seed`, over a curved mouse whose cursor shows every report
    /// in time: what the move answered, the trajectory it was drawn, the cursor as each
    /// steered tick read it, and where the cursor ended.
    static func steer(seed: UInt64, move: Int) async throws -> (moved: Pointer.Moved, path: Trajectory, reads: [(at: Duration, point: ScreenPoint)], end: ScreenPoint, took: Duration) {
        let (start, target) = moves[move]
        let mouse = CurvedMouse(at: start, lateEvery: 0)
        let clock = ManualClock(), trace = Trace()
        let pointer = Pointer(mouse: mouse, cursor: { trace.read(mouse.cursor(), at: clock.now.offset) }, displays: { .vast }, clock: clock, randomness: RandomSource(seed: seed), hand: .macOSDefault, traced: { _ in })
        let moved = try await pointer.move(to: target)
        let path = TrajectoryTests.trajectory(seed: seed, from: start, to: target)
        let ticks = Int((path.duration / Pointer.tick).rounded(.up))
        return (moved, path, Array(trace.all.dropFirst().prefix(ticks)), mouse.position, clock.now.offset)
    }

    /// On ten seeds and four moves: a report at most every tick for the trajectory's time,
    /// the cursor within a few points of where the trajectory was a tick before each read,
    /// no report jumping more than a tick's worth, and the closing loop landing it within
    /// half a point, its reports a tick apart.
    @Test(arguments: 1 ... 10, 0 ..< 4)
    func aMoveFollowsItsTrajectoryAndLands(seed: UInt64, move: Int) async throws {
        let (moved, path, reads, end, took) = try await Self.steer(seed: seed, move: move)
        let (start, target) = Self.moves[move]
        let ticks = Int((path.duration / Pointer.tick).rounded(.up))
        #expect(moved.planned == path.duration)
        #expect(moved.steered > 0 && moved.steered <= ticks)
        #expect(abs(end.x - target.x) <= 0.5 && abs(end.y - target.y) <= 0.5)
        #expect(took == Pointer.tick * (ticks + moved.closing))
        for read in reads {
            let due = path.point(after: read.at - Pointer.tick)
            #expect(hypot(read.point.x - due.x, read.point.y - due.y) < 6, "at \(read.at): \(read.point) against \(due)")
        }
        let points = [start] + reads.map(\.point)
        #expect(zip(points, points.dropFirst()).allSatisfy { hypot($1.x - $0.x, $1.y - $0.y) < 40 })
    }

    /// Over the long moves, where a tick carries many counts: every tick reports but the
    /// first few, whose share of a minimum-jerk start is under half a count, and the cursor
    /// is slow at both ends and fast in the middle. A short hop moves a point or two a tick,
    /// where whole counts decide the step lengths; its bell is `TrajectoryTests`'.
    @Test(arguments: 1 ... 10, 0 ..< 3)
    func aLongMoveSpeedsUpAndSlowsDown(seed: UInt64, move: Int) async throws {
        let (moved, path, reads, _, _) = try await Self.steer(seed: seed, move: move)
        let ticks = Int((path.duration / Pointer.tick).rounded(.up))
        #expect(moved.steered >= ticks - 8)
        let points = [Self.moves[move].0] + reads.map(\.point)
        let steps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let third = steps.count / 3
        let middle = steps[third ..< 2 * third].max()!
        #expect(steps.prefix(3).allSatisfy { $0 < middle / 3 })
        #expect(steps.suffix(3).allSatisfy { $0 < middle / 3 })
    }

    /// A cursor that shows one report in four a tick late: what has been sent and not shown
    /// is counted as covered, so the cursor never goes past the target and turns back, and
    /// the move still lands.
    @Test(arguments: 1 ... 10)
    func reportsTheCursorHasNotShownAreNotSentAgain(seed: UInt64) async throws {
        let mouse = CurvedMouse(at: Self.start, lateEvery: 4)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, displays: { .vast }, clock: ManualClock(), randomness: RandomSource(seed: seed), hand: .macOSDefault, traced: { _ in })
        _ = try await pointer.move(to: Self.target)
        #expect(mouse.farthest <= Self.target.x + 3, "went to \(mouse.farthest)")
        #expect(abs(mouse.position.x - Self.target.x) <= 0.5 && abs(mouse.position.y - Self.target.y) <= 0.5)
    }

    /// On `FakeMouse`'s step curve, which no Mac has, the steering is thrown about, and the
    /// closing loop still lands the move.
    @Test func aMoveLandsEvenOnACurveWithAStep() async throws {
        let mouse = FakeMouse(at: Self.start)
        _ = try await mouse.pointer.move(to: Self.target)
        #expect(abs(mouse.position.x - Self.target.x) <= 0.5 && abs(mouse.position.y - Self.target.y) <= 0.5)
    }

    /// Every move is handed to `traced` in order, as the verb that made it answered it: a
    /// drag's approach and then its carry.
    @Test func everyMoveIsTraced() async throws {
        final class Traced: Sendable { let moves = Mutex<[Pointer.Moved]>([]) }
        let mouse = CurvedMouse(at: Self.start, lateEvery: 0), traced = Traced()
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, displays: { .vast }, clock: ManualClock(), randomness: RandomSource(seed: 1),
                              hand: .macOSDefault, traced: { if case .moved(let move) = $0 { traced.moves.withLock { $0.append(move) } } })
        let drag = try await pointer.drag(from: Self.target, to: Self.start, button: .left)
        #expect(traced.moves.withLock { $0 } == [drag.approach, drag.carry])
        #expect(drag.approach.steered > 0 && drag.carry.steered > 0)
        #expect(drag.approach.lost == 0 && drag.carry.lost == 0)
    }

    /// A cursor that will not move is still `WouldNotReach`, from the closing loop.
    /// It counts every report the move sent, the steered ones too, as the move's trace does.
    @Test func aPinnedCursorIsStillWouldNotReach() async throws {
        final class Traced: Sendable { let moves = Mutex<[Pointer.Moved]>([]) }
        let mouse = FakeMouse(at: Self.start), traced = Traced()
        mouse.stuck = true
        let pointer = Pointer(mouse: mouse, cursor: mouse.cursor, displays: { .vast }, clock: ManualClock(), randomness: RandomSource(seed: 1),
                              hand: .macOSDefault, traced: { if case .moved(let move) = $0 { traced.moves.withLock { $0.append(move) } } })
        let stop = try await #require(throws: WouldNotReach.self) { try await pointer.move(to: Self.target) }
        let moved = try #require(traced.moves.withLock { $0.first })
        #expect(moved.steered > 0)
        #expect(stop.reports == moved.reports)
        #expect(stop.reports == mouse.log.count)
    }

    /// The match: a change is put on the oldest unseen reports whose expected motion sums
    /// nearest it, the gain is learned from those, and the rest stay unseen.
    @Test func aChangeIsMatchedToTheOldestUnseenReports() {
        var tracking = Tracking(at: Self.start)
        tracking.sent(Move(x: Count(clamping: 4), y: .zero), on: 1)
        tracking.sent(Move(x: Count(clamping: 6), y: .zero), on: 2)
        // At gain one the two were expected to carry 4 and 10 together; the cursor moved 5,
        // nearer the first alone.
        tracking.saw(ScreenPoint(x: 105, y: 300)!, on: 2)
        #expect(tracking.unseen.map(\.counts) == [Move(x: Count(clamping: 6), y: .zero)])
        #expect(tracking.curve == [Steering.Sample(counts: 4, perCount: 1.25)])
        #expect(tracking.expected == (112.5, 300))
        // A report that has shown nothing for longer than the closed loop waits moved nothing.
        tracking.saw(ScreenPoint(x: 105, y: 300)!, on: 2 + Tracking.patience + 1)
        #expect(tracking.unseen.isEmpty)
        #expect(tracking.lost == 1)
        // And so does one still unshown when the move gives up waiting.
        tracking.sent(Move(x: Count(clamping: 2), y: .zero), on: 20)
        tracking.giveUp()
        #expect(tracking.unseen.isEmpty)
        #expect(tracking.lost == 2)
    }

    /// Reports matched together are learned at their mean length, each measured alone, and
    /// at the gain the change over their summed counts shows.
    @Test func reportsMatchedTogetherAreLearnedAtTheirMeanLength() throws {
        var tracking = Tracking(at: Self.start)
        tracking.sent(Move(x: Count(clamping: 4), y: .zero), on: 1)
        tracking.sent(Move(x: .zero, y: Count(clamping: 3)), on: 2)
        // 0.8 of (4, 3): nearer both together than the first alone.
        tracking.saw(ScreenPoint(x: 103.2, y: 302.4)!, on: 2)
        #expect(tracking.unseen.isEmpty)
        let sample = try #require(tracking.curve.first)
        #expect(tracking.curve.count == 1)
        #expect(sample.counts == 4)
        #expect(abs(sample.perCount - 0.8) < 1e-9)
    }
}

/// A mouse on a smooth acceleration curve, its cursor showing every `lateEvery`th report
/// one read late.
///
/// The curve rises with report length as this Mac's does - 0.3 points a count at two
/// counts, 0.6 at four, 0.75 at five, measured in `Pointer.Gain` and `human.md` - rather
/// than `FakeMouse`'s step at ten counts, which no Mac has and which triples a report's
/// reach between one count and the next. A late report is one the window server has not
/// applied when the next tick reads: on studious 4 reports in 40 were, so one in four is
/// harsher than the Mac. Every report late is not a case steering can be asked to meet:
/// while the curve is being learned, two reports shown together read exactly as one
/// report on a curve twice as steep.
final class CurvedMouse: Mouse {
    private let state: Mutex<(shown: ScreenPoint, pending: (x: Double, y: Double), reports: Int, farthest: Double)>
    private let lateEvery: Int

    init(at position: ScreenPoint, lateEvery: Int) {
        state = Mutex((position, (0, 0), 0, position.x))
        self.lateEvery = lateEvery
    }

    /// Where the cursor really is, late reports included.
    var position: ScreenPoint { state.withLock { ScreenPoint(x: $0.shown.x + $0.pending.x, y: $0.shown.y + $0.pending.y)! } }
    /// The furthest right it has really been.
    var farthest: Double { state.withLock { $0.farthest } }

    /// What a read shows: every report but a late one not yet read past.
    func cursor() -> ScreenPoint {
        state.withLock {
            let shown = $0.shown
            $0.shown = ScreenPoint(x: shown.x + $0.pending.x, y: shown.y + $0.pending.y)!
            $0.pending = (0, 0)
            return shown
        }
    }

    func down(_ button: Button) throws {}
    func releaseAll() throws {}
    func hold(_ buttons: Set<Button>) throws {}
    func scroll(by delta: Scroll) throws {}

    func move(by delta: Move) throws {
        state.withLock {
            let gain = min(4, 0.15 * hypot(Double(delta.x.value), Double(delta.y.value)))
            let motion = (x: Double(delta.x.value) * gain, y: Double(delta.y.value) * gain)
            $0.reports += 1
            if lateEvery > 0, $0.reports % lateEvery == 0 {
                $0.pending = ($0.pending.x + motion.x, $0.pending.y + motion.y)
            } else {
                $0.shown = ScreenPoint(x: $0.shown.x + motion.x, y: $0.shown.y + motion.y)!
            }
            $0.farthest = max($0.farthest, $0.shown.x + $0.pending.x)
        }
    }
}
