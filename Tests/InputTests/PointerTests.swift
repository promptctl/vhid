import Foundation
import Pointing
import TestClock
import Testing
@testable import Input
import ScreenSpace

/// The pointer against a fake screen with a fake acceleration curve: what the loop posts,
/// where the cursor ends up, and what it does when the cursor will not go.
@Suite @MainActor struct PointerTests {
    static let origin = try! ScreenPoint.at(0, 0)

    /// One step is the remaining distance over the gain, rounded toward zero and clamped to
    /// the report: the whole screen at gain one is a full report, and 160.5 at gain three
    /// asks for 53, not 54, so a known gain lands short and never past.
    @Test func aStepIsTheRemainingDistanceOverTheGainClampedToTheReport() throws {
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(541.5, 375), gain: Pointer.Gain(perCount: 1, upTo: .infinity)) == Move(x: Count(clamping: 127), y: Count(clamping: 127)))
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(160.5, -6), gain: Pointer.Gain(perCount: 3, upTo: .infinity)) == Move(x: Count(clamping: 53), y: Count(clamping: -2)))
        #expect(Pointer.step(from: try ScreenPoint.at(100, 100), to: try ScreenPoint.at(90, 100), gain: Pointer.Gain(perCount: 1, upTo: .infinity)) == Move(x: Count(clamping: -10), y: .zero))
    }

    /// Within half a point an axis is arrived and asks for nothing; outside it the ask is
    /// never rounded to nothing, however high the gain.
    @Test func aStepIsZeroWhenArrivedAndNeverZeroWhenNot() throws {
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(0.4, -0.5), gain: Pointer.Gain(perCount: 1, upTo: .infinity)) == .none)
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(1, -0.6), gain: Pointer.Gain(perCount: 10, upTo: .infinity)) == Move(x: Count(clamping: 1), y: Count(clamping: -1)))
    }

    /// The gain is what moved over what was asked; a report that moved nothing halves the
    /// estimate rather than zeroing it, so the next ask doubles.
    @Test func theGainIsObservedMotionOverAskedMotion() throws {
        let asked = Move(x: Count(clamping: 127), y: Count(clamping: 127))
        let length = hypot(127.0, 127.0)
        #expect(Pointer.gain(after: asked, from: Self.origin, to: try ScreenPoint.at(381, 381), previous: .assumed) == Pointer.Gain(perCount: 3, upTo: length))
        #expect(Pointer.gain(after: asked, from: Self.origin, to: Self.origin, previous: .assumed) == Pointer.Gain(perCount: 0.5, upTo: .infinity))
    }

    /// A gain read off a slow report is not asked to hold for a faster one. The numbers are
    /// this Mac's: two counts moved the cursor 0.25 points each, and four counts would have
    /// moved it 0.72. Dividing the 1.2 points left by 0.25 asks for four counts and throws
    /// the cursor three points past; the ask stays at the two counts the gain was read from.
    @Test func aStepIsNoFasterThanTheReportItsGainCameFrom() throws {
        let slow = Pointer.Gain(perCount: 0.25, upTo: 2)
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(1.2, 0), gain: slow) == Move(x: Count(clamping: 2), y: .zero))
        // Both axes shrink together, so the report keeps its direction.
        #expect(Pointer.step(from: Self.origin, to: try ScreenPoint.at(30, 40), gain: Pointer.Gain(perCount: 1, upTo: 5)) == Move(x: Count(clamping: 3), y: Count(clamping: 4)))
    }

    /// A move across the screen: the first full report is thrown by the curve, the loop
    /// reads the gain off it and lands short with the second, a one-count nudge finishes,
    /// and the arrival round still asks the check.
    @Test func aMoveLearnsTheGainAndConvergesFromBelow() async throws {
        let mouse = FakeMouse(at: try ScreenPoint.at(100, 100))
        let reports = try await mouse.pointer.home(on: try ScreenPoint.at(641.5, 475))
        #expect(reports == 3)
        #expect(mouse.position == (try ScreenPoint.at(641, 475)))
        #expect(mouse.log == ["move 127 127", "move 53 -2", "move 1 0"])
    }

    /// A cursor that will not move is given three reports, each asking for more than the
    /// last, and then refused by name with where it is.
    @Test func aCursorThatWillNotMoveIsGivenUpAfterThreeStalls() async throws {
        let mouse = FakeMouse(at: Self.origin)
        mouse.stuck = true
        let refused = try await #require(throws: WouldNotReach.self) { try await mouse.pointer.home(on: try ScreenPoint.at(50, 0)) }
        #expect(refused.reports == 3)
        #expect(refused.cursor == Self.origin)
        #expect(mouse.log == ["move 50 0", "move 100 0", "move 127 0"])
    }

    /// Each click is a button down and a release, each behind its own check, after the
    /// move's own check found the cursor already there.
    @Test func aClickPostsOneDownAndOneUpPerClick() async throws {
        let mouse = FakeMouse(at: Self.origin)
        let click = try await mouse.pointer.click(at: .point(Self.origin), button: .middle, times: Clicks(rawValue: 3)!)
        let drawn = try TrajectoryTests.trajectory(seed: 1, from: Self.origin, to: Self.origin)
        #expect(click == Pointer.Click(at: Self.origin, moved: Pointer.Moved(from: Self.origin, aimed: Self.origin, toward: .point(Self.origin), planned: .zero, structure: drawn.structure,
                                                                             bow: drawn.bow, halfway: drawn.halfway,
                                                                             displays: .vast, kept: Trajectory.Kept(ends: 1, bow: 1), steered: 0, closing: 0, lost: 0, landed: Self.origin)))
        #expect(mouse.log == ["down 3", "up", "down 3", "up", "down 3", "up"])
    }

    /// A click that stops with the button down releases on the way out, and says so when
    /// the release was refused too. [LAW:no-silent-failure]
    @Test func aClickThatStopsReleasesAndReportsARefusedRelease() async throws {
        let mouse = FakeMouse(at: Self.origin)
        mouse.refused = 1 ..< .max
        let stopped = try await #require(throws: PointingStopped.self) { try await mouse.pointer.click(at: .point(Self.origin), button: .left, times: .single) }
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased != nil)
        #expect("\(stopped)".contains("A button may be left held"))
        #expect(mouse.log == ["down 1", "up", "up"])
    }

    /// The wheel goes out a notch a report, both axes together until the shorter is done,
    /// after a rest and with a pause after every notch, the last included.
    @Test func aScrollIsOneNotchAReportWithAPauseAfterEach() async throws {
        let mouse = FakeMouse(at: Self.origin)
        let clock = ManualClock()
        try await mouse.pointer(on: clock).scroll(at: .point(Self.origin), vertical: 300, horizontal: -5)
        #expect(mouse.log == Array(repeating: "scroll 1 -1", count: 5) + Array(repeating: "scroll 1 0", count: 295))
        #expect(clock.sleeps == 301)
    }

    /// A roll is mostly pauses, so a cancel lands in one and stops the roll at the next
    /// notch, with the buttons released on the way out. `Int.min` because it has no `abs`
    /// and only a cancel ends it. The task is made on this actor and cannot begin until
    /// the test suspends, so the aim is taken before the rest that comes first.
    @Test func aScrollCancelledInARestStopsBeforeTheNextNotch() async throws {
        let mouse = FakeMouse(at: Self.origin)
        let clock = ManualClock()
        let roll = Task { try await mouse.pointer(on: clock).scroll(at: .point(Self.origin), vertical: Int.min, horizontal: 0) }
        clock.cancel(afterSleeps: 4) { roll.cancel() }
        let stopped = try await #require(throws: PointingStopped.self) { try await roll.value }
        #expect(stopped.cause is CancellationError)
        #expect(mouse.log == Array(repeating: "scroll -1 0", count: 3) + ["up"])
    }

}

