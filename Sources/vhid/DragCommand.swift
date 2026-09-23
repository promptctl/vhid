import ArgumentParser
import Input
import Pointing

/// Presses a button at one place on the screen, carries it to another, and lets go.
struct DragCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Drag from one point on the screen to another.",
        discussion: """
            The pointer is moved to the first point, the button goes down, the pointer is moved to \
            the second with it held, and every button comes up. Both points it reports are read \
            back from the cursor.

            Negative coordinates follow --, as in: vhid drag -- -100 40 200 40.
            """)

    @Argument(help: "Where the button goes down: x.")
    var fromX: Double

    @Argument(help: "Where the button goes down: y.")
    var fromY: Double

    @Argument(help: "Where it comes up: x.")
    var toX: Double

    @Argument(help: "Where it comes up: y.")
    var toY: Double

    @Option(help: "Which button: left, right, middle, or a number from 1 to 32.")
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
