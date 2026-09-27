import ArgumentParser
import Input

/// Says where the pointer is.
struct CursorCommand: AsyncParsableCommand {
    static let configuration = Help.cursor.configuration

    func run() throws {
        print(try Self.cursor(Pointer.screenCursor))
    }

    /// The verb itself, over a cursor from anywhere. [LAW:decomposition]
    static func cursor(_ cursor: () throws -> ScreenPoint) throws -> String {
        "the cursor is at \(try cursor())"
    }
}
