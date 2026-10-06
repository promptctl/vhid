import Keystrokes

/// Presses keystrokes and keeps the score a stopped run has to report.
///
/// A character is several keystrokes - a dead key and the letter it accents, a modifier
/// and the key under it - so a run can stop *inside* one, and which keystrokes had been
/// posted decides both how much is on screen and whether the app is left holding a
/// pending accent. That is the entire content of a failure report, so it is a value that
/// can be driven and read rather than two variables in a run loop.
///
/// Every method that awaits takes the caller's isolation, so the value stays on the actor
/// the run is driven from rather than being sent across a boundary between keystrokes.
/// That is what lets it be a mutable struct at all: there is one owner, and it is whoever
/// started typing. [LAW:no-shared-mutable-globals]
public struct Scribe {
    public let keyboard: any Keyboard
    /// What every key is timed on, and what its waits are drawn from.
    public let timeline: Timeline
    public let randomness: RandomSource
    public let cadence: Cadence
    /// Where every wait is handed once it ends, however it ends. [LAW:nothing-unseen]
    public let traced: @Sendable (Pause) -> Void

    /// What the last keystroke left held, and when its key went down and came up.
    private var last: Cadence.Stroke
    /// How far behind its plan this run is: every report that went out late, after a slow
    /// acknowledgement of the one before, moves every report after it by as much, so a
    /// hold or a settle is never shortened to make up the time.
    private var slip: Duration = .zero

    public init(keyboard: any Keyboard, timeline: Timeline, randomness: RandomSource, cadence: Cadence, traced: @escaping @Sendable (Pause) -> Void) {
        self.keyboard = keyboard
        self.timeline = timeline
        self.randomness = randomness
        self.cadence = cadence
        self.traced = traced
        last = .idle(at: timeline.now(), settle: cadence.settle)
    }

    /// Characters and chords posted and acknowledged. "Posted and acknowledged", not
    /// "typed": the daemon acknowledges reports the driver then drops, so this is an upper
    /// bound on what landed and never a delivery receipt.
    public private(set) var typed = 0

    /// A character whose first keystroke landed and whose last did not. Only a run that
    /// stopped inside a character has one, and the target app is then holding a pending
    /// accent that the next keystroke it receives - a retry, another run, the operator's
    /// own hands - will combine with into some other character. Nothing here can undo a
    /// posted keystroke, so this is said rather than fixed.
    public private(set) var halfTyped: Character?

    /// One change of the keys held, at its time, and the one place this run can be stopped
    /// between reports.
    ///
    /// [LAW:single-enforcer] Every irrevocable act goes through here, and a keystroke is
    /// several of them: an em dash holds Shift and Option before its key, and each of those
    /// is its own report with its own round trip to the daemon. Asking once a keystroke
    /// would leave a window between the modifiers in which a cancelled run kept typing.
    /// The wait before each report is a place a cancelled run stops too: a sleep on a real
    /// clock throws when its task is cancelled.
    ///
    /// **What is asked here is whether this run was cancelled, and nothing else.** A driver
    /// does not decide that a keystroke should not be typed.
    ///
    /// `releaseAll`, on the way out of a stopped run, is deliberately not asked this way. A
    /// release that refuses to run leaves a key down for macOS to repeat into whatever
    /// comes forward next, which is worse than what stopping prevents.
    ///
    /// `composing` is the character a key-down leaves pending in the app - the dead key of
    /// an accented letter, and nothing else. It travels with the call rather than being set
    /// beside it, so the one line that can record a pending accent is the one line that is
    /// ambiguous about whether it happened. [LAW:dataflow-not-control-flow]
    private mutating func make(_ change: Cadence.Change, composing pending: Character?, isolation: isolated (any Actor)? = #isolation) async throws {
        let due = change.at + slip
        try await wait(until: due, for: change.wait)
        try Task.checkCancellation()
        slip += max(timeline.now() - due, .zero)
        // Recorded between the cancellation check and the report, and cleared after the
        // character's last key-down comes back. The two failures are not the same thing and
        // must not report the same thing: a report that throws may still have reached the
        // driver, so its accent is assumed pending rather than assumed away, while a
        // cancellation is a local decision that sent nothing, and reporting an accent for it
        // would tell the operator to clear a composition that is not there.
        if let pending { halfTyped = pending }
        try await keyboard.hold(change.held)
    }

    /// The wait until `due`, handed to `traced` once it ends, however it ends.
    private func wait(until due: Duration, for kind: Cadence.Wait) async throws {
        let began = timeline.now()
        defer { traced(Pause(kind: .keys(kind), length: max(timeline.now() - began, .zero))) }
        try await timeline.sleep(due)
    }

    /// One keystroke: the modifiers the last one held that this one does not need up, this
    /// one's modifiers down, its key down under them and up again, each at its time.
    private mutating func press(_ keystroke: Keystroke, composing: Character?, isolation: isolated (any Actor)? = #isolation) async throws {
        let (changes, left) = randomness.draw { [last] in cadence.press(keystroke, after: last, drawing: &$0) }
        last = left
        for change in changes {
            let keyDown = change.wait == .keyDown
            try await make(change, composing: keyDown ? composing : nil)
            // Counted on the key-down the daemon has acknowledged, not after the release: a
            // failure between the two still put the character on screen, and a count taken
            // after the release would report one fewer than is really there. It is the LAST
            // key-down of the character - the one composing nothing - because a character
            // typed as a dead key and then the letter it accents is not on screen until the
            // second of them.
            //
            // The opposite bias to `halfTyped` above, and deliberately: this count says
            // "posted and acknowledged", which a throw means did not happen, while that says
            // "may be pending", which a throw means it might be.
            if keyDown && composing == nil {
                typed += 1
                halfTyped = nil
            }
        }
    }

    /// A chord: one keystroke that is a whole act, so it composes nothing and counts as
    /// one when its key has gone down.
    public mutating func press(_ keystroke: Keystroke, isolation: isolated (any Actor)? = #isolation) async throws {
        try await press(keystroke, composing: nil)
    }

    /// A character, as the keystrokes the layout says it costs. Every keystroke but the
    /// last leaves the character pending in the app.
    public mutating func type(_ character: Character, _ keystrokes: [Keystroke], isolation: isolated (any Actor)? = #isolation) async throws {
        for (index, keystroke) in keystrokes.enumerated() {
            try await press(keystroke, composing: index == keystrokes.count - 1 ? nil : character)
        }
    }

    /// Every modifier the last keystroke left down comes up, each at its trail: the end of a
    /// run that was not stopped.
    public mutating func finish(isolation: isolated (any Actor)? = #isolation) async throws {
        let changes = randomness.draw { [last] in cadence.finish(after: last, drawing: &$0) }
        last = Cadence.Stroke(modifiers: [], down: last.down, up: changes.last?.at ?? last.up)
        for change in changes { try await make(change, composing: nil) }
    }
}
