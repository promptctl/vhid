import Keystrokes

/// How a typist's keys are timed: each key held for a dwell time, one key-down to the next
/// an interval apart that depends on the two keys and where they fall in the text, and the
/// modifiers a keystroke needs down before its key and up after it. `docs/design/human.md`,
/// "Typing".
///
/// [LAW:effects-at-boundaries] This only plans: given a run's keystrokes, it says when every
/// key goes down and comes up. `Scribe` sleeps until each change and posts it. A run is
/// planned whole, not a keystroke at a time, because with rollover a key's release can come
/// after the next key goes down.
public struct Cadence: Sendable, Equatable {
    /// From one key-down to the next.
    public let interval: Interval
    /// A key held down: its dwell time.
    public let dwell: LogNormal
    /// How long before its key a modifier goes down, in milliseconds, drawn evenly.
    public let lead: ClosedRange<Double>
    /// How long after the last key that needed it a modifier comes up, in milliseconds,
    /// drawn evenly.
    public let trail: ClosedRange<Double>
    /// The least time from the last key up to a key that cannot roll over going down, and
    /// from a key up to the same key down again.
    public let settle: Duration

    /// The share of the delay until a held key repeats that a key may be held for.
    static let withinRepeat = 0.8

    /// A practised typist on a Mac whose delay until a held key repeats is 250 ms or longer,
    /// which leaves the dwell uncut.
    public static let typist = Cadence(keyRepeatDelay: .milliseconds(250))

    /// A practised typist on a Mac whose held key repeats after `keyRepeatDelay`.
    ///
    /// The dwell is cut off at 200 ms, and lower, at 80% of the delay, on a Mac set shorter
    /// than 250 ms, as `defaults write -g InitialKeyRepeat` can from the next login: a long
    /// draw never holds a key long enough to type its character twice. The 20% left over is
    /// what acknowledgements may take: a key that rolls over has other reports sent while it
    /// is held, and its key-up waits behind theirs, so an acknowledgement slower than that -
    /// 50 ms on a 250 ms Mac - can repeat it. Below that the whole distribution shrinks with
    /// it, as `Hand`'s does.
    public init(keyRepeatDelay: Duration) {
        let dwell = LogNormal(median: 114, sigma: 0.2, within: 50 ... 200)
        let longest = Self.withinRepeat * (keyRepeatDelay / .milliseconds(1))
        let scale = min(1, longest / dwell.bounds.upperBound)
        self.init(interval: .typist, dwell: dwell.scaled(by: scale, floor: 0), lead: 30 ... 80, trail: 20 ... 60, settle: .milliseconds(20))
    }

    init(interval: Interval, dwell: LogNormal, lead: ClosedRange<Double>, trail: ClosedRange<Double>, settle: Duration) {
        self.interval = interval
        self.dwell = dwell
        self.lead = lead
        self.trail = trail
        self.settle = settle
    }

    /// The gap from one key-down to the next: a median set by the pair of keys and by where
    /// the second falls in the text, and a right-skewed spread around it. Milliseconds.
    public struct Interval: Sendable, Equatable {
        /// Between two keys of a word on one hand, under different fingers.
        public let withinWord: Double
        /// Added for a pair split between the hands (quicker, so negative), for two keys
        /// under one finger, and for one key pressed twice.
        let alternation: Double, sameFinger: Double, repeated: Double
        /// Added before a word's first letter (word initiation), on the space after a comma,
        /// semicolon or colon, and on the space after the end of a sentence or on a line break.
        let wordStart: Double, clause: Double, sentence: Double
        /// Each word's pace: a factor on the gaps inside it, so some words run fast and
        /// others slow.
        let pace: LogNormal
        /// The spread of each gap around its median, as a log-normal's sigma, and the floor
        /// no gap goes under.
        let sigma: Double, floor: Double
        /// How often a word is preceded by a hesitation, and how long one is.
        let hesitationChance: Double, hesitation: LogNormal

        public static let typist = Interval(withinWord: 155, alternation: -20, sameFinger: 60, repeated: 25,
                                            wordStart: 60, clause: 150, sentence: 350,
                                            pace: LogNormal(median: 1, sigma: 0.2, within: 0.6 ... 1.6), sigma: 0.3, floor: 60,
                                            hesitationChance: 1.0 / 16, hesitation: LogNormal(median: 400, sigma: 0.4, within: 150 ... 1500))

        /// Where a keystroke falls in the text, which decides what its gap adds and whether
        /// its word's pace applies.
        public enum Place: Sendable, Equatable {
            /// Inside a word, or a later keystroke of one character: paced by its word.
            case inWord
            /// A space, or a key with no words around it, as a chord is.
            case outsideWord
            case wordStart, clause, sentence

