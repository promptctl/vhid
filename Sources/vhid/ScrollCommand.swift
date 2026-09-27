import ArgumentParser
import Input

/// Rolls the wheel at a place on the screen.
struct ScrollCommand: AsyncParsableCommand {
    static let configuration = Help.scroll.configuration

    @Argument(help: Help.sentence(Help.x))
    var x: Double

    @Argument(help: Help.sentence(Help.y))
    var y: Double

    // [LAW:no-silent-failure] Unconditional, because a negative count is half of what this
    // takes and the default reads `-3` as a flag, refusing `--vertical -3` as missing.
    @Option(parsing: .unconditional, help: Help.sentence(Help.vertical))
    var vertical: Int = 0

    @Option(parsing: .unconditional, help: Help.sentence(Help.horizontal))
    var horizontal: Int = 0

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try place(x, y)
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.scroll(at: try place(x, y), vertical: vertical, horizontal: horizontal, with: $0.pointer)
        })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func scroll(at point: ScreenPoint, vertical: Int, horizontal: Int, with pointer: Pointer) async throws -> String {
        try await pointer.scroll(at: point, vertical: vertical, horizontal: horizontal)
        return "scrolled \(counted(vertical, "tick")) vertically and \(counted(horizontal, "tick")) horizontally at \(try pointer.cursor())"
    }
}
