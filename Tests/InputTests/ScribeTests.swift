import Keystrokes
import Synchronization
import Testing
import Input

/// What a run reports when it stops inside a character.
///
/// Two counts that move in opposite directions and must not be swapped: `typed` says
/// "posted and acknowledged", so a throw means it did not happen; `halfTyped` says "may be
/// pending in the app", so a throw means it might have. Every case below is a stop at a
/// different point in the same two-keystroke character.
@Suite @MainActor struct ScribeTests {
    /// Option-E then E: the shape of every accented character.
    static let acute = [Keystroke(Usage(rawValue: 0x08), .leftOption), Keystroke(Usage(rawValue: 0x08))]
    /// Shift-Option-hyphen: one keystroke, two modifiers, the em dash's shape.
    static let emDash = [Keystroke(Usage(rawValue: 0x2d), [.leftShift, .leftOption])]

    private func scribe(allowing calls: Int = .max) -> (Scribe, RefusingKeyboard) {
        let keyboard = RefusingKeyboard()
        keyboard.allow = calls
        return (Scribe.on(keyboard), keyboard)
    }

    @Test func aCharacterIsPressedAndReleasedInThatOrder() async throws {
        var (scribe, keyboard) = scribe()
        try await scribe.type("a", [Keystroke(Usage(rawValue: 0x04))])
        #expect(keyboard.log == ["hold [4]", "hold []"])
        #expect(scribe.typed == 1)
        #expect(scribe.halfTyped == nil)
    }

    /// Every modifier goes down before the key it modifies, one report each, and the key
    /// comes up under them; the modifiers stay down for whatever comes next, and come up
    /// when the run finishes.
    @Test func theModifiersOfAKeystrokeGoDownBeforeItAndUpAfterIt() async throws {
        var (scribe, keyboard) = scribe()
        try await scribe.type("\u{2014}", Self.emDash)
        // Which of the two goes down first is the draw of their leads.
        #expect(["hold [e1]", "hold [e2]"].contains(keyboard.log[0]))
        #expect(Array(keyboard.log.dropFirst()) == ["hold [e1 e2]", "hold [2d e1 e2]", "hold [e1 e2]"])
        #expect(scribe.typed == 1)
        try await scribe.finish()
        #expect(keyboard.log.last == "hold []")
        #expect(keyboard.log.count == 6)
    }

    /// A chord is one keystroke pressed the same way a character's is, and it composes
    /// nothing: pressed, it counts, and nothing is pending.
    @Test func aChordIsPressedLikeAKeystrokeAndLeavesNothingPending() async throws {
        var (scribe, keyboard) = scribe()
        try await scribe.press(Keystroke(Usage(rawValue: 0x04), [.leftCommand, .leftShift]))
        #expect(Array(keyboard.log.dropFirst()) == ["hold [e1 e3]", "hold [4 e1 e3]", "hold [e1 e3]"])
        #expect(scribe.typed == 1)
        #expect(scribe.halfTyped == nil)
    }

    /// An accented letter is two keystrokes and three keys: the Option that makes the dead
    /// key, the dead key under it, then the letter on its own, with Option up before it.
    /// Each change is its own report with its own round trip to the daemon.
    @Test func anAccentedLetterIsTwoKeystrokesAndThreeKeys() async throws {
        var (scribe, keyboard) = scribe()
        try await scribe.type("\u{e9}", Self.acute)
        #expect(keyboard.log == ["hold [e2]", "hold [8 e2]", "hold [e2]", "hold []", "hold [8]", "hold []"])
    }

