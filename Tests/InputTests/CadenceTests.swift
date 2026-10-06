import KeyboardLayouts
import Keystrokes
import Synchronization
import TestClock
import Testing
@testable import Input

/// A typist's keys on a fake clock: held and spaced as `docs/design/human.md`, "Typing",
/// says, varying from key to key, and stopped by a cancel that lands in a wait.
@Suite @MainActor struct CadenceTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")

    /// A keyboard that logs each set held with the time on `clock` it went out at, and
    /// takes `acknowledgingKeys` to answer each report that puts a key down.
    final class Timed: Keyboard {
        let clock = ManualClock()
        let acknowledgingKeys: Duration

        init(acknowledgingKeys: Duration = .zero) { self.acknowledgingKeys = acknowledgingKeys }
        private let state = Mutex<(log: [(ms: Double, held: Set<Usage>)], pauses: [Pause], late: [Duration])>(([], [], []))

        var log: [(ms: Double, held: Set<Usage>)] { state.withLock { $0.log } }
        var pauses: [Pause] { state.withLock { $0.pauses } }
        /// Each run's slip, as traced when it ended.
        var late: [Duration] { state.withLock { $0.late } }

        func down(_ usage: Usage) throws { Issue.record("a typist pressed \(usage) by down rather than hold") }
        func releaseAll() throws { state.withLock { $0.log.append((clock.now.offset / .milliseconds(1), [])) } }
        func hold(_ keys: HeldKeys) throws {
            state.withLock { $0.log.append((clock.now.offset / .milliseconds(1), keys.usages)) }
            clock.advance(by: keys.usages.contains { $0.modifierBit == nil } ? acknowledgingKeys : .zero)
        }

        func typist(seed: UInt64 = 1) -> Typist {
            Typist.on(self, clock: clock, seed: seed, traced: { [self] traced in
                state.withLock {
                    switch traced {
                    case .paused(let pause): $0.pauses.append(pause)
                    case .ran(let late): $0.late.append(late)
                    }
                }
            })
        }

        /// Each key that went down, with its modifiers held at that moment, when it went
        /// down and when it came up.
        var strokes: [(key: Usage, modifiers: Set<Usage>, down: Double, up: Double)] {
            var strokes: [(key: Usage, modifiers: Set<Usage>, down: Double, up: Double)] = []
            var open: (key: Usage, modifiers: Set<Usage>, down: Double)?
            for (ms, held) in log {
                let keys = held.filter { $0.modifierBit == nil }
                #expect(keys.count <= 1, "two keys held at once at \(ms) ms")
                if let pressed = open, !keys.contains(pressed.key) {
                    strokes.append((pressed.key, pressed.modifiers, pressed.down, ms))
                    open = nil
                }
                if open == nil, let key = keys.first { open = (key, held.subtracting([key]), ms) }
            }
            return strokes
        }
    }

    static let shift = Usage(rawValue: 0xE1)

    /// Every key held and spaced inside the model's bounds, each with exactly the modifiers
    /// its character asks for, and the keys of "HEllo, World" varying from one to the next.
    @Test func keysAreHeldAndSpacedAsATypistsAre() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        let text = "HEllo, World"
        #expect(try await typist.type(try typist.lower(text, on: Self.us)) == text.count)
        let strokes = keyboard.strokes
        try #require(strokes.count == text.count)
        for (stroke, character) in zip(strokes, text) {
            #expect((40 ... 200).contains(stroke.up - stroke.down), "\(character) held \(stroke.up - stroke.down) ms")
            #expect(stroke.modifiers == (character.isUppercase ? [Self.shift] : []), "\(character) under \(stroke.modifiers)")
        }
        for (previous, next) in zip(strokes, strokes.dropFirst()) {
            #expect(next.down - previous.down >= 70)
            #expect(next.down - previous.up >= 20)
        }
        #expect(Set(strokes.map { $0.up - $0.down }).count == strokes.count)
        #expect(Set(zip(strokes, strokes.dropFirst()).map { $1.down - $0.down }).count == strokes.count - 1)
        #expect(keyboard.log.last?.held == [])
    }

    /// Shift goes down 30-80 ms before the first capital and stays down through "HE", comes
    /// up 20-60 ms after the E, and is up 20 ms or more before the l goes down.
    @Test func shiftIsHeldThroughACapitalisedRunAndUpBeforeTheNextKey() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        try await typist.type(try typist.lower("HEl", on: Self.us))
        let log = keyboard.log
        let shiftDown = try #require(log.first { $0.held == [Self.shift] })
        let shiftUp = try #require(log.lastIndex { $0.held.contains(Self.shift) }.map { log[$0 + 1] })
        let strokes = keyboard.strokes
        #expect((30 ... 80).contains(strokes[0].down - shiftDown.ms))
        #expect(log.filter { $0.held == [Self.shift] }.count == 3, "shift came up between H and E")
        #expect((20 ... 60).contains(shiftUp.ms - strokes[1].up))
        #expect(strokes[2].down - shiftUp.ms >= 20)
    }

    /// A daemon slow to acknowledge a key-down sends the key-up after it late, and the rest
    /// of the run moves with it: no key goes down within 20 ms of the last one coming up,
    /// however late that came up.
    @Test func aSlowAcknowledgementDelaysTheRunRatherThanShorteningIt() async throws {
        let keyboard = Timed(acknowledgingKeys: .milliseconds(150))
        let typist = keyboard.typist()
        let text = "a slow daemon answers every key late"
        try await typist.type(try typist.lower(text, on: Self.us))
        let strokes = keyboard.strokes
        #expect(strokes.count == text.count)
        for (previous, next) in zip(strokes, strokes.dropFirst()) { #expect(next.down - previous.up >= 20) }
        // How late the run went is traced once it ends, and here it went late.
        try #require(keyboard.late.count == 1)
        #expect(keyboard.late[0] > .zero)
    }

    /// A run on time traces a slip of nothing: zero, not absent.
    @Test func aRunOnTimeTracesNoSlip() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        try await typist.type(try typist.lower("on time", on: Self.us))
        #expect(keyboard.late == [.zero])
    }

    /// The seed draws the run again exactly, and another seed draws another run.
    @Test func theSeedDrawsTheSameRunAgain() async throws {
        func run(seed: UInt64) async throws -> [Double] {
            let keyboard = Timed()
            let typist = keyboard.typist(seed: seed)
            try await typist.type(try typist.lower("Seeded", on: Self.us))
            return keyboard.log.map(\.ms)
        }
        #expect(try await run(seed: 7) == run(seed: 7))
        #expect(try await run(seed: 7) != run(seed: 8))
    }

    /// Over many keystrokes the dwell and the down-down latency centre on the model's means,
    /// 95 and 180 ms: drawn, not fixed.
    @Test func dwellAndLatencyCentreOnTheModelsMeans() {
        var generator = SeededGenerator(seed: 3)
        var last = Cadence.Stroke.idle(at: .zero, settle: Cadence.typist.settle)
        var dwells: [Double] = [], latencies: [Double] = []
        for _ in 0 ..< 4000 {
            let (changes, left) = Cadence.typist.press(Keystroke(Usage(rawValue: 0x04)), after: last, drawing: &generator)
            dwells.append((left.up - left.down!) / .milliseconds(1))
            if let down = last.down { latencies.append((left.down! - down) / .milliseconds(1)) }
            #expect(changes.map(\.wait) == [.keyDown, .keyUp])
            last = left
        }
        let mean = { (values: [Double]) in values.reduce(0, +) / Double(values.count) }
        #expect(abs(mean(dwells) - 95) < 3)
        // The latency floor of 70 ms and the 20 ms settle after a release lift the mean a little.
        #expect((180 ... 190).contains(mean(latencies)))
    }

    /// The waits are traced by the report each ends in, and they account for the run's time.
    @Test func everyWaitIsTracedByTheReportItEndsIn() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        try await typist.type(try typist.lower("Ab", on: Self.us))
        #expect(keyboard.pauses.map(\.kind) == [.keys(.modifierDown), .keys(.keyDown), .keys(.keyUp), .keys(.modifierUp), .keys(.keyDown), .keys(.keyUp)])
        let slept = keyboard.pauses.reduce(Duration.zero) { $0 + $1.length }
        #expect(slept == keyboard.clock.now.offset)
    }

    /// A list of chords is one run: the second chord is spaced from the first as a typist's
    /// next keystroke is, and Command is up before Return goes down.
    @Test func chordsAreSpacedAsKeystrokesAre() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        let chords = try [KeyChord(key: Key(rawValue: 0x01), modifiers: [.leftCommand]), KeyChord(key: Key(rawValue: 0x24))].map(typist.lower)
        #expect(try await typist.press(chords) == 2)
        let strokes = keyboard.strokes
        try #require(strokes.count == 2)
        #expect(strokes[0].modifiers == [Usage(rawValue: 0xE3)])
        #expect(strokes[1].modifiers == [])
        #expect(strokes[1].down - strokes[0].down >= 70)
        #expect(keyboard.log.last?.held == [])
    }

    /// Each chord lets go of its modifiers before the next: Command comes up between two
    /// Command-Tabs, so the second is a second app switch rather than one held Command.
    @Test func eachChordLetsGoOfItsModifiersBeforeTheNext() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        let tab = try typist.lower(KeyChord(key: Key(rawValue: 0x30), modifiers: [.leftCommand]))
        #expect(try await typist.press([tab, tab]) == 2)
        let strokes = keyboard.strokes
        try #require(strokes.count == 2)
        let between = keyboard.log.filter { $0.ms > strokes[0].up && $0.ms < strokes[1].down }
        #expect(between.contains { $0.held.isEmpty }, "Command held from one Command-Tab into the next")
        #expect(keyboard.log.last?.held == [])
    }

    /// The dwell is cut off under the delay until a held key repeats: uncut at 250 ms and
    /// longer, at 80% of it below that, and shrunk whole on a Mac set far shorter.
    @Test(arguments: [(250.0, 200.0), (1000, 200), (225, 180), (150, 120), (15, 12)])
    func theDwellStaysUnderTheDelayUntilRepeat(delay: Double, longest: Double) {
        let dwell = Cadence(keyRepeatDelay: .milliseconds(delay)).dwell
        #expect(abs(dwell.bounds.upperBound - longest) < 1e-9)
        #expect(dwell.bounds.contains(dwell.mean))
        var generator = SeededGenerator(seed: 5)
        for _ in 0 ..< 200 { #expect(dwell.draw(using: &generator) < delay) }
    }

    /// A cancel that lands inside a wait stops the run there: no key after it goes down, the
    /// count says how far it got, and every key is let go.
    @Test func aRunCancelledInAWaitStopsThere() async throws {
        let keyboard = Timed()
        keyboard.clock.cancel(afterSleeps: 5) { withUnsafeCurrentTask { $0?.cancel() } }
        let typist = keyboard.typist()
        let text = try typist.lower("abcdef", on: Self.us)
        let run = Task { @MainActor in try await typist.type(text) }
        let stopped = try await #require(throws: TypingStopped.self) { try await run.value }
        #expect(stopped.cause is CancellationError)
        #expect(stopped.typed == 2)
        #expect(keyboard.log.count == 5)
        #expect(keyboard.log.last?.held == [])
    }
}
