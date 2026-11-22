import Foundation
import TestClock
import Testing
@testable import Input
import ScreenSpace
import ScreenSpaceTesting
import InputTesting
import Time

/// Where a click lands, `docs/design/human.md`: a point exactly, and a box at a point drawn
/// inside it and clear of its edge, spread about its centre and held to the line the hand
/// sets out on, the move timed by its size.
@Suite struct TargetTests {
    static let start = ScreenPoint.at(100, 300)
    static let button = ScreenRect.at(800, 290, 80, 24)

    static func aims(at target: Target, from start: ScreenPoint = start, seeds: Range<UInt64> = 0 ..< 2000) -> [ScreenPoint] {
        seeds.map { seed in
            var generator = SeededGenerator(seed: seed)
            return try! target.aim(from: start, drawing: &generator)
        }
    }

    static func spread(_ values: [Double]) -> (mean: Double, deviation: Double) {
        let mean = values.reduce(0, +) / Double(values.count)
        return (mean, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot())
    }

    /// A point is pressed where it is, and its move timed as today's, by W = 20.
    @Test func aPointIsAimedAtExactlyAndTimedAsAButton() throws {
        let point = ScreenPoint.at(840.5, 300.25)
        #expect(Set(Self.aims(at: .point(point))) == [point])
        var generator = SeededGenerator(seed: 7)
        let path = try Trajectory(from: Self.start, toward: .point(point), drawing: &generator)
        #expect(path.target == point)
        #expect(path.toward.width == 20)
    }

    /// Every point drawn in a box is at least the margin inside its edge, and they differ:
    /// over 2000 seeds, no two the same.
    @Test func aBoxIsAimedInsideItsMarginAtVariedPoints() throws {
        let box = Self.button
        let aims = Self.aims(at: .box(box))
        #expect(aims.allSatisfy { (box.x + 2 ... box.x + box.width - 2).contains($0.x) && (box.y + 2 ... box.y + box.height - 2).contains($0.y) })
        #expect(Set(aims).count == aims.count)
    }

    /// Along the line of travel, spread about the centre as a person's clicks are, the
    /// deviation the aimable width over 4.133, a little less for the redraws past the edge:
    /// from straight above or beside, on either axis, and from over the box, its margin
    /// included, where there is no line to keep to, on both. So a drag whose drop box holds
    /// the point it pressed still carries the button somewhere inside it.
    @Test func alongTheTravelTheAimsSpreadAboutTheCentreByTheEffectiveWidth() throws {
        let box = Self.button
        let beside = Self.aims(at: .box(box), from: ScreenPoint.at(100, 302))
        let above = Self.aims(at: .box(box), from: ScreenPoint.at(840, 0))
        let over = Self.aims(at: .box(box), from: ScreenPoint.at(801, 291))
        for (values, centre, aimable) in [(beside.map(\.x), 840.0, 76.0), (above.map(\.y), 302.0, 20.0), (over.map(\.x), 840.0, 76.0), (over.map(\.y), 302.0, 20.0)] {
            let measured = Self.spread(values)
            #expect(abs(measured.mean - centre) < aimable * 0.02, "mean \(measured.mean)")
            #expect((aimable / 4.133 * 0.85 ... aimable / 4.133).contains(measured.deviation), "deviation \(measured.deviation)")
        }
    }

    /// A hand moving down onto a wide menu row comes straight down: across its travel the
    /// aims keep to the start's line by its directional error, 5% of the distance, not
    /// over the row to its centre. The row and start are the probe page's Bravo, under Menu.
    @Test func acrossTheTravelTheAimsKeepToTheStartsLine() throws {
        let row = ScreenRect.at(1101, 305, 238, 40)
        let start = ScreenPoint.at(1118, 252)
        let aims = Self.aims(at: .box(row), from: start)
        let (mean, deviation) = Self.spread(aims.map(\.x))
        // 55 down to the nearest aimable point, the hand strays 2.75 across; the row's spread
        // of 56.6 pulls the mean 0.24 toward its centre and the deviation down to 2.747.
        #expect(abs(mean - 1118.24) < 0.2, "mean \(mean)")
        #expect((2.6 ... 2.9).contains(deviation), "deviation \(deviation)")
        #expect(Self.spread(aims.map(\.y)).mean > 320)
    }

    /// Coming in at a slant, onto the button's corner, the aims still keep near the line the
    /// hand set out on, within its directional error, and lie past the corner along it.
    @Test func atASlantTheAimsKeepNearTheStartsLine() throws {
        let start = ScreenPoint.at(700, 200)
        let aims = Self.aims(at: .box(Self.button), from: start)
        // The line runs to the nearest aimable point, the corner (802, 292), 137 off.
        let (dx, dy) = (102.0, 92.0), distance = hypot(102.0, 92.0)
        let off = Self.spread(aims.map { (($0.x - start.x) * dy - ($0.y - start.y) * dx) / distance })
        let along = Self.spread(aims.map { (($0.x - start.x) * dx + ($0.y - start.y) * dy) / distance })
        #expect(abs(off.mean) < 0.05 * distance && off.deviation < 0.05 * distance, "across \(off)")
        #expect(along.mean > distance + 10, "along \(along)")
    }