            /// The place of `character`'s first keystroke, typed after `previous`. A stop or
            /// a comma pauses only where whitespace follows it, so "3.14", "1,000" and
            /// "example.com" are each typed as one word.
            init(_ character: Character, after previous: Character) {
                self = if character.isNewline || character.isWhitespace && ".!?".contains(previous) { .sentence }
                    else if character.isWhitespace { ",;:".contains(previous) ? .clause : .outsideWord }
                    else { previous.isWhitespace ? .wordStart : .inWord }
            }
        }

        /// The milliseconds a pair adds to the median: a key pressed twice, two keys under
        /// one finger, a pair split between the hands. A key off the typing block has no
        /// finger, and its pairs add nothing.
        func pair(_ previous: Usage, _ key: Usage) -> Double {
            switch (previous == key, Finger(previous), Finger(key)) {
            case (true, _, _): repeated
            case let (_, a?, b?) where a == b: sameFinger
            case let (_, a?, b?) where a.hand != b.hand: alternation
            default: 0
            }
        }

        /// The gap before `key`, pressed after `previous` at `place` in a word going at
        /// `pace`, and the hesitation in it, zero for none. Every draw is taken every time,
        /// so one seed lays out a run the same way whatever its text.
        /// [LAW:dataflow-not-control-flow]
        func draw(_ key: Usage, after previous: Usage, at place: Place, pace: Double,
                  using generator: inout some RandomNumberGenerator) -> (gap: Duration, hesitation: Duration) {
            let added = switch place {
            case .inWord, .outsideWord: 0.0
            case .wordStart: wordStart
            case .clause: clause
            case .sentence: sentence
            }
            let median = (withinWord + pair(previous, key)) * (place == .inWord ? pace : 1) + added
            let gap = LogNormal(median: median, sigma: sigma, within: floor ... .infinity).draw(using: &generator)
            let pause = hesitation.draw(using: &generator)
            let coin = Double.random(in: 0 ..< 1, using: &generator)
            let hesitated = Duration.milliseconds(place == .wordStart && coin < hesitationChance ? pause : 0)
            return (.milliseconds(gap) + hesitated, hesitated)
        }
    }

    /// What a typist waits for: the report a wait ends in.
    public enum Wait: String, Sendable {
        case modifierDown = "modifier_down"
        case keyDown = "key_down"
        case keyUp = "key_up"
        case modifierUp = "modifier_up"
    }

    /// What a report puts in the app: nothing, a dead key's accent left pending until the
    /// letter it accents, or a character typed (or a chord pressed).
    public enum Landing: Equatable, Sendable {
        case nothing
        case pending(Character)
        case typed
    }

    /// One report: the keys held from `at` on, measured from the start of the run, the wait
    /// it ends, what it puts in the app, and the hesitation drawn into the gap before its
    /// key goes down, zero for none and for every report but a key-down.
    public struct Change: Equatable, Sendable {
        public let at: Duration
        public let held: HeldKeys
        public let wait: Wait
        public let lands: Landing
        public let hesitation: Duration

        /// A key going down while another is still held.
        public var rollsOver: Bool {
            wait == .keyDown && held.usages.filter { $0.modifierBit == nil }.count > 1
        }
    }

    /// The changes that type `text`, character by character, and let go of every modifier
    /// at the end.
    public func type(_ text: [(character: Character, keystrokes: [Keystroke])], drawing generator: inout some RandomNumberGenerator) -> [Change] {
        // The text is taken as following a space: its first word starts a word.
        let strokes = text.indices.flatMap { index in
            let (character, keystrokes) = text[index]
            let place = Interval.Place(character, after: index == 0 ? " " : text[index - 1].character)
            return keystrokes.indices.map { offset in
                Stroke(keystroke: keystrokes[offset], place: offset > 0 ? .inWord : place,
                       lands: offset == keystrokes.count - 1 ? .typed : .pending(character), wholeAct: false)
            }
        }
        return plan(strokes, drawing: &generator)
    }

    /// The changes that press `chords` in order, each a whole act that lets go of its
    /// modifiers before the next: `leftCommand+tab` twice is two app switches, not a
    /// Command held through both.
    public func press(_ chords: [Keystroke], drawing generator: inout some RandomNumberGenerator) -> [Change] {
        plan(chords.map { Stroke(keystroke: $0, place: .outsideWord, lands: .typed, wholeAct: true) }, drawing: &generator)
    }

    /// One keystroke to plan, where it falls, what its key-down puts in the app, and whether
    /// it is a whole act, as a chord is.
    private struct Stroke {
        let keystroke: Keystroke
        let place: Interval.Place
        let lands: Landing
        let wholeAct: Bool
    }

