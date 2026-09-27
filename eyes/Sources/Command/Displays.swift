import ArgumentParser
import Eyes
import Foundation

/// Where the displays are, which a caller needs before it can name one to read or aim a
/// click at one left of or above the main display, where every coordinate is negative.
/// Nothing here captures, and it needs no grant.
struct Displays: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "displays",
        abstract: "List the active displays, main first, with their id, bounds and scale."
    )

    func run() async throws {
        print(Self.report(Geometry.displays()))
    }

    /// The scope line and a row per display: what the verb prints and what the MCP tool
    /// answers, from one function. Pure, so both are tested with displays a test wrote.
    /// [LAW:one-source-of-truth] [LAW:effects-at-boundaries]
    static func report(_ displays: [Display]) -> String {
        ([scope(displays.count)] + displays.map(row)).joined(separator: "\n")
    }

    /// Says what the rows cannot: that sleeping displays were not looked at, and what
    /// space the bounds are in. [LAW:no-silent-failure]
    static func scope(_ count: Int) -> String {
        "\(count) display\(count == 1 ? "" : "s"), main first. Active only: a sleeping display was never looked at."
            + " Bounds are the screen points vhid click takes, negative left of or above the main display."
    }

    /// One display as a row: the id `--display` takes, main or not, the rectangle, and the
    /// backing scale. Tab-separated, like `eyes windows`.
    static func row(_ display: Display) -> String {
        "\(display.id)\t\(display.isMain ? "main" : "secondary")\t\(display.frame)"
            + "\t\(String(format: "%g", display.scale))x"
    }
}
