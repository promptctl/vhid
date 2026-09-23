import ArgumentParser
import Input

/// Moves the pointer to a place on the screen, and presses nothing.
struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move the pointer to a point on the screen.",
        discussion: """
            Steered the way click steers it - post a delta, read the cursor back, repeat - and the \
            point it reports is read back from the cursor. Negative coordinates follow --, as in: \
            vhid move -- -100 -40.
            """)

    @Argument(help: "Screen points from the top left of the main display.")
    var x: Double

    @Argument(help: "Screen points from the top left of the main display.")
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
        let reports = try await pointer.move(to: point)
        // Where the cursor ended up, read back, for the reason `click` reads it back.
        // [LAW:no-silent-failure]
        return "moved to \(try pointer.cursor()) after \(counted(reports, "motion report"))"
    }
}
