import ArgumentParser
import Input

/// Says where the pointer is.
struct CursorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cursor",
        abstract: "Print where the pointer is, in the coordinates click takes.",
        discussion: """
            Read from the window server rather than from the daemon, which cannot know: macOS \
            accelerates what the device sends, so where the pointer went is a fact of the user's \
            session. This verb reaches no daemon at all.
            """)

    func run() throws {
        print(try Self.cursor(Pointer.screenCursor))
    }

    /// The verb itself, over a cursor from anywhere. [LAW:decomposition]
    static func cursor(_ cursor: () throws -> ScreenPoint) throws -> String {
        "the cursor is at \(try cursor())"
    }
}
