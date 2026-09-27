import AppKit
import ArgumentParser
import Eyes
import Foundation

/// Where the windows are, which a caller can ask before capturing anything.
///
/// It exists because the cheapest useful question about a screen is not what it says but
/// how it is divided: an owner, a layer and a rectangle per window is a couple of hundred
/// tokens and it tells a caller which application holds which part of the display.
/// Nothing here captures, recognises, or reads an accessibility tree, and it needs no
/// grant.
struct Windows: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List the on-screen windows, front to back, with their layer and bounds, and the application keys go to."
    )

    @Option(help: "Only windows owned by applications whose name contains this.")
    var owner: String?

    /// [LAW:no-silent-failure] An empty `--owner` matches nothing at all, because
    /// `localizedCaseInsensitiveContains("")` is false - so the one spelling a caller
    /// never means produces the one answer they cannot argue with: zero windows, on a
    /// screen full of them. It arrives from `--owner "$APP"` with `APP` unset, which is a
    /// mistake worth a sentence rather than a confident empty list.
    func validate() throws {
        try Self.refuseEmpty(owner, named: "--owner", " (A shell variable that did not expand?)")
    }

    /// One wording for the command line and the MCP tool alike, each naming the argument
    /// the way its caller spelled it. [LAW:single-enforcer]
    static func refuseEmpty(_ owner: String?, named name: String, _ hint: String = "") throws {
        guard owner?.isEmpty != true else {
            throw ValidationError(
                "\(name) was given an empty value, which would filter out every window. "
                    + "Leave \(name) off to list them all.\(hint)"
            )
        }
    }

    @MainActor
    func run() async throws {
        print(Self.report(try Geometry.onScreen(), owner: owner, frontmost: Frontmost.now()))
    }

    /// The scope line and a row per window: what the verb prints and what the MCP tool
    /// answers, from one function, so the two cannot report differently.
    /// [LAW:one-source-of-truth]
    ///
    /// The frontmost application's rows are marked by its pid, not found by row order:
    /// menus and the Dock sit on higher layers, so the first row is often not its window.
    static func report(_ listing: WindowListing, owner: String?, frontmost: Frontmost?) -> String {
        // The filter always runs; an absent owner is a predicate that admits everything
        // rather than a branch that skips the operation. [LAW:dataflow-not-control-flow]
        let shown = listing.windows.filter { window in
            owner.map { window.owner?.localizedCaseInsensitiveContains($0) ?? false } ?? true
        }
        let rows = shown.map { row($0) + ($0.pid == frontmost?.pid ? "\tfront" : "") }
        let front = frontmost.map { app in (app, shown.contains { $0.pid == app.pid }) }
        return ([scope(shown: shown.count, listing: listing, frontmost: front)] + rows).joined(separator: "\n")
    }

    /// The scope line, printed before the findings, because every reading below it is
    /// narrower than the screen and a narrow answer is only worth anything when it says
    /// what it left out. [LAW:no-silent-failure]
    ///
    /// It names all three narrowings, including the one no count can reach: the window
    /// server is asked for on-screen windows only, so minimized and hidden ones were
    /// never in the answer to be excluded from it. Measured, that is 29 against 110 - a
    /// caller told "no Safari window" while Safari sits minimized has been told something
    /// true about the screen and false about the question they asked.
    ///
    /// Pure, so the sentence a caller has to trust is checked by a test rather than read
    /// off a terminal by eye. [LAW:effects-at-boundaries]
    ///
    /// It names the frontmost application whether or not a row of it is shown, because
    /// that is where keystrokes go, and says so when nothing is frontmost.
    static func scope(shown: Int, listing: WindowListing, frontmost: (app: Frontmost, shown: Bool)?) -> String {
        let filtered = listing.windows.count - shown
        let clauses: [String?] = [
            "\(shown) window\(shown == 1 ? "" : "s"), front to back",
            filtered > 0 ? "\(filtered) of \(listing.windows.count) filtered by owner" : nil,
            listing.excluded.isEmpty
                ? nil
                : "\(listing.listed) listed, "
                    + listing.excluded.map { "\($0.count) \($0.reason.rawValue)" }.joined(separator: ", "),
        ]
        return clauses.compactMap { $0 }.joined(separator: "; ")
            + ". On screen only: minimized, hidden and other-Space windows were never looked at."
            + " Owner, layer and bounds; titles need Screen Recording."
            + (frontmost.map { " Keys go to \($0.app), " + ($0.shown ? "its rows marked front." : "which has no row here.") }
                ?? " No application is frontmost.")
    }

    /// One window as a row: id, owner, layer, then the rectangle in the coordinates vhid
    /// clicks. Tab-separated because the owner is the one field that can hold a space.
    static func row(_ window: Window) -> String {
        // A window whose owning process has no application name is still a window with a
        // place to click; it is named as unnamed rather than left blank, so the column
        // cannot be mistaken for an empty field.
        return "\(window.id)\t\(window.owner ?? "(unnamed)")\tL\(window.layer)"
            + "\t\(window.frame)"
    }
}

/// The application keystrokes go to: what `vhid type` reaches, and nothing eyes chooses.
struct Frontmost: Sendable, Hashable, CustomStringConvertible {
    let pid: Int32
    let name: String?

    var description: String { "\(name ?? "(unnamed)") (pid \(pid))" }

    @MainActor
    static func now() -> Frontmost? {
        NSWorkspace.shared.frontmostApplication.map { Frontmost(pid: $0.processIdentifier, name: $0.localizedName) }
    }
}
