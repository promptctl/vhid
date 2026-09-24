import AppKit
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

    /// One of something is one of it. The rule lives in `counted`, and this is the verb
    /// reading back what it did rather than the helper being asked directly.
    @Test func oneCharacterIsOneCharacter() async throws {
        let said = try await TypeCommand.type("a", on: Self.us, with: Typist(keyboard: RecordingKeyboard()))
        #expect(said == "typed 1 character on \(Self.us.name)")
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
        #expect(said.hasSuffix(" on \(Self.us.name)"))
        // Reported in the spelling that reads back, not the one that was typed.
        #expect(said.contains("leftCommand+key 0x"))
        // The chords themselves, in order, and no count beside them to disagree with them.
        #expect(said.hasPrefix("pressed leftCommand+key 0x"))
        #expect(said.contains(", "))
    }

    /// A list that stops part way says how many chords had already gone down, which is the
    /// part only this loop knows: a `leftCommand+a` that landed in front of a `delete` that
    /// did not has left the document selected, and nothing else would say so.
    /// [LAW:no-silent-failure]
    @Test func aStoppedListOfChordsSaysHowManyWentDown() async throws {
        let keyboard = RecordingKeyboard(failingAtKey: 1)
        let stopped = await #expect(throws: ChordsStopped.self) {
            try await KeysCommand.press(["return", "tab", "delete"], on: Self.us, with: Typist(keyboard: keyboard))
        }
        #expect(stopped?.pressed == 1)
        #expect(stopped?.of == 3)
        #expect(stopped?.description.contains("1 of 3 chords had been pressed before this") == true)
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

    // MARK: paste

    /// The text lands on the pasteboard, Command-V goes down, and what is said is the chord
    /// in the spelling that reads back: V on US is key code 9.
    @Test @MainActor func pasteWritesTheTextAndPressesCommandV() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        let keyboard = RecordingKeyboard()
        let said = try await PasteCommand.paste("héllo ✅ 日本", on: Self.us, with: Typist(keyboard: keyboard), through: Clipboard(pasteboard).write)
        #expect(pasteboard.string(forType: .string) == "héllo ✅ 日本")
        #expect(keyboard.down.map(\.rawValue) == [0xE3, 0x19])
        #expect(said == "pasted 10 characters with leftCommand+key 0x9 on \(Self.us.name)")
    }

    /// Nothing to paste is refused with what the user had copied still there and no key down.
    @Test @MainActor func pastingNothingLeavesTheClipboardAlone() async throws {
        let pasteboard = scratch()
        defer { pasteboard.releaseGlobally() }
        try Clipboard(pasteboard).write("what the user had copied")
        let keyboard = RecordingKeyboard()
        await #expect(throws: NothingToPaste.self) {
            try await PasteCommand.paste("", on: Self.us, with: Typist(keyboard: keyboard), through: Clipboard(pasteboard).write)
        }
        #expect(pasteboard.string(forType: .string) == "what the user had copied")
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

    // MARK: move, scroll, drag, cursor

    @Test func moveGoesThereAndPressesNothing() async throws {
        let mouse = FakeMouse(at: 0, 0, gain: 3)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await MoveCommand.move(to: ScreenPoint(x: 200, y: 120)!, with: pointer)
        #expect(mouse.buttons.isEmpty)
        // Within a count's worth: at three points a count, that is as near as it can get.
        #expect(abs(mouse.cursor.x - 200) <= 3 && abs(mouse.cursor.y - 120) <= 3)
        #expect(said.hasPrefix("moved to \(mouse.cursor) after "))
    }

    /// More ticks than one report holds go out as several reports, and every tick is sent.
    @Test func scrollSendsEveryTickAtThePlaceAsked() async throws {
        let mouse = FakeMouse(at: 0, 0)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await ScrollCommand.scroll(at: ScreenPoint(x: 40, y: 30)!, vertical: -300, horizontal: 5, with: pointer)
        #expect(mouse.scrolls.map { Int($0.vertical.value) }.reduce(0, +) == -300)
        #expect(mouse.scrolls.map { Int($0.horizontal.value) }.reduce(0, +) == 5)
        #expect(mouse.scrolls.count == 3)
        #expect(mouse.cursor == ScreenPoint(x: 40, y: 30)!)
        #expect(said == "scrolled -300 ticks vertically and 5 ticks horizontally at \(mouse.cursor)")
    }

    /// The button goes down at the start, the cursor is carried to the end with it held,
    /// and everything is up again afterwards.
    @Test func dragPressesAtOneEndAndLetsGoAtTheOther() async throws {
        let mouse = FakeMouse(at: 0, 0, gain: 2)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await DragCommand.drag(from: ScreenPoint(x: 10, y: 10)!, to: ScreenPoint(x: 300, y: 200)!, button: .left, with: pointer)
        #expect(mouse.buttons == [.left])
        #expect(mouse.releases >= 1)
        #expect(abs(mouse.cursor.x - 300) < 1 && abs(mouse.cursor.y - 200) < 1)
        #expect(said.hasPrefix("dragged left from "))
        #expect(said.contains(" to \(mouse.cursor) after "))
    }

    @Test func cursorSaysWhereTheCursorIs() throws {
        #expect(try CursorCommand.cursor { ScreenPoint(x: -12.5, y: 40)! } == "the cursor is at \(ScreenPoint(x: -12.5, y: 40)!)")
    }
}