    /// A long move to a small button holds no line: the hand's error is wider than the
    /// button, so the aims spread about its centre as from straight beside it.
    @Test func fromFarTheAimsSpreadAboutTheCentre() throws {
        let aims = Self.aims(at: .box(Self.button), from: ScreenPoint.at(100, 280))
        let measured = Self.spread(aims.map(\.y))
        #expect(abs(measured.mean - 302) < 0.6, "mean \(measured.mean)")
        #expect(measured.deviation > 20 / 4.133 * 0.85, "deviation \(measured.deviation)")
    }

    /// A box no wider than twice the margin on an axis is aimed at its centre on that axis.
    @Test func aBoxTooThinToStrayInIsAimedAtItsCentre() throws {
        let line = ScreenRect.at(10, 20, 200, 3)
        let aims = Self.aims(at: .box(line))
        #expect(aims.allSatisfy { $0.y == 21.5 })
        #expect(Set(aims.map(\.x)).count == aims.count)
    }

    /// Fitts' W is the smaller of the box's sides, so a large target is a quicker move than
    /// a small one from as far away.
    @Test func aMoveToABoxIsTimedByItsSmallerSide() throws {
        var generator = SeededGenerator(seed: 7)
        let path = try Trajectory(from: Self.start, toward: .box(Self.button), drawing: &generator)
        var replay = SeededGenerator(seed: 7)
        _ = try Target.box(Self.button).aim(from: Self.start, drawing: &replay)
        let pace = Trajectory.pace.draw(using: &replay)
        let distance = hypot(path.target.x - Self.start.x, path.target.y - Self.start.y)
        #expect(path.toward.width == 24)
        #expect(path.duration == (Duration.milliseconds(50) + .milliseconds(150) * log2(distance / 24 + 1)) * pace)
        let wide = ScreenRect.at(700, 200, 280, 200)
        let small = ScreenRect.at(836, 296, 8, 8)
        var a = SeededGenerator(seed: 3), b = SeededGenerator(seed: 3)
        let (wideMove, smallMove) = (try Trajectory(from: Self.start, toward: .box(wide), drawing: &a), try Trajectory(from: Self.start, toward: .box(small), drawing: &b))
        #expect(wideMove.duration < smallMove.duration)
    }

    /// A place is spelled as a reading prints it: two numbers a point, four a box, and any
    /// other count is refused in the words of the form it is nearest.
    @Test func aPlaceIsSpelledAsAReadingPrintsIt() throws {
        #expect(try Target.Asked(spelled: "840.5,300.25") == .point(ScreenPoint.at(840.5, 300.25)))
        #expect(try Target.Asked(spelled: "800,290,80,24") == .box(Self.button))
        for refused in ["", "1", "1,2,3", "1,2,3,4,5", "a,2", "1,2,inf,4"] {
            #expect(throws: Misspelled.self, "\(refused)") { try Target.Asked(spelled: refused) }
        }
    }

    /// A place asked for is placed by the one rule, and refused by name when no display
    /// shows it.
    @Test func aPlaceNoDisplayShowsIsRefused() throws {
        let screen = DisplayLayout.single.online
        let refused = try #require(throws: Unplaced.self) { try Target.Asked.point(ScreenPoint.at(-5, 5)).placed(on: screen) }
        #expect("\(refused)" == "-5,5 is on no display: the displays are 0,0,1920,1080")
        guard case .box(let shown) = try Target.Asked.box(ScreenRect.at(1900, 10, 100, 20)).placed(on: screen) else {
            Issue.record("a box placed as a point")
            return
        }
        #expect(shown.value.part == ScreenRect.at(1900, 10, 20, 20))
    }

    /// A click given a box lands on the point its move aimed at, inside the box, and says
    /// where: the aim and the landing both on the move it hands over.
    @Test func aClickGivenABoxLandsWhereItAimedInsideTheBox() async throws {
        for seed in UInt64(0) ..< 5 {
            let mouse = CurvedMouse(at: Self.start, lateEvery: 0)
            let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, clock: Clock(ManualClock()),
                                  randomness: RandomSource(seed: seed), hand: .macOSDefault, traced: { _ in })
            let click = try await pointer.click(at: .box(Self.button), button: .left, times: .single)
            let aimed = click.moved.aimed
            #expect((802 ... 878).contains(aimed.x) && (292 ... 312).contains(aimed.y), "seed \(seed): \(aimed)")
            #expect(click.moved.landed == click.at)
            #expect(abs(click.at.x - aimed.x) <= 0.5 && abs(click.at.y - aimed.y) <= 0.5, "seed \(seed): \(click.at) for \(aimed)")
            #expect(click.moved.width == 24)
        }
    }
}
