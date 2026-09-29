import ArgumentParser
import Helper
import Input

/// Says where the pointer is.
struct CursorCommand: AsyncParsableCommand {
    static let configuration = Help.cursor.configuration

    @OptionGroup var service: ServiceOption

    func run() throws {
        print(try Self.cursor(Devices.cursor(HelperConnection(installation: try service.installation()))))
    }

    /// The verb itself, over a cursor from anywhere. [LAW:decomposition]
    static func cursor(_ cursor: () throws -> ScreenPoint) throws -> String {
        "the cursor is at \(try cursor())"
    }
}
