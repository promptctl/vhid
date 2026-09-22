import Input
import KeyboardLayout
import Pointing
import Testing
@testable import vhid

/// What each verb does with the devices, and what it says afterwards. No daemon, no
/// driver, no root: the devices record instead of acting. [LAW:behavior-not-structure]
@Suite struct VerbTests {
    /// A named layout rather than whichever one this Mac is switched to, so which key `s`
    /// is on is a fact of the test rather than of the machine.
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")

    // MARK: type

    @Test func typeReportsTheCharactersItPosted() async throws {
        let keyboard = RecordingKeyboard()
        let said = try await TypeCommand.type("abc", on: Self.us, with: Typist(keyboard: keyboard))
        #expect(said == "typed 3 characters on \(Self.us.name)")
        #expect(keyboard.down.count >= 3)
    }

    /// The whole string is refused rather than typed up to the first character the layout
    /// cannot type: half a sentence in a document is worse than none, because only one of
    /// the two is obviously wrong.
    @Test func textTheLayoutCannotTypeMovesNothing() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: (any Error).self) {
            try await TypeCommand.type("ab日", on: Self.us, with: Typist(keyboard: keyboard))
        }
        #expect(keyboard.down.isEmpty, "the refusal came after keys had already gone down")
    }

    /// A run that stops part way says how far it got, and the count is of what was posted
    /// rather than of what was asked for. [LAW:no-silent-failure]
    @Test func aStoppedRunSaysHowMuchWasTyped() async throws {
        let keyboard = RecordingKeyboard(failingAtKey: 2)
        let stopped = await #expect(throws: TypingStopped.self) {
            try await TypeCommand.type("abcd", on: Self.us, with: Typist(keyboard: keyboard))
        }
        #expect(stopped?.of == 4)
        #expect((stopped?.typed ?? 4) < 4)
    }

    // MARK: keys

    @Test func keysPressesEveryChordAndNamesThemBack() async throws {
        let keyboard = RecordingKeyboard()
        let said = try await KeysCommand.press(["leftCommand+s", "return"], on: Self.us, with: Typist(keyboard: keyboard))
        #expect(said.hasPrefix("pressed 2 chords on \(Self.us.name): "))
        // Reported in the spelling that reads back, not the one that was typed.
        #expect(said.contains("leftCommand+key 0x"))
    }

    /// The claim the command's own comment makes: every chord is proven before the first
    /// one goes down. A list that stopped half way would already have pressed the chords
    /// before the bad one, and those cannot be taken back.
    @Test func aBadChordLateInTheListPressesNothing() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: (any Error).self) {
            try await KeysCommand.press(["leftCommand+s", "return", "nosuchkey"], on: Self.us, with: Typist(keyboard: keyboard))
        }
        #expect(keyboard.down.isEmpty, "a chord was pressed before the whole list had been proven")
    }

    /// Modifiers alone name no chord the device can press, and that is refused by the
    /// second crossing rather than the spelling. Either way, before anything moves.
    @Test func aChordOfModifiersAloneIsRefusedBeforeAnythingIsPressed() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: (any Error).self) {
            try await KeysCommand.press(["leftCommand"], on: Self.us, with: Typist(keyboard: keyboard))
        }
        #expect(keyboard.down.isEmpty)
    }

    // MARK: click

    /// The one positional output of the verb is read back from the cursor, not repeated
    /// from the request. A mouse whose gain is not 1 lands beside what it was aimed at,
    /// and what gets printed is where the button actually went down.
    @Test func clickReportsWhereTheButtonWentDownNotWhereItWasAimed() async throws {
        let mouse = FakeMouse(at: 0, 0, gain: 3)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await ClickCommand.click(at: ScreenPoint(x: 100, y: 50)!, button: .left, times: .single, with: pointer)
        #expect(said.contains("clicked left once at "))
        #expect(mouse.buttons == [.left])
        // Whatever it says it landed on is the cursor's own position by then.
        #expect(said.contains("\(mouse.cursor)"))
    }

    @Test func clickPressesTheButtonAsManyTimesAsAsked() async throws {
        let mouse = FakeMouse(at: 10, 10)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await ClickCommand.click(at: ScreenPoint(x: 10, y: 10)!, button: .right, times: .double, with: pointer)
        #expect(mouse.buttons == [.right, .right])
        #expect(said.contains("clicked right 2 times"))
    }

    /// A button with no word is still a button: naming only three of thirty-two would be
    /// the CLI deciding which the caller is allowed to press.
    @Test func aNumberedButtonIsPressedAndPrintedByItsNumber() async throws {
        let mouse = FakeMouse(at: 0, 0)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let eight = try #require(Button(rawValue: 8))
        let said = try await ClickCommand.click(at: ScreenPoint(x: 0, y: 0)!, button: eight, times: .single, with: pointer)
        #expect(mouse.buttons == [eight])
        #expect(said.contains("clicked 8 once"))
    }
}
