import Input
import KeyboardLayouts
import Keystrokes
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
        let said = try await TypeCommand.type("abc", on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
        #expect(said == "typed 3 characters on \(Self.us.name)")
        #expect(keyboard.down.count >= 3)
    }

    /// One of something is one of it. The rule lives in `counted`, and this is the verb
    /// reading back what it did rather than `counted` being called directly.
    @Test func oneCharacterIsOneCharacter() async throws {
        let said = try await TypeCommand.type("a", on: Self.us, into: .anywhere, with: Typist(keyboard: RecordingKeyboard()), front: { nil })
        #expect(said == "typed 1 character on \(Self.us.name)")
    }

    /// The whole string is refused rather than typed up to the first character the layout
    /// cannot type: half a sentence in a document is worse than none, because only one of
    /// the two is obviously wrong.
    @Test func textTheLayoutCannotTypeMovesNothing() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: (any Error).self) {
            try await TypeCommand.type("ab日", on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
        }
        #expect(keyboard.down.isEmpty, "the refusal came after keys had already gone down")
    }

    /// A run that stops part way says how far it got, and the count is of what was posted
    /// rather than of what was asked for. [LAW:no-silent-failure]
    @Test func aStoppedRunSaysHowMuchWasTyped() async throws {
        let keyboard = RecordingKeyboard(failingAtKey: 2)
        let stopped = await #expect(throws: TypingStopped.self) {
            try await TypeCommand.type("abcd", on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
        }
        #expect(stopped?.of == 4)
        #expect((stopped?.typed ?? 4) < 4)
    }

    // MARK: press

    @Test func pressPressesEveryChordAndNamesThemBack() async throws {
        let keyboard = RecordingKeyboard()
        let said = try await PressCommand.press(["leftCommand+s", "return"], on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
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
            try await PressCommand.press(["return", "tab", "delete"], on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
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
            try await PressCommand.press(["leftCommand+s", "return", "nosuchkey"], on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
        }
        #expect(keyboard.down.isEmpty, "a chord was pressed before the whole list had been proven")
    }

    /// Modifiers alone name no chord the device can press, and that is refused by the
    /// second crossing rather than the spelling. Either way, before anything moves.
    @Test func aChordOfModifiersAloneIsRefusedBeforeAnythingIsPressed() async throws {
        let keyboard = RecordingKeyboard()
        await #expect(throws: (any Error).self) {
            try await PressCommand.press(["leftCommand"], on: Self.us, into: .anywhere, with: Typist(keyboard: keyboard), front: { nil })
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
        let said = try await ClickCommand.click(at: ScreenPoint(x: 100, y: 50)!, button: .left, times: .single, holding: .none, with: pointer, RecordingKeyboard())
        #expect(said.contains("clicked left once at "))
        #expect(mouse.buttons == [.left])
        // Whatever it says it landed on is the cursor's own position by then.
        #expect(said.contains("\(mouse.cursor)"))
    }

    @Test func clickPressesTheButtonAsManyTimesAsAsked() async throws {
        let mouse = FakeMouse(at: 10, 10)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let said = try await ClickCommand.click(at: ScreenPoint(x: 10, y: 10)!, button: .right, times: .double, holding: .none, with: pointer, RecordingKeyboard())
        #expect(mouse.buttons == [.right, .right])
        #expect(said.contains("clicked right 2 times"))
    }

    /// A button with no word is still a button: naming only three of thirty-two would be
    /// the CLI deciding which the caller is allowed to press.
    @Test func aNumberedButtonIsPressedAndPrintedByItsNumber() async throws {
        let mouse = FakeMouse(at: 0, 0)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let eight = try #require(Button(rawValue: 8))
        let said = try await ClickCommand.click(at: ScreenPoint(x: 0, y: 0)!, button: eight, times: .single, holding: .none, with: pointer, RecordingKeyboard())
        #expect(mouse.buttons == [eight])
        #expect(said.contains("clicked 8 once"))
    }

    /// The modifiers go down before the click and come up after it, and the report names
    /// them.
    @Test func aClickHoldingModifiersPressesThemAroundTheClickAndSaysSo() async throws {
        let mouse = FakeMouse(at: 0, 0)
        let keyboard = RecordingKeyboard()
        let held = try HeldModifiers(spelled: "leftCommand+leftShift")
        let said = try await ClickCommand.click(at: ScreenPoint(x: 5, y: 5)!, button: .left, times: .single, holding: held, with: Pointer(mouse: mouse, cursor: { mouse.cursor }), keyboard)
        #expect(keyboard.down == held.pressed.usages)
        #expect(keyboard.releases == 1)
        #expect(mouse.buttons == [.left])
        #expect(said.hasPrefix("clicked left once holding leftShift+leftCommand at "))
    }

    /// Scroll and drag name what they held the same way.
    @Test func scrollAndDragSayWhatTheyHeld() async throws {
        let mouse = FakeMouse(at: 0, 0)
        let pointer = Pointer(mouse: mouse, cursor: { mouse.cursor })
        let command = try HeldModifiers(spelled: "leftCommand")
        let scrolled = try await ScrollCommand.scroll(at: ScreenPoint(x: 5, y: 5)!, vertical: 1, horizontal: 0, holding: command, with: pointer, RecordingKeyboard())
        #expect(scrolled.hasPrefix("scrolled 1 tick vertically and 0 ticks horizontally holding leftCommand at "))
        let option = try HeldModifiers(spelled: "leftOption")
        let dragged = try await DragCommand.drag(from: ScreenPoint(x: 5, y: 5)!, to: ScreenPoint(x: 9, y: 9)!, button: .left, holding: option, with: pointer, RecordingKeyboard())
        #expect(dragged.hasPrefix("dragged left holding leftOption from "))
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
        let said = try await ScrollCommand.scroll(at: ScreenPoint(x: 40, y: 30)!, vertical: -300, horizontal: 5, holding: .none, with: pointer, RecordingKeyboard())
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
        let said = try await DragCommand.drag(from: ScreenPoint(x: 10, y: 10)!, to: ScreenPoint(x: 300, y: 200)!, button: .left, holding: .none, with: pointer, RecordingKeyboard())
        #expect(mouse.buttons == [.left])
        #expect(mouse.releases >= 1)
        #expect(abs(mouse.cursor.x - 300) < 1 && abs(mouse.cursor.y - 200) < 1)
        #expect(said.hasPrefix("dragged left from "))
        #expect(said.contains(" to \(mouse.cursor) after "))
    }

    @Test func cursorSaysWhereTheCursorIs() async throws {
        #expect(try await CursorCommand.cursor { ScreenPoint(x: -12.5, y: 40)! } == "the cursor is at \(ScreenPoint(x: -12.5, y: 40)!)")
    }
}

/// `gesture`: the chord a gesture comes to on this Mac, and the press of it. The
/// preferences are handed in, so each test says which entry the user's Mac holds.
@Suite struct GestureVerbTests {
    static let us = VerbTests.us
    static func none() -> [String: Any]? { nil }

    static func performed(_ gesture: Gesture, on layout: KeyboardLayout = us, hotKeys: () -> [String: Any]? = none) async throws -> (said: String, down: [Usage]) {
        let keyboard = RecordingKeyboard()
        let chord = try GestureCommand.chord(for: gesture, on: layout, hotKeys: hotKeys)
        let said = try await GestureCommand.perform(chord, with: Typist(keyboard: keyboard))
        return (said, keyboard.down)
    }

    /// An app's command is the chord read off the layout, and the report says which.
    @Test func backPressesCommandAndLeftBracket() async throws {
        let (said, down) = try await Self.performed(.back)
        #expect(down == [.leftCommand, Usage(rawValue: 0x2F)])
        #expect(said == "back: pressed leftCommand+key 0x21, on \(Self.us.name)")
    }

    /// Look Up is a system shortcut, matched by key code, so ⌃⌘D is the key US calls D on
    /// every layout - on Dvorak the one that types E.
    @Test func lookUpPressesItsKeyCodeWhateverTheLayout() async throws {
        let (said, down) = try await Self.performed(.lookUp, on: try KeyboardLayout.named("com.apple.keylayout.Dvorak"))
        #expect(Set(down) == [.leftControl, .leftCommand, Usage(rawValue: 0x07)])
        #expect(said.hasSuffix("its shortcut by default at entry 70 of AppleSymbolicHotKeys in com.apple.symbolichotkeys, which System Settings does not list"))
    }

    /// A command the layout has no keys for is refused as the gesture's, not as a spelling.
    @Test func aCommandTheLayoutCannotPressIsRefusedAsTheGestures() throws {
        let german = try KeyboardLayout.named("com.apple.keylayout.German")
        let refused = #expect(throws: GestureRefused.self) { try GestureCommand.chord(for: .back, on: german, hotKeys: Self.none) }
        #expect(refused?.description.hasPrefix("back is leftCommand+[, which \(german.name) has no keys for: ") == true)
    }

    /// The user's own binding wins, and the report says it was theirs.
    @Test func aShortcutTheUserSetIsPressedAndSaidToBeTheirs() async throws {
        let (said, down) = try await Self.performed(.missionControl) {
            ["32": ["enabled": true, "value": ["parameters": [113, 12, 524288], "type": "standard"]]]
        }
        #expect(down == [.leftOption, Usage(rawValue: 0x14)])
        #expect(said == "mission-control: pressed leftOption+key 0xc, its shortcut as set at System Settings > Keyboard > Keyboard Shortcuts > Mission Control > Mission Control")
    }

    @Test func aShortcutNeverChangedIsMacOSsDefaultAndSaidToBe() async throws {
        let (said, down) = try await Self.performed(.appExpose)
        #expect(down == [.leftControl, Usage(rawValue: 0x51)])
        #expect(said.contains("its shortcut by default at "))
    }

    /// Off is refused by name, naming the setting, before anything is pressed.
    @Test func aShortcutThatIsOffIsRefusedNamingTheSetting() throws {
        let refused = #expect(throws: GestureRefused.self) { try GestureCommand.chord(for: .launchpad, on: Self.us, hotKeys: Self.none) }
        #expect(refused?.description == "launchpad is the shortcut at System Settings > Keyboard > Keyboard Shortcuts > Launchpad & Dock > Show Launchpad, and it is off")
    }

    /// A gesture with no route is refused, never approximated by a neighbour's.
    @Test(arguments: [Gesture.smartZoom, .rotate])
    func aGestureWithNoRouteIsRefused(_ gesture: Gesture) throws {
        let refused = #expect(throws: GestureRefused.self) { try GestureCommand.chord(for: gesture, on: Self.us, hotKeys: Self.none) }
        #expect(refused?.description.hasPrefix("\(gesture) has no key or button that does it: ") == true)
    }

    @Test func theCommandLineReadsAGestureByName() throws {
        let parsed = try #require(try Vhid.parseAsRoot(["gesture", "mission-control"]) as? GestureCommand)
        #expect(parsed.gesture == .missionControl)
        #expect(throws: (any Error).self) { try Vhid.parseAsRoot(["gesture", "swipe"]) }
    }
}
