import Carbon.HIToolbox
import KeyboardLayout
import Keystrokes
import Testing
import Input

/// A chord as a script spells it.
@Suite struct ChordSpellingTests {
    static let us = try! KeyboardLayout.named("com.apple.keylayout.US")
    static let dvorak = try! KeyboardLayout.named("com.apple.keylayout.Dvorak")

    @Test func modifiersAndACharacterNameTheKeyThatCharacterIsOn() throws {
        let chord = try KeyChord(spelled: "leftCommand+s", on: Self.us)
        #expect(chord == KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_S)), modifiers: [.leftCommand]))
    }

    /// The character is the layout's: `s` on Dvorak is the key US calls semicolon.
    @Test func theCharacterIsReadOffTheLayout() throws {
        let chord = try KeyChord(spelled: "leftCommand+s", on: Self.dvorak)
        #expect(chord.key == Key(rawValue: UInt16(kVK_ANSI_Semicolon)))
    }

    /// A chord holding Command is read off the layer the shortcut is matched on. Dvorak -
    /// QWERTY ⌘ is QWERTY under Command, and Russian's Command layer is Latin.
    @Test(arguments: [
        ("com.apple.keylayout.US", kVK_ANSI_V),
        ("com.apple.keylayout.Dvorak", kVK_ANSI_Period),
        ("com.apple.keylayout.DVORAK-QWERTYCMD", kVK_ANSI_V),
        ("com.apple.keylayout.Russian", kVK_ANSI_V),
    ])
    func aChordHoldingCommandIsReadWithCommandHeld(layout: String, key: Int) throws {
        let chord = try KeyChord(spelled: "v+rightCommand", on: KeyboardLayout.named(layout))
        #expect(chord == KeyChord(key: Key(rawValue: UInt16(key)), modifiers: [.rightCommand]))
    }

    /// Without Command the key is what types the character: Dvorak - QWERTY ⌘'s `v` is
    /// key code 47 again, and Russian's key code 9 is `м`, with no `v` anywhere.
    @Test func aChordWithoutCommandIsReadWithNothingHeld() throws {
        let dvorakQwerty = try KeyboardLayout.named("com.apple.keylayout.DVORAK-QWERTYCMD")
        #expect(try KeyChord(spelled: "leftControl+v", on: dvorakQwerty).key == Key(rawValue: UInt16(kVK_ANSI_Period)))
        let russian = try KeyboardLayout.named("com.apple.keylayout.Russian")
        #expect(try KeyChord(spelled: "м", on: russian).key == Key(rawValue: UInt16(kVK_ANSI_V)))
        #expect(throws: ChordSpellingError.notOneKey("v", layout: russian.name, [.plain])) { try KeyChord(spelled: "leftShift+v", on: russian) }
    }

    /// The letter on the key cap still names the key under Command, when the Command
    /// layer types something else there.
    @Test func aChordHoldingCommandFallsToTheLetterOnTheKey() throws {
        let russian = try KeyboardLayout.named("com.apple.keylayout.Russian")
        #expect(try KeyChord(spelled: "leftCommand+м", on: russian).key == Key(rawValue: UInt16(kVK_ANSI_V)))
    }

    /// A keypad key is named by its code, never by a character: `*` on US is Shift and 8,
    /// and the keypad's `*` is not what the chord means by it.
    @Test func aCharacterIsNeverAKeypadKey() throws {
        #expect(throws: ChordSpellingError.notOneKey("*", layout: Self.us.name, [.command, .plain])) { try KeyChord(spelled: "leftCommand+*", on: Self.us) }
        #expect(try KeyChord(spelled: "1", on: Self.us).key == Key(rawValue: UInt16(kVK_ANSI_1)))
    }

    /// A line break is Return however it is written, as it is when text is typed.
    @Test(arguments: ["\n", "\r", "\r\n"])
    func aLineBreakIsReturn(term: String) throws {
        #expect(try KeyChord(spelled: "leftCommand+" + term, on: Self.us).key == Key(rawValue: UInt16(kVK_Return)))
    }

    @Test func aNamedKeyNeedsNoLayoutCharacter() throws {
        #expect(try KeyChord(spelled: "return", on: Self.us) == KeyChord(key: Key(rawValue: UInt16(kVK_Return))))
        #expect(try KeyChord(spelled: "leftShift+leftCommand+left", on: Self.us)
            == KeyChord(key: Key(rawValue: UInt16(kVK_LeftArrow)), modifiers: [.leftShift, .leftCommand]))
        #expect(try KeyChord(spelled: "f12", on: Self.us).key == Key(rawValue: UInt16(kVK_F12)))
    }

    /// Every name is a key the device can press, so no name parses into a refusal.
    @Test func everyNamedKeyIsPressable() {
        for (name, key) in KeyChord.namedKeys {
            #expect(Usage(virtualKeyCode: key.rawValue) != nil, "\(name) names key code \(key.rawValue), which has no usage")
        }
    }

    /// [LAW:one-source-of-truth] What the program prints for a chord is a spelling it
    /// reads. The one map: a chord a report names is a chord a caller can ask for back,
    /// with nothing in between to retype by hand.
    @Test(arguments: [
        KeyChord(key: Key(rawValue: 0x24), modifiers: [.rightShift, .leftControl]),
        KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_Keypad1))),
        KeyChord(modifiers: .rightOption),
        KeyChord(modifiers: .leftCommand, .leftShift),
        KeyChord(key: Key(rawValue: UInt16(kVK_ANSI_S)), modifiers: [.leftCommand]),
    ])
    func aChordPrintsAsSomethingThatParsesBackToIt(chord: KeyChord) throws {
        #expect(try KeyChord(spelled: "\(chord)", on: Self.us) == chord)
    }

    /// Modifiers alone spell a chord; that the device cannot strike one is the keystroke's
    /// refusal, the same one a decoded chord gets.
    @Test func modifiersAloneParseAndAreRefusedWhereEveryChordIs() throws {
        let chord = try KeyChord(spelled: "rightOption", on: Self.us)
        #expect(chord == KeyChord(modifiers: .rightOption))
        #expect(throws: UnpressableChord.self) { try Keystroke(chord: chord) }
    }

    @Test func aCharacterThatNeedsAModifierIsNotAKey() {
        #expect(throws: ChordSpellingError.notOneKey("S", layout: "com.apple.keylayout.US", [.command, .plain])) { try KeyChord(spelled: "leftCommand+S", on: Self.us) }
        // A dead key and the letter under it is two keys.
        #expect(throws: ChordSpellingError.notOneKey("\u{e9}", layout: "com.apple.keylayout.US", [.plain])) { try KeyChord(spelled: "\u{e9}", on: Self.us) }
    }

    @Test func whatNamesNoChordIsRefusedByName() {
        #expect(throws: ChordSpellingError.unknownTerm("cmd", in: "cmd+s")) { try KeyChord(spelled: "cmd+s", on: Self.us) }
        #expect(throws: ChordSpellingError.unknownTerm("", in: "leftCommand+")) { try KeyChord(spelled: "leftCommand+", on: Self.us) }
        #expect(throws: ChordSpellingError.unknownTerm("", in: "")) { try KeyChord(spelled: "", on: Self.us) }
        #expect(throws: ChordSpellingError.moreThanOneKey("a+b")) { try KeyChord(spelled: "a+b", on: Self.us) }
        #expect(throws: ChordSpellingError.notOneKey("\u{1F600}", layout: "com.apple.keylayout.US", [.plain])) { try KeyChord(spelled: "\u{1F600}", on: Self.us) }
    }
}
