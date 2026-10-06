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

    @Option(help: Help.sentence(Help.modifiers), transform: heldModifiers)
    var modifiers: HeldModifiers = .none

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try (place(fromX, fromY), place(toX, toY))
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.drag(from: try place(fromX, fromY), to: try place(toX, toY), button: button, holding: modifiers, with: $0.pointer, $0.keyboard)
        })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func drag(from start: ScreenPoint, to end: ScreenPoint, button: Button, holding held: HeldModifiers, with pointer: Pointer, _ keyboard: any Keyboard) async throws -> String {
        let drag = try await pointer.holding(held, on: keyboard) { try await $0.drag(from: start, to: end, button: button) }
        Invocation.moved([drag.approach, drag.carry])
        return "dragged \(button)\(holding(held)) from \(drag.from) to \(drag.to) after \(counted(drag.approach.reports + drag.carry.reports, "motion report"))"
    }
}
