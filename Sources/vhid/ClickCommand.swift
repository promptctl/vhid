import ArgumentParser
import Input
import Pointing

/// Clicks at a place on the screen, by moving the pointer there and pressing.
struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click at a point on the screen.",
        discussion: """
            Coordinates, and nothing else: there is no click-by-element here, because nothing in vhid \
            reads the screen. What is under the point is the caller's to know.

            The device sends counts, not coordinates, and macOS accelerates them, so the pointer is \
            steered in a loop - post a delta, read the cursor back, repeat - and the point it reports \
            landing at is read back from the cursor rather than the point that was asked for.

            A display left of or above the main one has negative coordinates, and a bare -100 reads as \
            a flag, so those follow --, as in: vhid click -- -100 -40.
            """)

    @Argument(help: "Screen points from the top left of the main display.")
    var x: Double

    @Argument(help: "Screen points from the top left of the main display.")
    var y: Double

    @Option(help: "Which button: left, right, middle, or a number from 1 to 32.")
    var button: Button = .left

    @Option(help: "How many presses without moving between them.")
    var times: Clicks = .single

    @OptionGroup var service: ServiceOption

    /// The point asked for, once it is one.
    ///
    /// [LAW:parse-dont-validate] `ScreenPoint` refuses what is not a place on the screen,
    /// and `inf` and `nan` are both things a shell hands over as a Double without
    /// complaint. [LAW:single-enforcer] One place says so, called from both `validate`
    /// and `run`, so the refusal cannot come to be worded two ways.
    private func target() throws -> ScreenPoint {
        guard let point = ScreenPoint(x: x, y: y) else {
            throw ValidationError("(\(x), \(y)) is not a place on the screen")
        }
        return point
    }

    /// Asked before any `run`, which is what makes the refusal arrive as this verb's own
    /// usage rather than the root command's - and before anything is connected.
    func validate() throws {
        _ = try target()
    }

    func run() async throws {
        print(try await Devices.using(try service.installation()) {
            try await Self.click(at: try target(), button: button, times: times, with: $0.pointer)
        })
    }

    /// The verb itself, over a pointer from anywhere - which is what lets it be run
    /// against a mouse and a screen that exist only in a test. [LAW:decomposition]
    static func click(at point: ScreenPoint, button: Button, times: Clicks, with pointer: Pointer) async throws -> String {
        let click = try await pointer.click(at: point, button: button, times: times)
        // Where the button went down is read back from the cursor rather than repeated
        // from the request: the two differ, and the one worth printing is the one that
        // happened. [LAW:no-silent-failure]
        return "clicked \(button) \(times.rawValue == 1 ? "once" : "\(times.rawValue) times") at \(click.at) after \(counted(click.reports, "motion report"))"
    }
}
