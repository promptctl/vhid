import ArgumentParser
import Input
import Pointing

/// Clicks at a place on the screen, by moving the pointer there and pressing.
struct ClickCommand: AsyncParsableCommand {
    static let configuration = Help.click.configuration

    @Argument(help: Help.sentence(Help.x))
    var x: Double

    @Argument(help: Help.sentence(Help.y))
    var y: Double

    @Option(help: Help.sentence(Help.button))
    var button: Button = .left

    @Option(help: Help.sentence(Help.times))
    var times: Clicks = .single

    @Option(help: Help.sentence(Help.modifiers), transform: heldModifiers)
    var modifiers: HeldModifiers = .none

    @OptionGroup var service: ServiceOption

    /// Asked before any `run`, which is what makes the refusal arrive as this verb's own
    /// usage rather than the root command's - and before anything is connected.
    func validate() throws {
        _ = try place(x, y)
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.click(at: try place(x, y), button: button, times: times, holding: modifiers, with: $0.pointer, $0.keyboard)
        })
    }

    /// The verb itself, over a pointer from anywhere - which is what lets it be run
    /// against a mouse and a screen that exist only in a test. [LAW:decomposition]
    static func click(at point: ScreenPoint, button: Button, times: Clicks, holding held: HeldModifiers, with pointer: Pointer, _ keyboard: any Keyboard) async throws -> String {
        let click = try await pointer.holding(held, on: keyboard) { try await $0.click(at: point, button: button, times: times) }
        // Where the button went down is read back from the cursor rather than repeated
        // from the request: the two differ, and the one worth printing is the one that
        // happened. [LAW:no-silent-failure]
        return "clicked \(button) \(times.rawValue == 1 ? "once" : "\(times.rawValue) times")\(holding(held)) at \(click.at) after \(counted(click.reports, "motion report"))"
    }
}
