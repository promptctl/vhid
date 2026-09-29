import ArgumentParser
import Helper
import Input

/// Says where the pointer is.
struct CursorCommand: AsyncParsableCommand {
    static let configuration = Help.cursor.configuration

    @OptionGroup var service: ServiceOption

    func run() async throws {
        print(try await Self.cursor(Devices.cursor(HelperConnection(installation: try service.installation()), on: DeviceQueue())))
    }

    /// The verb itself, over a cursor from anywhere. [LAW:decomposition]
    static func cursor(_ cursor: () async throws -> ScreenPoint) async throws -> String {
        "the cursor is at \(try await cursor())"
    }
}
