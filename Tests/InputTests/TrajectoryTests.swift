import Foundation
import OwnThread
import Pointing
import Synchronization
import TestClock
import Testing
@testable import Input

/// The trajectory model of `docs/design/human.md`, on fixed seeds: how long a move takes,
/// the shape of its path, and the draws behind both. Seconds of work over a thousand seeds,
/// which would hold `make test`'s one-thread pool, hence its own thread.
@Suite(.ownThread) struct TrajectoryTests {
    static let start = ScreenPoint(x: 100, y: 300)!
    static let across = ScreenPoint(x: 840, y: 300)!

    static func trajectory(seed: UInt64, from start: ScreenPoint = start, to target: ScreenPoint = across) -> Trajectory {
        var generator = SeededGenerator(seed: seed)
        return Trajectory(from: start, toward: .point(target), within: .vast, drawing: &generator)
    }

    /// MT = 50 ms + 150 ms × log2(D/20 + 1), times the pace drawn after the aim: about
    /// 0.84 s across 740 points before the pace.
    @Test func aMoveTakesFittsTimeTimesItsDrawnPace() {
        var generator = SeededGenerator(seed: 7)
        _ = Target.point(Self.across).aim(drawing: &generator)
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

    /// Each structure ends its main movement where the design note says, over 1,000 seeds:
    /// on the target, short of it by 1–10% of D, past it by 1–8%, or short and then a first
    /// correction that leaves 25–80% of the miss on either side; off the line by at most 4%
    /// of D; each stroke from where the last ended, the last onto the target exactly. All
    /// four come up, at about their shares.
    @Test func eachStructureEndsItsMainMovementWhereTheNoteSays() {
        var seen: [Trajectory.Structure: Int] = [:]
        var sides = Set<Bool>()
        for seed in UInt64(0) ..< 1000 {
            let path = Self.trajectory(seed: seed)
            seen[path.structure, default: 0] += 1
            let main = path.strokes[0].to
            #expect(abs(main.y - 300) <= 29.6, "seed \(seed): \(main)")
            switch path.structure {
            case .direct:
                #expect(path.strokes.count == 1)
            case .undershoot:
                #expect(path.strokes.count == 2)
                #expect((840 - 74.0 ... 840 - 7.4).contains(main.x), "seed \(seed): \(main)")
            case .overshoot:
                #expect(path.strokes.count == 2)
                #expect((840 + 7.4 ... 840 + 59.2).contains(main.x), "seed \(seed): \(main)")
            case .twoCorrections:
                #expect(path.strokes.count == 3)
                #expect((840 - 74.0 ... 840 - 7.4).contains(main.x), "seed \(seed): \(main)")
                let left = (840 - path.strokes[1].to.x) / (840 - main.x)
                #expect((0.25 - 1e-9 ... 0.8 + 1e-9).contains(abs(left)), "seed \(seed): \(left)")
                sides.insert(left > 0)
            }
            #expect(zip(path.strokes, path.strokes.dropFirst()).allSatisfy { $0.to == $1.from })
            #expect(path.strokes.last!.to == (840, 300))
            #expect(path.point(after: path.duration) == (840, 300))
            let total = path.strokes.reduce(Duration.zero) { $0 + $1.duration }
            #expect(abs((total - path.duration) / .milliseconds(1)) < 1e-6)
        }
        #expect(sides == [true, false])
        let shares: [Trajectory.Structure: ClosedRange<Int>] = [.direct: 200 ... 300, .undershoot: 400 ... 500, .overshoot: 110 ... 190, .twoCorrections: 110 ... 190]
        for (structure, range) in shares { #expect(range.contains(seen[structure] ?? 0), "\(structure): \(seen[structure] ?? 0)") }
    }

    /// The whole path, bow, aims off the line and tremor together, stays within the sum of
    /// their bounds of the line, every millisecond over 200 seeds of every structure: 6% and
    /// 4% of D and 1.6 points across it, and no further back than the start or on than the
    /// furthest overshoot.
    @Test func thePathStaysWithinItsBounds() {
        var structures = Set<Trajectory.Structure>()
        for seed in UInt64(0) ..< 200 {
            let path = Self.trajectory(seed: seed)
            structures.insert(path.structure)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let point = path.point(after: .milliseconds(ms))
                #expect(abs(point.y - 300) <= 0.10 * 740 + 1.6 && (100 - 1e-9 ... 840 + 0.08 * 740).contains(point.x), "seed \(seed) at \(ms) ms: \(point)")
            }
        }
        #expect(structures == Set(Trajectory.Structure.allCases))
    }

    /// The main movement bows away from the elbow in every direction, by 1–6% of D times the
    /// sine of its angle to the forearm: a move right or left bulges up, and one along the
    /// forearm hardly bows at all. Corrections are straight.
    @Test func theBowFollowsTheForearm() {
        let centre = ScreenPoint(x: 2000, y: 2000)!
        let forearm = Trajectory.forearm
        for degrees in stride(from: 0.0, to: 360, by: 15) {
            let angle = degrees * .pi / 180
            let end = ScreenPoint(x: centre.x + 740 * cos(angle), y: centre.y + 740 * sin(angle))!
            for seed in UInt64(0) ..< 40 {
                let path = Self.trajectory(seed: seed, from: centre, to: end)
                let main = path.strokes[0]
                let (dx, dy) = (main.to.x - main.from.x, main.to.y - main.from.y)
                let length = hypot(dx, dy)
                let across = abs(dx * forearm.y - dy * forearm.x) / length
                #expect((0.01 * length * across - 1 ... 0.06 * length * across + 1).contains(abs(main.bow)), "\(degrees)° seed \(seed): \(main.bow)")
                // The middle of the stroke, against the middle of its chord, is away from the elbow.
                let middle = main.point(after: main.duration * Submovement.halfway)
                let bulge = (middle.x - (main.from.x + main.to.x) / 2, middle.y - (main.from.y + main.to.y) / 2)
                #expect(bulge.0 * forearm.x + bulge.1 * forearm.y <= 1e-6, "\(degrees)° seed \(seed): \(bulge)")
                #expect(path.strokes.dropFirst().allSatisfy { $0.bow == 0 })
                if degrees == 0 || degrees == 180 { #expect(bulge.1 < 0, "\(degrees)° seed \(seed): \(bulge)") }
            }
        }
        let along = Self.trajectory(seed: 1, from: centre, to: ScreenPoint(x: centre.x + 740 * forearm.x, y: centre.y + 740 * forearm.y)!)
        #expect(abs(along.strokes[0].bow) < 0.01 * 740 * 0.05)
    }

    /// Speed rises and falls once in every stroke, peaking at about 43% of its time, so it
    /// slows down for longer than it speeds up; and the whole move is fastest before half
    /// its time is gone. Sampled a millisecond apart, on seeds of every structure.
    @Test func everyStrokeSlowsDownForLongerThanItSpeedsUp() {
        var structures = Set<Trajectory.Structure>()
        for seed in UInt64(0) ..< 40 {
            let path = Self.trajectory(seed: seed)
            structures.insert(path.structure)
            for stroke in path.strokes {
                let ms = Int(stroke.duration / .milliseconds(1))
                let points = (0 ... ms).map { stroke.point(after: .milliseconds($0)) }
                let steps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
                let peak = steps.indices.max { steps[$0] < steps[$1] }!
                #expect((0.40 ... 0.46).contains(Double(peak) / Double(steps.count)), "seed \(seed): \(peak) of \(steps.count)")
                #expect(zip(steps[..<peak], steps[1 ... peak]).allSatisfy { $0 <= $1 + 1e-9 })
                #expect(zip(steps[peak...], steps[(peak + 1)...]).allSatisfy { $0 + 1e-9 >= $1 })
            }
            let ms = Int(path.duration / .milliseconds(1))
            let points = (0 ... ms).map { path.point(after: .milliseconds($0)) }
            let steps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
            #expect(steps.indices.max { steps[$0] < steps[$1] }! < steps.count / 2, "seed \(seed)")
        }
        #expect(structures == Set(Trajectory.Structure.allCases))
    }

    /// The tremor shakes the path across its line by no more than its amplitude, 0.4–1.6
    /// points, at 7–13 Hz; not at all at either end, so the path starts where the cursor is
    /// and ends on the target; and visibly through the slow strokes after the main one.
    @Test func theTremorShakesThePathOnlyInTheMiddle() {
        var shown = 0
        for seed in UInt64(0) ..< 100 {
            let path = Self.trajectory(seed: seed)
            #expect((0.4 ... 1.6).contains(path.tremor.amplitude) && (7 ... 13).contains(path.tremor.frequency))
            #expect(path.tremor.across == (0, 1))
            #expect(path.point(after: .zero) == (100, 300))
            #expect(path.point(after: path.duration) == (840, 300))
            let main = path.strokes[0].duration
            var widest = 0.0
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let elapsed = Duration.milliseconds(ms)
                let off = path.point(after: elapsed).y - path.unshaken(after: elapsed).y
                #expect(abs(off) <= path.tremor.amplitude + 1e-9, "seed \(seed) at \(ms) ms")
                if elapsed > main { widest = max(widest, abs(off)) }
            }
            if path.strokes.count > 1, widest > path.tremor.amplitude / 2 { shown += 1 }
        }
        #expect(shown > 30)
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

/// A trajectory kept on the displays: beside an edge its strokes never run nearer the edge
/// than the straight line does, the tremor only shakes them, and what it cuts it cuts from
/// the deviation that would reach the edge, not the other. Away from every edge it keeps
/// everything. Over 200 seeds each, seconds of work that would hold `make test`'s one-thread
/// pool, hence its own thread.
@Suite(.ownThread) struct TrajectoryOnTheDisplaysTests {
    static let screen = Displays(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080)])!
    /// Ten points above the bottom edge, where an auto-hidden Dock waits, and across it.
    static let alongTheEdge = (ScreenPoint(x: 100, y: 1070)!, ScreenPoint(x: 1800, y: 1070)!)

    static func trajectory(seed: UInt64, from start: ScreenPoint, to target: ScreenPoint, within displays: Displays = screen) -> Trajectory {
        var generator = SeededGenerator(seed: seed)
        return Trajectory(from: start, toward: .point(target), within: displays, drawing: &generator)
    }

    /// Every millisecond of every path along the bottom edge: its strokes no lower than the
    /// line they were drawn about, to the few hundredths `Displays.depth` finds, and the
    /// tremor no more than its amplitude below them, on the screen. The bow bulges up and
    /// away from the edge, so every path keeps all of it, whatever its aim beside the line
    /// kept.
    @Test func aPathAlongAnEdgeNeverRunsIntoIt() {
        var kept: [Trajectory.Kept] = []
        var highest = 1070.0
        for seed in UInt64(0) ..< 200 {
            let path = Self.trajectory(seed: seed, from: Self.alongTheEdge.0, to: Self.alongTheEdge.1)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let (unshaken, point) = (path.unshaken(after: .milliseconds(ms)), path.point(after: .milliseconds(ms)))
                #expect(unshaken.y <= 1070.05 && point.y <= 1070.05 + path.tremor.amplitude, "seed \(seed) at \(ms) ms: \(point)")
                #expect(Self.screen.covers(point, by: 0), "seed \(seed) at \(ms) ms: \(point)")
                highest = min(highest, point.y)
            }
            kept.append(path.kept)
        }
        #expect(kept.allSatisfy { $0.bow == 1 }, "\(kept.filter { $0.bow < 1 }.count) cut")
        #expect(kept.contains { $0.ends == 1 } && kept.contains { $0.ends < 1 })
        #expect(highest < 1070 - 50)
    }

