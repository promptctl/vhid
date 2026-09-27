import ArgumentParser
import Input
import Pointing

/// Presses a button at one place on the screen, carries it to another, and lets go.
struct DragCommand: AsyncParsableCommand {
    static let configuration = Help.drag.configuration

    @Argument(help: Help.sentence(Help.from + ": x"))
    var fromX: Double

    @Argument(help: Help.sentence(Help.from + ": y"))
    var fromY: Double

    @Argument(help: Help.sentence(Help.to + ": x"))
    var toX: Double

    @Argument(help: Help.sentence(Help.to + ": y"))
    var toY: Double

    @Option(help: Help.sentence(Help.button))
    var button: Button = .left

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try (place(fromX, fromY), place(toX, toY))
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.drag(from: try place(fromX, fromY), to: try place(toX, toY), button: button, with: $0.pointer)
        })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func drag(from start: ScreenPoint, to end: ScreenPoint, button: Button, with pointer: Pointer) async throws -> String {
        let drag = try await pointer.drag(from: start, to: end, button: button)
        return "dragged \(button) from \(drag.from) to \(drag.to) after \(counted(drag.reports, "motion report"))"
    }
}
