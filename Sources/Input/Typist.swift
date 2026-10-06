import KeyboardLayouts
import Keystrokes

/// The one typist: text and chords, lowered to keystrokes and pressed on a keyboard,
/// with every key released again when a run stops.
///
/// Two steps, and the value between them is the proof. `lower` turns text or a chord into
/// keystrokes this typist can press - every character on the layout, every chord the
/// device can hold - and refuses the whole of it before a key goes down. `type` and
/// `press` take only what `lower` returned, so nothing half-proven can reach the
/// keyboard, and a caller with several things to type can lower all of them before typing
/// any. [LAW:parse-dont-validate]
///
/// **What `lower` refuses is what cannot be pressed, and nothing else.** It used to also
/// refuse a keystroke that would press low-talker's dictation hotkey - a real hazard in
/// low-talker, and none of this package's business. A keystroke that means something to
/// some program on this Mac is still a keystroke the device can send, and a client that
/// does not want to send it does not send it. A client with a shortcut of its own to avoid
/// knows which one that is; this does not.
public struct Typist {
    public let keyboard: any Keyboard
    /// What every key is timed on. [LAW:effects-at-boundaries]
    public let timeline: Timeline
    /// What every key's timing is drawn from: the devices' one source, so a verb's keys and
    /// moves draw again from the one seed on its record.
    public let randomness: RandomSource
    public let cadence: Cadence
    /// Where every wait between keys is handed once it ends. [LAW:nothing-unseen]
    public let traced: @Sendable (Pause) -> Void

    public init<C: Clock>(keyboard: any Keyboard, clock: C, randomness: RandomSource, cadence: Cadence = .typist,
                          traced: @escaping @Sendable (Pause) -> Void) where C.Duration == Duration {
        self.keyboard = keyboard
        timeline = Timeline(clock)
        self.randomness = randomness
        self.cadence = cadence
        self.traced = traced
    }

    /// A scribe for one run, timed from now.
    private var scribe: Scribe {
        Scribe(keyboard: keyboard, timeline: timeline, randomness: randomness, cadence: cadence, traced: traced)
    }

    /// Text proven typeable: every character has keys on the layout.
    public struct Text {
        fileprivate let characters: [(character: Character, keystrokes: [Keystroke])]
        /// How many characters the keys will put on screen, which is what `type` counts
        /// against.
        public var count: Int { characters.count }
    }

    /// A chord proven pressable.
    public struct Chord {
        fileprivate let keystroke: Keystroke
    }

    /// [LAW:parse-dont-validate] The whole string is refused rather than typed up to the
    /// first character the layout cannot type - half a sentence in a document is worse
    /// than none, because only one of the two is obviously wrong.
    public func lower(_ text: String, on layout: KeyboardLayout) throws -> Text {
        Text(characters: try layout.typing(text))
    }

    public func lower(_ chord: KeyChord) throws -> Chord {
        Chord(keystroke: try Keystroke(chord: chord))
    }

    /// Types the text and answers with how many characters were posted and acknowledged,
    /// which is `text.count` on every return: a run that stops throws `TypingStopped`
    /// with the count instead.
    @discardableResult
    public func type(_ text: Text, isolation: isolated (any Actor)? = #isolation) async throws -> Int {
        var scribe = scribe
        do {
            for (character, keystrokes) in text.characters { try await scribe.type(character, keystrokes) }
            try await scribe.finish()
        } catch {
            throw TypingStopped(typed: scribe.typed, of: text.count, halfTyped: scribe.halfTyped, cause: error, unreleased: await release())
        }
        return scribe.typed
    }

    /// Presses the chords in order, spaced as a typist's keystrokes are, and answers with
    /// how many were pressed, which is `chords.count` on every return: a run that stops
    /// throws `ChordsStopped` with the count instead.
    @discardableResult
    public func press(_ chords: [Chord], isolation: isolated (any Actor)? = #isolation) async throws -> Int {
        var scribe = scribe
        do {
            for chord in chords { try await scribe.press(chord.keystroke) }
            try await scribe.finish()
        } catch {
            throw ChordsStopped(pressed: scribe.typed, of: chords.count, cause: error, unreleased: await release())
        }
        return scribe.typed
    }