    /// Along the menu bar, twelve points under the top edge, the bow bulges up into it and no
    /// path keeps all of it; but the cut takes the bow alone, and the paths that aim below
    /// the line, about half, keep that aim and every overshoot along it whole.
    @Test func aPathAlongTheMenuBarCutsItsBowAlone() {
        var kept: [Trajectory.Kept] = []
        for seed in UInt64(0) ..< 200 {
            let path = Self.trajectory(seed: seed, from: ScreenPoint(x: 100, y: 12)!, to: ScreenPoint(x: 900, y: 12)!)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                #expect(path.unshaken(after: .milliseconds(ms)).y >= 11.95, "seed \(seed) at \(ms) ms")
            }
            kept.append(path.kept)
        }
        #expect(kept.allSatisfy { $0.bow < 1 })
        #expect(kept.filter { $0.ends == 1 }.count >= 80, "\(kept.filter { $0.ends == 1 }.count)")
    }

    /// Up to a menu-bar item, an overshoot would carry the path past it into the top edge,
    /// and every one is cut where it ends. The bow, bulging up and left, is cut only where
    /// the main movement ends on the target, at its depth, or a correction carries it past:
    /// nine in ten of those that stop short keep all of their curve.
    @Test func aPathUpToTheMenuBarCutsItsOvershootNotItsBow() {
        var overshoots = 0, short = 0, bowed = 0
        for seed in UInt64(0) ..< 200 {
            let path = Self.trajectory(seed: seed, from: ScreenPoint(x: 400, y: 600)!, to: ScreenPoint(x: 900, y: 12)!)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                #expect(path.unshaken(after: .milliseconds(ms)).y >= 11.95, "seed \(seed) at \(ms) ms")
            }
            if [.undershoot, .twoCorrections].contains(path.structure) { (short, bowed) = (short + 1, bowed + (path.kept.bow == 1 ? 1 : 0)) }
            guard path.structure == .overshoot else { continue }
            overshoots += 1
            #expect(path.kept.ends < 1, "seed \(seed)")
        }
        #expect(overshoots > 15)
        #expect(Double(bowed) >= 0.9 * Double(short), "\(bowed) of \(short)")
    }

    /// A path the drawn deviation would carry into a corner keeps less of it and is still on
    /// the screen: a target ten points from both edges, approached along the diagonal.
    @Test func aPathIntoACornerStaysOffIt() {
        var kept: [Trajectory.Kept] = []
        for seed in UInt64(0) ..< 200 {
            let path = Self.trajectory(seed: seed, from: ScreenPoint(x: 900, y: 500)!, to: ScreenPoint(x: 1910, y: 1070)!)
            for ms in 0 ... Int(path.duration / .milliseconds(1)) {
                let unshaken = path.unshaken(after: .milliseconds(ms))
                #expect(unshaken.x <= 1910.05 && unshaken.y <= 1070.05, "seed \(seed) at \(ms) ms: \(unshaken)")
                #expect(Self.screen.covers(path.point(after: .milliseconds(ms)), by: 0), "seed \(seed) at \(ms) ms")
            }
            kept.append(path.kept)
        }
        #expect(kept.contains { $0.ends < 1 })
    }

    /// Far from every edge, and across the seam between two displays side by side, the whole
    /// drawn path is kept: the same path as on a screen with no edges near.
    @Test func aPathFarFromTheEdgesKeepsItsWholeBow() {
        let pair = Displays(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: 0, width: 1920, height: 1080)])!
        for seed in UInt64(0) ..< 200 {
            let across = Self.trajectory(seed: seed, from: TrajectoryTests.start, to: TrajectoryTests.across)
            #expect(across == TrajectoryTests.trajectory(seed: seed), "seed \(seed)")
            #expect(across.kept == Trajectory.Kept(ends: 1, bow: 1))
            let seam = Self.trajectory(seed: seed, from: ScreenPoint(x: 1000, y: 540)!, to: ScreenPoint(x: 2800, y: 540)!, within: pair)
            #expect(seam.kept == Trajectory.Kept(ends: 1, bow: 1), "seed \(seed)")
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
        try await pointer.move(to: .point(target))
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
        let moved = try await pointer.move(to: .point(target))
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
        // At most ten silent: over seeds 1-40 of these three moves, 2 to 10 were.
        #expect(moved.steered >= ticks - 10)
        let points = [Self.moves[move].0] + reads.map(\.point)
        let steps = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let third = steps.count / 3
        let middle = steps[third ..< 2 * third].max()!
        #expect(steps.prefix(3).allSatisfy { $0 < middle / 3 })
        #expect(steps.suffix(3).allSatisfy { $0 < middle / 3 })
    }

    /// A cursor that shows one report in four a tick late: what has been sent and not shown
    /// is counted as covered, so the cursor never goes past the furthest the path does and
    /// turns back, and the move still lands.
    @Test(arguments: 1 ... 10)
    func reportsTheCursorHasNotShownAreNotSentAgain(seed: UInt64) async throws {
        let mouse = CurvedMouse(at: Self.start, lateEvery: 4)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, displays: { .vast }, clock: ManualClock(), randomness: RandomSource(seed: seed), hand: .macOSDefault, traced: { _ in })
        _ = try await pointer.move(to: .point(Self.target))
        let path = TrajectoryTests.trajectory(seed: seed, from: Self.start, to: Self.target)
        let farthest = (0 ... Int(path.duration / .milliseconds(1))).map { path.point(after: .milliseconds($0)).x }.max()!
        #expect(mouse.farthest <= farthest + 3, "went to \(mouse.farthest) on a path to \(farthest)")
        #expect(abs(mouse.position.x - Self.target.x) <= 0.5 && abs(mouse.position.y - Self.target.y) <= 0.5)
    }

    /// On `FakeMouse`'s step curve, which no Mac has, the steering is thrown about, and the
    /// closing loop still lands the move.
    @Test func aMoveLandsEvenOnACurveWithAStep() async throws {
        let mouse = FakeMouse(at: Self.start)
        _ = try await mouse.pointer.move(to: .point(Self.target))
        #expect(abs(mouse.position.x - Self.target.x) <= 0.5 && abs(mouse.position.y - Self.target.y) <= 0.5)
    }

    /// Every move is handed to `traced` in order, as the verb that made it answered it: a
    /// drag's approach and then its carry.
    @Test func everyMoveIsTraced() async throws {
        final class Traced: Sendable { let moves = Mutex<[Pointer.Moved]>([]) }
        let mouse = CurvedMouse(at: Self.start, lateEvery: 0), traced = Traced()
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, displays: { .vast }, clock: ManualClock(), randomness: RandomSource(seed: 1),
                              hand: .macOSDefault, traced: { if case .moved(let move) = $0 { traced.moves.withLock { $0.append(move) } } })
        let drag = try await pointer.drag(from: .point(Self.target), to: .point(Self.start), button: .left)
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
        let stop = try await #require(throws: WouldNotReach.self) { try await pointer.move(to: .point(Self.target)) }
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
