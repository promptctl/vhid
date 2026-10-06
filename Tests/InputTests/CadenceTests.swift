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
        private let state = Mutex<(log: [(ms: Double, held: Set<Usage>)], pauses: [Pause], late: [Duration], rollovers: [Int], hesitations: [Duration])>(([], [], [], [], []))

        var log: [(ms: Double, held: Set<Usage>)] { state.withLock { $0.log } }
        var pauses: [Pause] { state.withLock { $0.pauses } }
        /// Each run's slip, as traced when it ended.
        var late: [Duration] { state.withLock { $0.late } }
        /// Each run's rollovers, as traced when it ended.
        var rollovers: [Int] { state.withLock { $0.rollovers } }
        /// Every run's hesitations, as traced when each ended.
        var hesitations: [Duration] { state.withLock { $0.hesitations } }

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
                    case .ran(let late, let rollovers, let hesitations):
                        $0.late.append(late)
                        $0.rollovers.append(rollovers)
                        $0.hesitations += hesitations
                    }
                }
            })
        }

        /// Each key that went down, in the order it went down, with the modifiers held at
        /// that moment, when it went down and when it came up. Keys may overlap: a typist
        /// rolls over.
        var strokes: [(key: Usage, modifiers: Set<Usage>, down: Double, up: Double)] {
            var strokes: [(key: Usage, modifiers: Set<Usage>, down: Double, up: Double)] = []
            var open: [Usage: Int] = [:]
            var before = Set<Usage>()
            for (ms, held) in log {
                for key in held.subtracting(before) where key.modifierBit == nil {
                    open[key] = strokes.count
                    strokes.append((key, held.filter { $0.modifierBit != nil }, ms, .infinity))
                }
                for key in before.subtracting(held) where key.modifierBit == nil {
                    if let index = open.removeValue(forKey: key) { strokes[index].up = ms }
                }
                before = held
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
            #expect((50 ... 200).contains(stroke.up - stroke.down), "\(character) held \(stroke.up - stroke.down) ms")
            #expect(stroke.modifiers == (character.isUppercase ? [Self.shift] : []), "\(character) under \(stroke.modifiers)")
        }
        for (previous, next) in zip(strokes, strokes.dropFirst()) { #expect(next.down - previous.down >= 60) }
        #expect(Set(strokes.map { $0.up - $0.down }).count == strokes.count)
        #expect(Set(zip(strokes, strokes.dropFirst()).map { $1.down - $0.down }).count == strokes.count - 1)
        #expect(keyboard.log.last?.held == [])
    }

    /// Shift goes down 30-80 ms before the first capital and stays down through "HE", comes
    /// up 20-60 ms after the last key that needed it, and is up 20 ms or more before the l
    /// goes down: a key that needs other modifiers never rolls over.
    @Test func shiftIsHeldThroughACapitalisedRunAndUpBeforeTheNextKey() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist()
        try await typist.type(try typist.lower("HEl", on: Self.us))
        let log = keyboard.log
        let shiftDown = try #require(log.firstIndex { $0.held.contains(Self.shift) })
        let shiftUp = try #require(log.lastIndex { $0.held.contains(Self.shift) }.map { $0 + 1 })
        let strokes = keyboard.strokes
        #expect((30 ... 80).contains(strokes[0].down - log[shiftDown].ms))
        #expect(log[shiftDown ..< shiftUp].allSatisfy { $0.held.contains(Self.shift) }, "shift came up between H and E")
        #expect((20 ... 60).contains(log[shiftUp].ms - max(strokes[0].up, strokes[1].up)))
        #expect(strokes[2].down - log[shiftUp].ms >= 20)
    }

    /// A daemon slow to acknowledge a key-down sends the reports after it late, and the
    /// rest of the run moves with it rather than closing up: no two keys go down closer than
    /// the model's floor, however late the first went out.
    @Test func aSlowAcknowledgementDelaysTheRunRatherThanShorteningIt() async throws {
        let keyboard = Timed(acknowledgingKeys: .milliseconds(150))
        let typist = keyboard.typist()
        let text = "a slow daemon answers every key late"
        try await typist.type(try typist.lower(text, on: Self.us))
        let strokes = keyboard.strokes
        #expect(strokes.count == text.count)
        for (previous, next) in zip(strokes, strokes.dropFirst()) { #expect(next.down - previous.down >= 60) }
        // How late the run went is traced once it ends, and here it went late.
        try #require(keyboard.late.count == 1)
        #expect(keyboard.late[0] > .zero)
    }

    /// A key that rolls over has other reports sent while it is held, and a slow
    /// acknowledgement of any of them holds it longer. Inside the headroom the dwell's cut
    /// leaves under the delay until repeat - 50 ms on a 250 ms Mac - no key is held long
    /// enough to repeat, however many reports its hold spans.
    @Test func aKeyHeldThroughSlowAcknowledgementsStillDoesNotRepeat() async throws {
        for seed in UInt64(1) ... 20 {
            let keyboard = Timed(acknowledgingKeys: .milliseconds(40))
            let typist = keyboard.typist(seed: seed)
            try await typist.type(try typist.lower("the quick brown fox jumps over the lazy dog", on: Self.us))
            for stroke in keyboard.strokes { #expect(stroke.up - stroke.down < 250, "seed \(seed): held \(stroke.up - stroke.down) ms") }
        }
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

    /// Prose planned by the model types in bursts, as `docs/design/human.md`, "Typing",
    /// says a person does: keys held near 116 ms; gaps inside a word shorter than before a
    /// word, and those shorter than after a sentence; a right-skewed spread; a quarter or so
    /// of keys rolling over; and words a minute in a practised typist's range.
    @Test func proseComesInBursts() {
        let passage = String(repeating: "the quick brown fox jumps over the lazy dog, and then it naps. ", count: 40)
        let text = passage.map { character in
            (character: character, keystrokes: [Keystroke(Usage(rawValue: Finger.keys.first { $0.character == character }!.usage))])
        }
        var generator = SeededGenerator(seed: 3)
        let changes = Cadence.typist.type(text, drawing: &generator)
        let downs = changes.filter { $0.wait == .keyDown }
        try! #require(downs.count == text.count)
        let ms = { (duration: Duration) in duration / .milliseconds(1) }
        let gaps = zip(downs, downs.dropFirst()).map { ms($1.at - $0.at) }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let pairs = Array(zip(passage, passage.dropFirst()))
        func between(where place: (Character, Character) -> Bool) -> [Double] {
            pairs.indices.filter { place(pairs[$0].0, pairs[$0].1) }.map { gaps[$0] }
        }
        let inWord = between(where: { $0.isLetter && $1.isLetter })
        let wordStart = between(where: { $0 == " " && $1.isLetter })
        let sentence = between(where: { previous, _ in previous == "." })
        #expect(median(inWord) + 30 < median(wordStart))
        #expect(median(wordStart) + 200 < median(sentence))
        let mean = gaps.reduce(0, +) / Double(gaps.count)
        #expect(mean > median(gaps) + 15, "the spread is skewed right")
        #expect(gaps.allSatisfy { $0 >= 60 })
        let rolledOver = Double(changes.filter(\.rollsOver).count) / Double(downs.count)
        #expect((0.15 ... 0.35).contains(rolledOver), "rolled over on \(rolledOver)")
        let wordsPerMinute = Double(text.count) / 5 / (ms(downs.last!.at - downs.first!.at) / 60_000)
        #expect((55 ... 75).contains(wordsPerMinute), "\(wordsPerMinute) words a minute")
        #expect(changes.contains { $0.hesitation > .zero })
        #expect(changes.last?.held == HeldKeys.none)
    }

    /// A stop or a comma pauses only where whitespace follows it: inside "3.14" and
    /// "1,000" the keys run on as one word's, and the space after a sentence pauses.
    @Test func punctuationPausesOnlyBeforeWhitespace() {
        typealias Place = Cadence.Interval.Place
        #expect(Place("1", after: ".") == .inWord)
        #expect(Place("0", after: ",") == .inWord)
        #expect(Place(" ", after: ".") == .sentence)
        #expect(Place(" ", after: ",") == .clause)
        #expect(Place("\n", after: "x") == .sentence)
        #expect(Place("W", after: " ") == .wordStart)
        #expect(Place("W", after: "\n") == .wordStart)
    }

    /// The first character's later keystrokes are inside it, as every character's are: the
    /// e of a dead-key é that starts the text is never placed as a word's start, so a
    /// one-word text never hesitates, not even between the accent and its letter.
    @Test func aFirstCharactersLaterKeystrokesAreInsideIt() async throws {
        let keyboard = Timed()
        for seed in UInt64(1) ... 100 {
            let typist = keyboard.typist(seed: seed)
            try await typist.type(try typist.lower("\u{e9}t\u{e9}", on: Self.us))
        }
        #expect(keyboard.hesitations == [])
    }

    /// A key that rolls over still never goes down a second time before it is up: the l of
    /// "ll" is up a settle or more before it goes down again.
    @Test func aKeyPressedTwiceIsUpBeforeItGoesDownAgain() async throws {
        for seed in UInt64(1) ... 20 {
            let keyboard = Timed()
            let typist = keyboard.typist(seed: seed)
            try await typist.type(try typist.lower("hello all", on: Self.us))
            let strokes = keyboard.strokes
            for (previous, next) in zip(strokes, strokes.dropFirst()) where previous.key == next.key {
                #expect(next.down - previous.up >= 20, "seed \(seed)")
            }
        }
    }

    /// Typing rolls over, and the run's record hears how often: the count traced when the
    /// run ends is the number of keys that went down while another was held.
    @Test func rolloversAreTracedAsTheyWereSent() async throws {
        let keyboard = Timed()
        let typist = keyboard.typist(seed: 4)
        try await typist.type(try typist.lower("the quick brown fox jumps over the lazy dog", on: Self.us))
        let sent = zip(keyboard.log, keyboard.log.dropFirst()).count { before, after in
            after.held.subtracting(before.held).contains { $0.modifierBit == nil } && after.held.filter { $0.modifierBit == nil }.count > 1
        }
        #expect(sent > 0)
        #expect(keyboard.rollovers == [sent])
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
        #expect(strokes[1].down - strokes[0].down >= 60)
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
        #expect(dwell.bounds.contains(dwell.median))
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
