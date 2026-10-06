import Foundation
import Pointing
import Synchronization
import TestClock
import Testing
@testable import Input

/// The pauses a pointer makes around its presses, on a fake clock: a rest before the
/// button goes down, the button held, the clicks of a double click a gap apart, and the
/// wheel's notches spaced. `docs/design/human.md`, "Clicks" and "Scrolling".
@Suite @MainActor struct HandTests {
    static let origin = ScreenPoint(x: 0, y: 0)!

    /// A mouse that logs every report with the time on `clock` it went out at, in whole
    /// milliseconds, and a pointer over it whose pauses are collected as traced.
    final class Timed: Mouse {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let clock = ManualClock()
        private let state = Mutex<(log: [String], pauses: [Pause])>(([], []))

        var log: [String] { state.withLock { $0.log } }
        var pauses: [Pause] { state.withLock { $0.pauses } }

        private func logged(_ what: String) { state.withLock { $0.log.append("\(clock.now.offset / .milliseconds(1)) \(what)") } }

        func down(_ button: Button) throws { try mouse.down(button); logged("down") }
        func releaseAll() throws { try mouse.releaseAll(); logged("up") }
        func hold(_ buttons: Set<Button>) throws { try mouse.hold(buttons) }
        func move(by delta: Move) throws { try mouse.move(by: delta) }
        func scroll(by delta: Scroll) throws { try mouse.scroll(by: delta); logged("notch") }

        func pointer(hand: Hand = .macOSDefault, seed: UInt64 = 1) -> Pointer {
            Pointer(mouse: self, cursor: mouse.cursor, displays: { .vast }, clock: clock, randomness: RandomSource(seed: seed), hand: hand,
                    traced: { [self] in if case .paused(let pause) = $0 { self.state.withLock { $0.pauses.append(pause) } } })
        }
    }

    /// The milliseconds of `pauses`, rounded, for comparing against a log.
    static func ms(_ pauses: [Pause]) -> [Double] { pauses.map { ($0.length / .milliseconds(1)).rounded() } }

