import KeyboardLayout

public extension Typist {
    /// Puts `text` in through the pasteboard: `write` puts it there, and the layout's
    /// Command-V pastes it. Two keystrokes whatever the text, and any text at all - emoji
    /// and scripts the layout has no keys for included, which `type` refuses.
    ///
    /// The cost is `Clipboard`'s to state and it states it: the user's clipboard is
    /// replaced and stays replaced. Nothing here puts the old contents back.
    ///
    /// The chord is spelled the way a caller spells one to `vhid keys`, so V is the key
    /// this layout puts `v` on - key code 9 on US, 47 on Dvorak - by the one reading of a
    /// layout every chord goes through. [LAW:one-source-of-truth]
    ///
    /// [LAW:parse-dont-validate] The chord is proven pressable before the write, so a
    /// layout with no `v` refuses with the user's clipboard still theirs. The write comes
    /// before the chord, and a write that throws is the whole answer: pasting over a
    /// pasteboard that did not take the text would paste whatever it holds instead.
    ///
    /// [LAW:effects-at-boundaries] The write is taken as a value, so a test can have it
    /// refuse, which a real pasteboard cannot be made to do.
    ///
    /// Answers with the chord it pressed, in the spelling that reads back.
    @MainActor @discardableResult
    func paste(_ text: String, on layout: KeyboardLayout, through write: @MainActor (String) throws -> Void) async throws -> KeyChord {
        let chord = try KeyChord(spelled: "leftCommand+v", on: layout)
        let pressable = try lower(chord)
        try write(text)
        try await press(pressable)
        return chord
    }
}
