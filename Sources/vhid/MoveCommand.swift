import ArgumentParser
import Input

/// Moves the pointer to a place on the screen, and presses nothing.
struct MoveCommand: AsyncParsableCommand {
    static let configuration = Help.move.configuration

    @Argument(help: Help.sentence(Help.target))
    var place: [String]

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try places(place, count: 1)
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) { try await Self.move(to: try places(place, count: 1)[0], with: $0.pointer) })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func move(to target: Target, with pointer: Pointer) async throws -> String {
        let moved = try await pointer.move(to: target)
        // Where the cursor ended up, read back, for the reason `click` reads it back.
        // [LAW:no-silent-failure]
        return "moved to \(try await pointer.cursor()) after \(counted(moved.reports, "motion report"))"
    }
}
