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

    @Option(help: Help.sentence(Help.modifiers), transform: heldModifiers)
    var modifiers: HeldModifiers = .none

    @OptionGroup var service: ServiceOption

    func validate() throws {
        _ = try place(x, y)
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.scroll(at: try place(x, y), vertical: vertical, horizontal: horizontal, holding: modifiers, with: $0.pointer, $0.keyboard, clock: ContinuousClock())
        })
    }

    /// The verb itself, over a pointer from anywhere. [LAW:decomposition]
    static func scroll<C: Clock>(at point: ScreenPoint, vertical: Int, horizontal: Int, holding held: HeldModifiers, with pointer: Pointer, _ keyboard: any Keyboard, clock: C) async throws -> String where C.Duration == Duration {
        try await pointer.holding(held, on: keyboard) { try await $0.scroll(at: point, vertical: vertical, horizontal: horizontal, clock: clock) }
        return "scrolled \(counted(vertical, "tick")) vertically and \(counted(horizontal, "tick")) horizontally\(holding(held)) at \(try await pointer.cursor())"
    }
}
