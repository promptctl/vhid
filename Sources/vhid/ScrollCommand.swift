import ArgumentParser
import Input

/// Rolls the wheel at a place on the screen.
struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Roll the mouse wheel at a point on the screen.",
        discussion: """
            The pointer is moved to the point first, because a wheel scrolls whatever is under the \
            pointer. The ticks are the device's own, and macOS decides how far each one scrolls.

            --vertical positive rolls the wheel away from the hand. With macOS's Natural scrolling on, \
            as it is by default, that moves the view toward the end of what is scrolled, so the content \
            slides up; with it off, toward the start. --horizontal positive tilts the wheel right, which \
            with Natural scrolling on moves the view toward the left edge, and with it off toward the \
            right. Negative is the other way on both.
            """)

    @Argument(help: "Screen points from the top left of the main display.")
    var x: Double

    @Argument(help: "Screen points from the top left of the main display.")
    var y: Double

    // [LAW:no-silent-failure] Unconditional, because a negative count is half of what this
    // takes and the default reads `-3` as a flag, refusing `--vertical -3` as missing.
    @Option(parsing: .unconditional, help: "Wheel ticks: positive rolls the wheel away from the hand.")
    var vertical: Int = 0

    @Option(parsing: .unconditional, help: "Wheel ticks: positive tilts the wheel right.")
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
