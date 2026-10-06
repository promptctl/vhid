import ArgumentParser
import Input

/// Moves the pointer to a place on the screen, and presses nothing.
struct MoveCommand: AsyncParsableCommand {
    static let configuration = Help.move.configuration

    @Argument(help: Help.sentence(Help.x))
    var x: Double

    @Argument(help: Help.sentence(Help.y))
    var y: Double

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try place(x, y)
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) { try await Self.move(to: try place(x, y), with: $0.pointer) })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func move(to point: ScreenPoint, with pointer: Pointer) async throws -> String {
        let moved = try await pointer.move(to: point)
        // Where the cursor ended up, read back, for the reason `click` reads it back.
        // [LAW:no-silent-failure]
        return "moved to \(try await pointer.cursor()) after \(counted(moved.reports, "motion report"))"
    }
}
