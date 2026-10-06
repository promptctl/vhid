import Foundation
import TestClock
import Testing
@testable import Input

/// Where a click lands, `docs/design/human.md`: a point exactly, and a box at a point drawn
/// inside it, spread about its centre and clear of its edge, the move timed by its size.
@Suite struct TargetTests {
    static let start = ScreenPoint(x: 100, y: 300)!
    static let button = ScreenRect(x: 800, y: 290, width: 80, height: 24)!

    static func aims(at target: Target, seeds: Range<UInt64> = 0 ..< 2000) -> [ScreenPoint] {
        seeds.map { seed in
            var generator = SeededGenerator(seed: seed)
            return target.aim(drawing: &generator)
        }
    }

    /// A point is pressed where it is, and its move timed as today's, by W = 20.
    @Test func aPointIsAimedAtExactlyAndTimedAsAButton() {
        let point = ScreenPoint(x: 840.5, y: 300.25)!
        #expect(Set(Self.aims(at: .point(point))) == [point])
        var generator = SeededGenerator(seed: 7)
        let path = Trajectory(from: Self.start, toward: .point(point), within: .vast, drawing: &generator)
        #expect(path.target == point)
        #expect(path.width == 20)
    }

    /// Every point drawn in a box is at least the margin inside its edge, and they differ:
    /// over 2000 seeds, no two the same.
    @Test func aBoxIsAimedInsideItsMarginAtVariedPoints() {
        let box = Self.button
        let aims = Self.aims(at: .box(box))
        #expect(aims.allSatisfy { (box.x + 2 ... box.x + box.width - 2).contains($0.x) && (box.y + 2 ... box.y + box.height - 2).contains($0.y) })
        #expect(Set(aims).count == aims.count)
    }

    /// Spread about the centre as a person's clicks are, each axis's deviation its aimable
    /// width over 4.133, a little less for the redraws past the edge.
    @Test func theAimsSpreadAboutTheCentreByTheEffectiveWidth() {
        let box = Self.button
        let aims = Self.aims(at: .box(box))
        for (values, centre, aimable) in [(aims.map(\.x), 840.0, 76.0), (aims.map(\.y), 302.0, 20.0)] {
            let mean = values.reduce(0, +) / Double(values.count)
            let deviation = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
            #expect(abs(mean - centre) < aimable * 0.02, "mean \(mean)")
            #expect((aimable / 4.133 * 0.85 ... aimable / 4.133).contains(deviation), "deviation \(deviation)")
        }
    }

    /// A box no wider than twice the margin on an axis is aimed at its centre on that axis.
    @Test func aBoxTooThinToStrayInIsAimedAtItsCentre() {
        let line = ScreenRect(x: 10, y: 20, width: 200, height: 3)!
        let aims = Self.aims(at: .box(line))
        #expect(aims.allSatisfy { $0.y == 21.5 })
        #expect(Set(aims.map(\.x)).count == aims.count)
    }

    /// Fitts' W is the smaller of the box's sides, so a large target is a quicker move than
    /// a small one from as far away.
    @Test func aMoveToABoxIsTimedByItsSmallerSide() {
        var generator = SeededGenerator(seed: 7)
        let path = Trajectory(from: Self.start, toward: .box(Self.button), within: .vast, drawing: &generator)
        var replay = SeededGenerator(seed: 7)
        _ = Target.box(Self.button).aim(drawing: &replay)
        let pace = Trajectory.pace.draw(using: &replay)
        let distance = hypot(path.target.x - Self.start.x, path.target.y - Self.start.y)
        #expect(path.width == 24)
        #expect(path.duration == (Duration.milliseconds(50) + .milliseconds(150) * log2(distance / 24 + 1)) * pace)
        let wide = ScreenRect(x: 700, y: 200, width: 280, height: 200)!
        let small = ScreenRect(x: 836, y: 296, width: 8, height: 8)!
        var a = SeededGenerator(seed: 3), b = SeededGenerator(seed: 3)
        #expect(Trajectory(from: Self.start, toward: .box(wide), within: .vast, drawing: &a).duration
            < Trajectory(from: Self.start, toward: .box(small), within: .vast, drawing: &b).duration)
    }

    /// A box is what eyes prints, and nothing that is not one is read as one.
    @Test func aBoxIsSpelledAsEyesPrintsIt() {
        #expect(ScreenRect(spelled: "800,290,80,24") == Self.button)
        #expect(ScreenRect(spelled: " -5 ,2.5,1,1") == ScreenRect(x: -5, y: 2.5, width: 1, height: 1))
        #expect(Self.button.description == "800,290,80,24")
        for refused in ["", "1,2,3", "1,2,3,4,5", "1,2,0,4", "1,2,3,-4", "1,,3,4", "a,2,3,4", "1,2,inf,4", "1e308,0,1e308,1"] {
            #expect(ScreenRect(spelled: refused) == nil, "\(refused)")
        }
    }

    /// A click given a box lands on the point its move aimed at, inside the box, and says
    /// where: the aim and the landing both on the move it hands over.
    @Test func aClickGivenABoxLandsWhereItAimedInsideTheBox() async throws {
        for seed in UInt64(0) ..< 5 {
            let mouse = CurvedMouse(at: Self.start, lateEvery: 0)
            let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor() }, displays: { .vast }, clock: ManualClock(),
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