    /// **Cancellation is asked before every report, not once a character or even once a
    /// keystroke.** Each change is its own report, so the window in which a cancelled run
    /// keeps typing has to be one report wide: aimed at the first key of a three-key
    /// character, exactly one key goes down and the other two do not.
    ///
    /// And what it reports: a cancellation is a decision taken here, before any report
    /// leaves - unlike a `down` that throws, which may have reached the driver anyway - so
    /// the dead key is not pending in the app and the run must not say it is. An operator
    /// told to clear a composition that is not there will clear something else.
    ///
    /// The release is not asked this way, and that is not an oversight: a release that
    /// refused to run would leave a key held for macOS to repeat.
    @Test func aRunCancelledBetweenTwoKeysOfOneCharacterStopsAtOnceAndSaysNothingIsPending() async {
        let keyboard = CancellingKeyboard(afterReports: 1)
        let outcome = Mutex<(typed: Int, halfTyped: Character?)>((-1, nil))
        let run = Task { @MainActor in
            var scribe = Scribe.on(keyboard)
            defer { outcome.withLock { $0 = (scribe.typed, scribe.halfTyped) } }
            try await scribe.type("\u{e9}", Self.acute)
        }
        keyboard.aim(at: run)
        await #expect(throws: CancellationError.self) { try await run.value }
        #expect(keyboard.log == ["hold [e2]"])
        #expect(outcome.withLock { $0.typed } == 0)
        #expect(outcome.withLock { $0.halfTyped } == nil)
    }

    /// Refused before anything was posted: nothing is on screen and nothing is pending, so
    /// both counts stay where they were.
    @Test func aRunRefusedBeforeItsFirstKeystrokeLeavesNothingBehind() async {
        var (scribe, _) = scribe(allowing: 0)
        await #expect(throws: Refused.self) { try await scribe.type("\u{e9}", Self.acute) }
        #expect(scribe.typed == 0)
        #expect(scribe.halfTyped == nil)
    }

    /// The dead key may have been posted and the letter was not, at each of the four
    /// points where that can happen: the dead key's own key-down, its release, Option's
    /// release, and the letter's key-down. The app may be holding an accent in all four, so
    /// all four say so.
    @Test func aCharacterStoppedBeforeItsLastKeystrokeIsHalfTyped() async {
        for stoppedAfter in [1, 2, 3, 4] {
            var (scribe, _) = scribe(allowing: stoppedAfter)
            await #expect(throws: Refused.self) { try await scribe.type("\u{e9}", Self.acute) }
            #expect(scribe.typed == 0, "stopped after \(stoppedAfter) calls")
            #expect(scribe.halfTyped == "\u{e9}", "stopped after \(stoppedAfter) calls")
        }
    }

    /// The last key-down was acknowledged, so the character is on screen even though the
    /// release that follows it failed. Counted, and no longer pending.
    @Test func aCharacterStoppedAfterItsLastKeystrokeIsTypedAndNotPending() async {
        var (scribe, _) = scribe(allowing: 5)
        await #expect(throws: Refused.self) { try await scribe.type("\u{e9}", Self.acute) }
        #expect(scribe.typed == 1)
        #expect(scribe.halfTyped == nil)
    }

    /// A modifier that would not go down leaves nothing pending: no key of the character
    /// was posted, so there is no accent in the app to combine with the next one.
    /// `halfTyped` is recorded between the modifiers and the key, which is where the
    /// pending accent begins, and the em dash's second modifier is before that line.
    @Test func aKeystrokeStoppedAmongItsModifiersLeavesNothingPending() async {
        var (dash, _) = scribe(allowing: 1)
        await #expect(throws: Refused.self) { try await dash.type("\u{2014}", Self.emDash) }
        #expect(dash.typed == 0)
        #expect(dash.halfTyped == nil)
    }

    /// The count carries across characters, and a stop mid-way reports the ones already
    /// posted rather than starting over.
    @Test func theCountIsOfTheRunAndNotOfOneCharacter() async throws {
        var (scribe, keyboard) = scribe()
        for character in "abc" { try await scribe.type(character, [Keystroke(Usage(rawValue: 0x04))]) }
        #expect(scribe.typed == 3)
        keyboard.allow = keyboard.log.count + 3
        await #expect(throws: Refused.self) { try await scribe.type("\u{e9}", Self.acute) }
        #expect(scribe.typed == 3)
        #expect(scribe.halfTyped == "\u{e9}")
    }
}
