import Keystrokes

/// How a typist's keys are timed: each key held for a dwell time, one key-down to the next
/// a down-down latency apart, and the modifiers a keystroke needs down before its key and
/// up after it. `docs/design/human.md`, "Typing".
///
/// [LAW:effects-at-boundaries] This only plans: given what the last keystroke left held, it
/// says when each key goes down and comes up for the next one. `Scribe` sleeps until each
/// change and posts it.
public struct Cadence: Sendable, Equatable {
    /// From one key-down to the next.
    public let latency: Normal
    /// A key held down: its dwell time.
    public let dwell: Normal
    /// How long before its key a modifier goes down, in milliseconds, drawn evenly.
    public let lead: ClosedRange<Double>
    /// How long after its key a modifier comes up, in milliseconds, drawn evenly.
    public let trail: ClosedRange<Double>
    /// The least time from a keystroke's last key up to the next keystroke's first key down.
    public let settle: Duration

    /// The share of the delay until a held key repeats that a key may be held for.
    static let withinRepeat = 0.8

    /// A practised typist, at about 67 words a minute, on a Mac whose delay until a held key
    /// repeats is 250 ms or longer, which leaves the dwell uncut.
    public static let typist = Cadence(keyRepeatDelay: .milliseconds(250))

    /// A practised typist on a Mac whose held key repeats after `keyRepeatDelay`.
    ///
    /// The dwell is cut off at 200 ms, and lower, at 80% of the delay, on a Mac set shorter
    /// than 250 ms, as `defaults write -g InitialKeyRepeat` can from the next login: a long
    /// draw, or a key-up sent late behind a slow acknowledgement, never holds a key long
    /// enough to type its character twice. Below that the whole distribution shrinks with it, as `Hand`'s does.
    public init(keyRepeatDelay: Duration) {
        let dwell = Normal(95, 25, within: 40 ... 200)
        let longest = Self.withinRepeat * (keyRepeatDelay / .milliseconds(1))
        let scale = min(1, longest / dwell.bounds.upperBound)
        self.init(latency: Normal(180, 60, within: 70 ... .infinity), dwell: dwell.scaled(by: scale, floor: 0),
                  lead: 30 ... 80, trail: 20 ... 60, settle: .milliseconds(20))
    }

    init(latency: Normal, dwell: Normal, lead: ClosedRange<Double>, trail: ClosedRange<Double>, settle: Duration) {
        self.latency = latency
        self.dwell = dwell
        self.lead = lead
        self.trail = trail
        self.settle = settle
    }

    /// What a typist waits for: the report a wait ends in.
    public enum Wait: String, Sendable {
        case modifierDown = "modifier_down"
        case keyDown = "key_down"
        case keyUp = "key_up"
        case modifierUp = "modifier_up"
    }

    /// One report: the keys held from `at` on, and the wait it ends.
    public struct Change: Equatable, Sendable {
        public let at: Duration
        public let held: HeldKeys
        public let wait: Wait
    }

    /// What a keystroke leaves behind for the next: the modifiers still down, and when its
    /// key went down and came up. Before the first keystroke no key has gone down.
    public struct Stroke: Equatable, Sendable {
        let modifiers: Modifiers
        let down: Duration?
        let up: Duration

        /// Nothing held, as of `now`: the first keystroke's first key may go down at once.
        public static func idle(at now: Duration, settle: Duration) -> Stroke {
            Stroke(modifiers: [], down: nil, up: now - settle)
        }
    }

    /// The changes that press `keystroke` after `last`, and what it leaves for the next.
    ///
    /// The modifiers `last` held that this keystroke does not need come up first, each its
    /// trail after `last`'s key; the ones it shares stay down, as a hand holds Shift through
    /// a capitalised word. This keystroke's key goes down a latency after `last`'s, or its
    /// longest lead after the settle that follows those releases, whichever is later; its
    /// new modifiers go down their leads before it. So keys never overlap, and no modifier
    /// is down on a key that did not ask for it.
    func press(_ keystroke: Keystroke, after last: Stroke, drawing generator: inout some RandomNumberGenerator) -> (changes: [Change], left: Stroke) {
        let lifted = lift(last.modifiers.subtracting(keystroke.modifiers), after: last, drawing: &generator)
        let released = lifted.last?.at ?? last.up
        let latency = Duration.milliseconds(latency.draw(using: &generator))
        let dwell = Duration.milliseconds(dwell.draw(using: &generator))
        let added = keystroke.modifiers.subtracting(last.modifiers).usages
            .map { (usage: $0, lead: Duration.milliseconds(Double.random(in: lead, using: &generator))) }
            .sorted { $0.lead > $1.lead }
        let down = max(last.down.map { $0 + latency } ?? released, released + settle + (added.first?.lead ?? .zero))
        var held = last.modifiers.intersection(keystroke.modifiers)
        let pressed = added.map { modifier in
            held.formUnion(Modifiers([modifier.usage]))
            return Change(at: down - modifier.lead, held: HeldKeys(held), wait: .modifierDown)
        }
        return (lifted + pressed + [Change(at: down, held: HeldKeys(keystroke.modifiers, pressing: keystroke.usage), wait: .keyDown),
                                    Change(at: down + dwell, held: HeldKeys(keystroke.modifiers), wait: .keyUp)],
                Stroke(modifiers: keystroke.modifiers, down: down, up: down + dwell))
    }

    /// The changes that let go of every modifier `last` still holds, once a run is done.
    func finish(after last: Stroke, drawing generator: inout some RandomNumberGenerator) -> [Change] {
        lift(last.modifiers, after: last, drawing: &generator)
    }

    /// `modifiers` up, each its trail after `last`'s key, earliest first.
    private func lift(_ modifiers: Modifiers, after last: Stroke, drawing generator: inout some RandomNumberGenerator) -> [Change] {
        var held = last.modifiers
        return modifiers.usages
            .map { (usage: $0, at: last.up + .milliseconds(Double.random(in: trail, using: &generator))) }
            .sorted { $0.at < $1.at }
            .map { modifier in
                held.subtract(Modifiers([modifier.usage]))
                return Change(at: modifier.at, held: HeldKeys(held), wait: .modifierUp)
            }
    }
}
