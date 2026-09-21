import AppKit

/// A pasteboard, as the other way text gets into an app: put it here and press the paste
/// chord, instead of typing it a character at a time.
///
/// The two insertions are not the same act and neither is the better one. Typing is what
/// the device does - every keystroke a real key, in an app that only ever sees hardware -
/// and it costs a report per key. A paste is two keystrokes whatever the length, and it
/// costs the user's clipboard: the words replace what was there and stay, because the
/// paste happens at a moment nothing here can see and there is no point after it at which
/// the old contents could be put back. Which of those a caller wants is the caller's to
/// decide, and this says what it costs rather than choosing for them.
///
/// [LAW:effects-at-boundaries] The pasteboard is taken as a value, so a test writes to one
/// of its own and reads the words back, and the person at the Mac keeps their clipboard.
@MainActor
public struct Clipboard {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    /// The one every app pastes from.
    public static var general: Clipboard { Clipboard(.general) }

    /// Puts `text` on the pasteboard, replacing what was there.
    ///
    /// [LAW:no-silent-failure] `setString` answers false rather than throwing, and a false
    /// that went unread would leave a caller pressing paste over whatever the user had
    /// copied earlier - the one failure here that inserts the wrong text rather than none.
    public func write(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ClipboardRefused(pasteboard: pasteboard.name.rawValue) }
    }
}

/// The pasteboard server would not take the text. [LAW:no-silent-failure]
public struct ClipboardRefused: Error, CustomStringConvertible {
    public let pasteboard: String

    public var description: String { "the pasteboard \(pasteboard) refused the text; nothing was copied" }
}
