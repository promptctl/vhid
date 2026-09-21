import KeyboardLayout
import Keystrokes
import Testing
@testable import Input

/// The typist against a keyboard the test plays, on the installed US layout.
@Suite @MainActor struct TypistTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")

    @Test func textIsTypedCharacterByCharacterAndCounted() async throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard)
        let text = try typist.lower("aB", on: Self.us)
        #expect(text.count == 2)
        #expect(try await typist.type(text) == 2)
        #expect(keyboard.log == ["down 4", "up", "down e1", "down 5", "up"])
    }

    @Test func nothingIsTypedForNothing() async throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard)
        #expect(try await typist.type(try typist.lower("", on: Self.us)) == 0)
        #expect(keyboard.log.isEmpty)
    }

    /// The layout's refusal comes back as it is, before any key: nothing was typed, so
    /// there is no count to carry.
    @Test func textTheLayoutCannotTypeIsRefusedWhole() {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard)
        #expect(throws: UntypeableCharacters.self) { try typist.lower("a\u{1F600}", on: Self.us) }
        #expect(keyboard.log.isEmpty)
    }

    @Test func aChordIsPressedAsOneKeystroke() async throws {
        let keyboard = RefusingKeyboard()
        let typist = Typist(keyboard: keyboard)
        try await typist.press(try typist.lower(KeyChord(key: Key(rawValue: 0x24))))
        #expect(keyboard.log == ["down 28", "up"])
    }

    /// A run that stops is reported with its count, and the keys are released on the way
    /// out: the modifiers of the keystroke it stopped inside would otherwise stay held.
    @Test func aStoppedRunReleasesTheKeysAndReportsTheCount() async throws {
        let keyboard = StuckKeyboard()
        let typist = Typist(keyboard: keyboard)
        let text = try typist.lower("abc", on: Self.us)
        let stopped = try await #require(throws: TypingStopped.self) { try await typist.type(text) }
        #expect(stopped.typed == 0)
        #expect(stopped.of == 3)
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased == nil)
        #expect(keyboard.log == ["down 4", "up"])
        #expect(!"\(stopped)".contains("not released"))
    }

    /// A release that fails after the stop is said beside the stop, not instead of it:
    /// the operator is told the count and that a key may be held.
    @Test func aReleaseThatFailsAfterTheStopIsReported() async throws {
        let keyboard = RefusingKeyboard()
        keyboard.allow = 2
        let typist = Typist(keyboard: keyboard)
        let stopped = try await #require(throws: TypingStopped.self) { try await typist.type(try typist.lower("ab", on: Self.us)) }
        #expect(stopped.typed == 1)
        #expect(stopped.of == 2)
        #expect(stopped.unreleased is Refused)
        #expect("\(stopped)".hasSuffix("The keyboard was not released afterwards: Refused(). A key may be left held"))
    }

    @Test func aStoppedChordReleasesTheKeysToo() async throws {
        let keyboard = StuckKeyboard()
        let typist = Typist(keyboard: keyboard)
        let chord = try typist.lower(KeyChord(key: Key(rawValue: 0x00), modifiers: [.leftCommand]))
        let stopped = try await #require(throws: ChordStopped.self) { try await typist.press(chord) }
        #expect(stopped.cause is Refused)
        #expect(stopped.unreleased == nil)
        #expect(keyboard.log == ["down e3", "up"])
    }
}

/// The report a stopped run makes. It has been wrong twice - once claiming nothing was
/// typed when a fragment was already in the document, once saying "the rest were not"
/// about a run where there was no rest - so what it says is checked rather than read.
@Suite struct TypingStoppedTests {
    @Test func aRunStoppedPartWaySaysHowMuchLandedAndThatTheRestDidNot() {
        let stopped = TypingStopped(typed: 34, of: 500, cause: WentQuiet())
        #expect("\(stopped)" == "the daemon did not answer. 34 of 500 characters had been posted and acknowledged before this, and the rest were not sent")
    }

    /// The same failure after the last keystroke is a different fact, and claiming a
    /// remainder that does not exist is how the first version of this misled.
    @Test func aRunStoppedAfterTheLastKeystrokeClaimsNoRemainder() {
        let stopped = TypingStopped(typed: 40, of: 40, cause: WentQuiet())
        #expect("\(stopped)" == "the daemon did not answer. all 40 characters had been posted and acknowledged before this")
    }

    /// The one cause with no words of its own. Interpolated raw it reads
    /// `CancellationError()` at the head of a sentence an operator has to act on, so it is
    /// named instead - and named once, so every stopped run says it the same way.
    @Test func aCancelledRunIsNamedRatherThanPrintedAsItsType() {
        let stopped = TypingStopped(typed: 12, of: 40, cause: CancellationError())
        #expect("\(stopped)".hasPrefix("the run was cancelled. 12 of 40 characters"))
        #expect("\(PointingStopped(cause: CancellationError()))" == "the run was cancelled")
    }

    /// A run that stopped between a dead key and the letter it accents left the target app
    /// holding a pending accent. It is not in the count - it is not on screen - and it is
    /// not nothing either: the next keystroke that app receives combines with it.
    @Test func aRunStoppedInsideACharacterSaysWhatIsPendingInTheApp() {
        let stopped = TypingStopped(typed: 12, of: 40, halfTyped: "\u{e9}", cause: Refused())
        #expect("\(stopped)".contains("12 of 40 characters"))
        #expect("\(stopped)".contains("was left half typed"))
        #expect("\(stopped)".contains("\u{e9}"))
    }

    /// Every other stop is between characters, and saying nothing about a pending accent
    /// is the truth there. A report that hedged on every run would be read past.
    @Test func aRunStoppedBetweenCharactersSaysNothingAboutPendingAccents() {
        let stopped = TypingStopped(typed: 12, of: 40, cause: Refused())
        #expect(!"\(stopped)".contains("half typed"))
    }
}

/// A daemon that took a report and never answered: a cause with words of its own, so
/// these assert the sentence around it rather than Swift's name for a type.
private struct WentQuiet: Error, CustomStringConvertible {
    var description: String { "the daemon did not answer" }
}
