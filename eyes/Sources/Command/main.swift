import ArgumentParser
import Eyes
import Foundation

@main
struct Eye: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyes",
        abstract: "Say what is on screen and where, in the coordinates vhid clicks.",
        subcommands: [Windows.self]
    )
}

/// Where the windows are, which a caller can ask before capturing anything.
///
/// It exists because the cheapest useful question about a screen is not what it says but
/// how it is divided: an owner and a rectangle per window is about a hundred tokens and
/// it tells a caller which application holds which part of the display. Nothing here
/// captures, recognises, or reads an accessibility tree, and it needs no grant.
struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List the on-screen windows, front to back, with their bounds."
    )

    @Option(help: "Only windows owned by applications whose name contains this.")
    var owner: String?

    @MainActor
    func run() async throws {
        let all = try Geometry.onScreen()
        let shown = owner.map { name in
            all.filter { $0.owner.localizedCaseInsensitiveContains(name) }
        } ?? all

        // The scope line, first, because every reading below it is narrower than the
        // screen and a narrow answer is only worth anything when it says what it left
        // out. [LAW:no-silent-failure]
        var scope = "\(shown.count) window\(shown.count == 1 ? "" : "s"), front to back"
        if shown.count != all.count { scope += "; \(all.count - shown.count) of \(all.count) filtered by owner" }
        scope += ". Owner and bounds; titles need Screen Recording."
        print(scope)

        for window in shown {
            let f = window.frame
            print("\(window.id)\t\(window.owner)\t\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))")
        }
    }
}