    /// Every key up, on the way out of a run that stopped. A run that stopped inside a
    /// keystroke left that keystroke's modifiers held, and macOS repeats a held key into
    /// whatever comes forward next. The release is not stopped by cancellation, for the
    /// reason `Scribe` gives; what it answers is whether the keys are known to be up.
    /// [LAW:no-silent-failure] A release that fails is reported beside the stop rather
    /// than thrown over it, so the operator is told both.
    private func release(isolation: isolated (any Actor)? = #isolation) async -> (any Error)? {
        await failure(of: keyboard.releaseAll)
    }

}

/// A run that stopped once text was already in the target: the daemon went quiet, the
/// caller cancelled it. What stopped it is the cause; how much is in the
/// document is the part only this knows, and the part the operator has to act on, since
/// text already typed cannot be taken back.
public struct TypingStopped: StoppedPartWay, CustomStringConvertible {
    public let typed: Int
    public let of: Int
    /// The character whose first keystroke landed and whose last did not, when the run
    /// stopped inside one. It is not in the count, because it is not on screen; it is in
    /// the target app as a pending accent, which is a different thing to act on.
    public let halfTyped: Character?
    public let cause: any Error
    /// The failure of the release that followed the stop, when it failed too. Nil says
    /// every key is up; anything else says one may be held, and macOS will repeat it.
    public let unreleased: (any Error)?

    public init(typed: Int, of: Int, halfTyped: Character? = nil, cause: any Error, unreleased: (any Error)? = nil) {
        self.typed = typed
        self.of = of
        self.halfTyped = halfTyped
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String {
        // "Posted and acknowledged", not "typed", and the difference is the whole finding
        // of low-talker's spike: the daemon acknowledges reports the driver then
        // drops, so the count is what left here and an upper bound on what landed, never
        // a delivery receipt. A run interrupted at 445 has been seen to leave 436 in the
        // document.
        let progress = typed < of
            ? "\(typed) of \(of) characters had been posted and acknowledged before this, and the rest were not sent"
            : "all \(of) characters had been posted and acknowledged before this"
        // A dead key posted without the letter after it leaves the app mid-composition,
        // which no reset here can clear and which silently changes the next character
        // that app receives. [LAW:no-silent-failure]
        let pending = halfTyped.map { ", and \(String($0).debugDescription) was left half typed: its accent is pending in the app and will combine with whatever it receives next" } ?? ""
        return Self.unreleased(unreleased, after: cause.reported.then("\(progress)\(pending)"))
    }

    /// `report`, then the same sentences a stopped chord ends with when its release
    /// failed too. [LAW:one-source-of-truth]
    static func unreleased(_ error: (any Error)?, after report: String) -> String {
        error.map { report.then("The keyboard was not released afterwards: \($0.reported)").then("A key may be left held") } ?? report
    }
}

/// A list of chords that stopped part way.
///
/// How many of the list had already gone down is the fact the operator has to act on: a
/// `leftCommand+a` that landed in front of a `delete` that did not has left the document
/// selected, and without the count nothing says so. [LAW:no-silent-failure]
public struct ChordsStopped: StoppedPartWay, CustomStringConvertible {
    public let pressed: Int
    public let of: Int
    public let cause: any Error
    /// The failure of the release that followed the stop, when it failed too.
    public let unreleased: (any Error)?

    public init(pressed: Int, of: Int, cause: any Error, unreleased: (any Error)? = nil) {
        self.pressed = pressed
        self.of = of
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String {
        TypingStopped.unreleased(unreleased, after: cause.reported.then("\(pressed) of \(of) chords had been pressed before this, and the rest were not sent"))
    }
}