    /// A key or a modifier going down or coming up.
    private struct Event {
        let at: Duration
        let usage: Usage
        let down: Bool
        let wait: Wait
        let lands: Landing
        var hesitation = Duration.zero
    }

    /// Each key goes down its drawn gap after the last, and no sooner than a settle after the
    /// same key last came up. It may go down while the last key is held - rollover - unless
    /// it needs other modifiers than the last, or either is a whole act: then every key is up
    /// first, the modifiers it does not need come up their trails after that, and it goes
    /// down a settle and its longest lead later, its new modifiers their leads before it.
    private func plan(_ strokes: [Stroke], drawing generator: inout some RandomNumberGenerator) -> [Change] {
        var events: [Event] = []
        var modifiers = Modifiers()
        var last: (key: Usage, down: Duration, wholeAct: Bool)?
        // When every key so far is up; before the first, a settle before the run's start, so
        // the first key may go down at once.
        var allUp = Duration.zero - settle
        var upOf: [Usage: Duration] = [:]
        var pace = 1.0
        func lift(_ lifted: Modifiers) -> [Event] {
            lifted.usages.map { Event(at: allUp + .milliseconds(Double.random(in: trail, using: &generator)), usage: $0, down: false, wait: .modifierUp, lands: .nothing) }
                .sorted { $0.at < $1.at }
        }
        for stroke in strokes {
            let key = stroke.keystroke.usage
            let drawnPace = interval.pace.draw(using: &generator)
            pace = stroke.place == .wordStart ? drawnPace : pace
            let (gap, hesitation) = last.map { interval.draw(key, after: $0.key, at: stroke.place, pace: pace, using: &generator) } ?? (.zero, .zero)
            let held = Duration.milliseconds(dwell.draw(using: &generator))
            let lifted = lift(modifiers.subtracting(stroke.keystroke.modifiers))
            let added = stroke.keystroke.modifiers.subtracting(modifiers).usages
                .map { (usage: $0, lead: Duration.milliseconds(Double.random(in: lead, using: &generator))) }
                .sorted { $0.lead > $1.lead }
            let rollsOver = modifiers == stroke.keystroke.modifiers && !stroke.wholeAct && !(last?.wholeAct ?? false)
            let released = lifted.last?.at ?? allUp
            let down = [last.map { $0.down + gap } ?? allUp + settle,
                        rollsOver ? nil : released + settle + (added.first?.lead ?? .zero),
                        upOf[key].map { $0 + settle }].compactMap { $0 }.max()!
            events += lifted
            events += added.map { Event(at: down - $0.lead, usage: $0.usage, down: true, wait: .modifierDown, lands: .nothing) }
            events.append(Event(at: down, usage: key, down: true, wait: .keyDown, lands: stroke.lands, hesitation: hesitation))
            events.append(Event(at: down + held, usage: key, down: false, wait: .keyUp, lands: .nothing))
            modifiers = stroke.keystroke.modifiers
            last = (key, down, stroke.wholeAct)
            allUp = max(allUp, down + held)
            upOf[key] = down + held
            if stroke.wholeAct {
                let letGo = lift(modifiers)
                events += letGo
                allUp = letGo.last.map { max(allUp, $0.at) } ?? allUp
                modifiers = []
            }
        }
        events += lift(modifiers)
        // Ordered by time; two events drawn at the same instant keep the order they were made in.
        var keys = Set<Usage>()
        return events.indices.sorted { (events[$0].at, $0) < (events[$1].at, $1) }.map { index in
            let event = events[index]
            if event.down { keys.insert(event.usage) } else { keys.remove(event.usage) }
            // At most four keys are ever down at once - a 200 ms hold over 60 ms gaps - far
            // under the 32 a report carries.
            return Change(at: event.at, held: try! HeldKeys(keys), wait: event.wait, lands: event.lands, hesitation: event.hesitation)
        }
    }

    /// The mean gap from one key-down to the next over a passage of prose, by planning one:
    /// the figure `vhid help type` quotes, read off the model rather than restated.
    /// [LAW:one-source-of-truth]
    public var proseInterval: Duration {
        let passage = String(repeating: "the quick brown fox jumps over the lazy dog, and then it naps. ", count: 30)
        let text = passage.map { character in
            (character: character, keystrokes: [Keystroke(Usage(rawValue: Finger.keys.first { $0.character == character }!.usage))])
        }
        var generator = SeededGenerator(seed: 0)
        let downs = type(text, drawing: &generator).filter { $0.wait == .keyDown }.map(\.at)
        return (downs.last! - downs.first!) / (downs.count - 1)
    }
}
