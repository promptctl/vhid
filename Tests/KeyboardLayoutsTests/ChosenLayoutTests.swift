import Testing
@testable import KeyboardLayouts

/// Which layout a verb types with, given `--layout` or not.
@Suite struct ChosenLayoutTests {
    @Test func aNamedLayoutIsTheOneTypedWith() throws {
        #expect(try KeyboardLayout.chosen("com.apple.keylayout.Dvorak").name == "com.apple.keylayout.Dvorak")
    }

    /// Refused by the name given, not replaced with US: a wrong name typing on US is the
    /// silent misbehaviour naming a layout exists to prevent.
    @Test func anUnknownLayoutIsRefusedByName() {
        #expect(throws: NoLayout.noSourceNamed("com.apple.keylayout.Nope")) {
            try KeyboardLayout.chosen("com.apple.keylayout.Nope")
        }
    }

    @Test func withNoneNamedTheCurrentLayoutIsUsed() throws {
        let dvorak = try KeyboardLayout.named("com.apple.keylayout.Dvorak")
        #expect(try KeyboardLayout.chosen(nil, current: { dvorak }).name == dvorak.name)
    }

    @Test func withNoneNamedAndNoneReadableUSEnglishIsUsed() throws {
        #expect(try KeyboardLayout.chosen(nil, current: { throw NoLayout.noCurrentSource }).name == KeyboardLayout.usEnglish)
    }

    /// Only a missing current layout falls back. One that cannot type is the user's to hear about.
    @Test func aCurrentInputMethodIsNotReplacedWithUS() {
        #expect(throws: NoLayout.noKeyLayoutData("Pinyin")) {
            try KeyboardLayout.chosen(nil, current: { throw NoLayout.noKeyLayoutData("Pinyin") })
        }
    }
}
