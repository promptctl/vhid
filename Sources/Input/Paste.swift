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
    /// this layout's Command layer puts `v` on - key code 9 on US, on Dvorak - QWERTY ⌘ and
    /// on Russian, 47 on Dvorak - by the one reading of a layout every chord goes through.
    /// [LAW:one-source-of-truth]
    ///
    /// [LAW:parse-dont-validate] The chord is proven pressable before the write, so a
    /// chord that cannot be spelled is refused with the user's clipboard still theirs. The
    /// write comes before the chord, and a write that throws is the whole answer: pasting
    /// over a pasteboard that did not take the text would paste whatever it holds instead.
    /// Empty text and a cancelled run are refused before the write too: either would cost
    /// the user their clipboard and put nothing in. So is a daemon that will not take keys -
    /// not running, not admitting this caller, serving someone else - which the release the
    /// keyboard answers before the write is what finds out. It holds nothing down, and it is
    /// the first thing to reach the daemon, whose connection is made on first use.
    ///
    /// [LAW:effects-at-boundaries] The write is taken as a value, so a test can have it
    /// refuse, which a real pasteboard cannot be made to do.
    ///
    /// Answers with the chord it pressed, in the spelling that reads back, once the
    /// daemon has acknowledged its keys. That is not the moment the app reads the
    /// pasteboard - the app reads it when it gets to the event, and nothing on this Mac says
    /// when that is - so a write straight after this returns can be what the app pastes.
    /// [LAW:no-ambient-temporal-coupling]
    @MainActor @discardableResult
    func paste(_ text: String, on layout: KeyboardLayout, through write: @MainActor (String) throws -> Void) async throws -> KeyChord {
        let chord = try KeyChord(spelled: "leftCommand+v", on: layout)
        let pressable = try lower(chord)
        guard !text.isEmpty else { throw NothingToPaste() }
        try await keyboard.releaseAll()
        // After the release and not before it: the release waits on the daemon, and a run
        // cancelled during that wait must still find the clipboard the user's.
        try Task.checkCancellation()
        try write(text)
        do {
            try await press(pressable)
        } catch {
            throw PasteStopped(cause: error)
        }
        return chord
    }
}

/// Empty text, refused before the write: a paste of nothing would still take what the
/// user had copied.
public struct NothingToPaste: Error, CustomStringConvertible {
    public var description: String { "there is no text to paste; the clipboard was left as it was" }
}

/// A paste whose chord stopped after the write had landed. What stopped the chord is the
/// cause; that the clipboard already held the text is the part only the paste knows, and
/// the part the person at the Mac needs: what they had copied is gone, and whether the app
/// got Command-V is not known. [LAW:no-silent-failure]
public struct PasteStopped: StoppedPartWay, CustomStringConvertible {
    public let cause: any Error

    public var description: String {
        "\(cause.reported). The text was already on the clipboard in place of what had been copied there, and whether the app received the paste is not known"
    }
}