/// The last step of a move, on a Mac whose pointer moves several points for one count.
///
/// The loop's promise is that it converges, and the one step that can break it is the
/// floor: below a whole count's worth of distance there is nothing smaller to ask for
/// than one count, and one count may carry the cursor further past the target than it
/// was short of it. Asking anyway is an oscillation that ends in a `WouldNotReach` about
/// a target the cursor was already beside. [LAW:verifiable-goals]
@Suite struct PointerConvergenceTests {
    /// Every step lands strictly nearer than the one before, or the move is over. Asserted
    /// over the gains a Mac with tracking speed turned up actually shows, and over
    /// remainders on both sides of half a count.
    @Test(arguments: [2.0, 3.0, 5.0, 7.5])
    func aMoveEndsBesideTheTargetRatherThanOscillatingPastIt(gain: Double) async throws {
        for offset in [1.4, 1.6, 2.5, 3.0, 4.9, 20.0] {
            let mouse = SteadyGainMouse(at: try ScreenPoint.at(0, 0), gain: gain)
            let target = try ScreenPoint.at(offset, 0)
            let reports = try await mouse.pointer.home(on: target)
            let short = abs(mouse.position.x - target.x)
            #expect(short < gain, "gain \(gain), offset \(offset): stopped \(short) points short in \(reports) reports")
            #expect(reports < Pointer.rounds, "gain \(gain), offset \(offset): took every round it had")
        }
    }