    /// A double click on seed 1, pinned to the millisecond: it rests, holds, gaps and holds
    /// again, each pause traced as it is drawn, and every report goes out when the pauses
    /// before it add up to. [LAW:verifiable-goals]
    @Test func aDoubleClickRestsHoldsAndGapsAtExactTimes() async throws {
        let timed = Timed()
        _ = try await timed.pointer().click(at: .point(Self.origin), button: .left, times: .double)
        #expect(timed.pauses.map(\.kind) == [.hand(.rest), .hand(.hold), .hand(.gap), .hand(.hold)])
        let (rest, hold1, gap, hold2) = (timed.pauses[0].length, timed.pauses[1].length, timed.pauses[2].length, timed.pauses[3].length)
        #expect(timed.log == ["\(rest / .milliseconds(1)) down", "\((rest + hold1) / .milliseconds(1)) up",
                              "\((rest + hold1 + gap) / .milliseconds(1)) down", "\((rest + hold1 + gap + hold2) / .milliseconds(1)) up"])
        #expect(timed.clock.now.offset == rest + hold1 + gap + hold2)
        #expect(Self.ms(timed.pauses) == [215, 113, 76, 86])
    }

    /// One seed draws one set of pauses, and another seed another.
    @Test func theSeedDecidesThePauses() async throws {
        let (a, b, c) = (Timed(), Timed(), Timed())
        _ = try await a.pointer(seed: 7).click(at: .point(Self.origin), button: .left, times: .double)
        _ = try await b.pointer(seed: 7).click(at: .point(Self.origin), button: .left, times: .double)
        _ = try await c.pointer(seed: 8).click(at: .point(Self.origin), button: .left, times: .double)
        #expect(a.pauses == b.pauses)
        #expect(a.pauses != c.pauses)
    }

    /// Over many seeds, every pause is inside the design note's bounds, and no two clicks'
    /// holds or rests are all one length: the pauses vary, as a hand's do.
    @Test func everyPauseIsInItsBoundsAndThePausesVary() async throws {
        var rests: Set<Double> = [], holds: Set<Double> = []
        for seed in UInt64(1) ... 50 {
            let timed = Timed()
            _ = try await timed.pointer(seed: seed).click(at: .point(Self.origin), button: .left, times: Clicks(rawValue: 3)!)
            for pause in timed.pauses {
                let ms = pause.length / .milliseconds(1)
                switch pause.kind {
                case .hand(.rest): #expect((120 ... 500).contains(ms)); rests.insert(ms)
                case .hand(.hold): #expect((60 ... 200).contains(ms)); holds.insert(ms)
                case .hand(.gap): #expect((60 ... 180).contains(ms))
                case .hand(.dragHold), .hand(.notch), .keys: Issue.record("a click made a \(pause.kind.name) pause")
                }
            }
        }
        #expect(rests.count > 40 && holds.count > 100)
    }

    /// Each press of a double or triple click comes inside 80% of the double-click interval
    /// after the one before, at the default 0.5 s, on a Mac set as short as macOS's settings
    /// allow, where the hold and gap are scaled down to it but never under 60 ms, and below
    /// that, where the floor yields to half the 80% so a double click is still one.
    @Test(arguments: [500, 300, 200, 150, 100])
    func eachPressComesInsideTheDoubleClickInterval(interval: Int) async throws {
        let hand = Hand(doubleClickInterval: .milliseconds(interval))
        let ceiling = 0.8 * Double(interval)
        for seed in UInt64(1) ... 50 {
            let timed = Timed()
            _ = try await timed.pointer(hand: hand, seed: seed).click(at: .point(Self.origin), button: .left, times: Clicks(rawValue: 3)!)
            let presses = timed.pauses.filter { $0.kind != .hand(.rest) }.map { $0.length / .milliseconds(1) }
            #expect(presses.allSatisfy { $0 >= min(60, ceiling / 2) })
            // hold, gap, hold, gap, hold: a press is the hold before it and the gap after.
            for pair in stride(from: 0, to: presses.count - 1, by: 2) {
                #expect(presses[pair] + presses[pair + 1] <= ceiling, "\(presses) at \(interval) ms")
            }
        }
    }

    /// At the default interval nothing is scaled: the click's pauses are the design note's.
    @Test func atTheDefaultIntervalTheHandIsTheDesignNotes() {
        let hand = Hand.macOSDefault
        #expect(hand.hold == Normal(110, 30, within: 60 ... 200))
        #expect(hand.gap == Normal(120, 30, within: 60 ... 180))
        #expect(hand.rest == Normal(250, 80, within: 120 ... 500))
    }

    /// A drag rests on the start, holds the button before carrying it, and rests on the end
    /// before letting go.
    @Test func aDragRestsHoldsCarriesAndRestsBeforeLettingGo() async throws {
        let timed = Timed()
        _ = try await timed.pointer().drag(from: .point(Self.origin), to: .point(ScreenPoint(x: 40, y: 0)!), button: .left)
        #expect(timed.pauses.map(\.kind) == [.hand(.rest), .hand(.dragHold), .hand(.rest)])
        let rest = timed.pauses[0].length
        #expect(timed.log.first == "\(rest / .milliseconds(1)) down")
        #expect(timed.log.last?.hasSuffix(" up") == true)
        let up = Double(timed.log.last!.split(separator: " ")[0])!
        #expect(up >= timed.pauses.map { $0.length / .milliseconds(1) }.reduce(0, +))
        #expect((50 ... 200).contains(timed.pauses[1].length / .milliseconds(1)))
    }

    /// A scroll rests before its first notch, and its notches are 200 to 300 ms apart and
    /// not all one length; the pause follows the last notch too, so a roll started straight
    /// after is not taken as its continuation.
    @Test func aScrollRestsThenSpacesItsNotches() async throws {
        let timed = Timed()
        try await timed.pointer().scroll(at: .point(Self.origin), vertical: 20, horizontal: 0)
        #expect(timed.pauses.map(\.kind) == [.hand(.rest)] + Array(repeating: .hand(.notch), count: 20))
        let notches = timed.pauses.dropFirst().map { $0.length / .milliseconds(1) }
        #expect(notches.allSatisfy { (200 ... 300).contains($0) })
        #expect(Set(notches).count > 15)
        #expect(timed.clock.now.offset == timed.pauses.map(\.length).reduce(.zero, +))
        #expect(timed.log.first == "\(timed.pauses[0].length / .milliseconds(1)) notch")
    }
}