    /// A cursor that will not move is still a named failure and not a loop without end:
    /// the floor may never be the reason a move gives up, and a pinned cursor always is.
    @Test func aPinnedCursorIsStillWouldNotReach() async throws {
        let mouse = FakeMouse(at: try ScreenPoint.at(0, 0))
        mouse.stuck = true
        await #expect(throws: WouldNotReach.self) { try await mouse.pointer.home(on: try ScreenPoint.at(400, 0)) }
    }
}

/// What a click says about itself, and what a place on the screen refuses to be.
@Suite struct ClickTruthTests {
    /// A cursor that will not move is `WouldNotReach` however near the target is.
    ///
    /// The approach ends when one count stops helping, and a pinned cursor is one count
    /// that did not help - so the two have to be told apart by whether the cursor moved at
    /// all. Aimed 1.4 points away, which is inside the first step's reach, so the whole
    /// move is floor-sized reports: if the floor alone decided this, it would report an
    /// arrival the cursor never made.
    @Test func aPinnedCursorIsWouldNotReachEvenWhenTheTargetIsOneCountAway() async throws {
        let mouse = FakeMouse(at: try ScreenPoint.at(0, 0))
        mouse.stuck = true
        await #expect(throws: WouldNotReach.self) { try await mouse.pointer.home(on: try ScreenPoint.at(1.4, 0)) }
    }

    /// The click reports where the button went down, not where it was asked to go down.
    /// On a Mac whose smallest report carries the cursor three points, those are different
    /// places, and only one of them is a fact.
    @Test func aClickSaysWhereItLandedAndNotWhereItWasAimed() async throws {
        let mouse = SteadyGainMouse(at: try ScreenPoint.at(0, 0), gain: 3)
        let aim = try ScreenPoint.at(1.4, 0)
        let click = try await mouse.pointer.click(at: .point(aim), button: .left, times: .single)
        #expect(click.at == mouse.position)
        #expect(click.at != aim)
    }

    /// A place no display shows is refused by every verb by name, before the mouse is asked
    /// anything: no report, no button, and a drag with one good end holds nothing.
    @Test(arguments: ["click", "move", "scroll", "drag from", "drag to"])
    func aPlaceOnNoDisplayIsRefusedBeforeAnythingMoves(verb: String) async throws {
        let mouse = FakeMouse(at: try ScreenPoint.at(0, 0))
        let off = Target.point(try ScreenPoint.at(150_000, 0))
        let near = Target.point(try ScreenPoint.at(50, 50))
        let pointer = mouse.pointer
        await #expect(throws: OffDisplays(target: off)) {
            switch verb {
            case "click": _ = try await pointer.click(at: off, button: .left, times: .single)
            case "move": _ = try await pointer.move(to: off)
            case "scroll": try await pointer.scroll(at: off, vertical: 1, horizontal: 0)
            case "drag from": _ = try await pointer.drag(from: off, to: near, button: .left)
            default: _ = try await pointer.drag(from: near, to: off, button: .left)
            }
        }
        #expect(mouse.log.allSatisfy { $0 == "up" }, "\(mouse.log)")
    }

    /// A cursor the window server puts where no display is is not steered from: the move is
    /// refused naming where it was said to be.
    @Test func aCursorOnNoDisplayIsRefusedByWhereItWasSaidToBe() async throws {
        let at = try ScreenPoint.at(150_000, 0)
        let mouse = FakeMouse(at: at)
        await #expect(throws: CursorUnreadable.offDisplays(at)) { try await mouse.pointer.move(to: .point(try ScreenPoint.at(10, 10))) }
        #expect(mouse.log.isEmpty)
        #expect(CursorUnreadable.offDisplays(at).description == "the window server says the cursor is at 150000,0, which no display holds")
    }
}
