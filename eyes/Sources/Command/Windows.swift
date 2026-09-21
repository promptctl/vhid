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
        abstract: "List the on-screen windows, front to back, with their layer and bounds."
    )

    @Option(help: "Only windows owned by applications whose name contains this.")
    var owner: String?

    /// [LAW:no-silent-failure] An empty `--owner` matches nothing at all, because
    /// `localizedCaseInsensitiveContains("")` is false - so the one spelling a caller
    /// never means produces the one answer they cannot argue with: zero windows, on a
    /// screen full of them. It arrives from `--owner "$APP"` with `APP` unset, which is a
    /// mistake worth a sentence rather than a confident empty list.
    func validate() throws {
        guard owner?.isEmpty != true else {
            throw ValidationError(
                "--owner was given an empty value, which would filter out every window. "
                    + "Leave --owner off to list them all. (A shell variable that did not expand?)"
            )
        }
    }

    @MainActor
    func run() async throws {
        let listing = try Geometry.onScreen()
        // The filter always runs; an absent --owner is a predicate that admits everything
        // rather than a branch that skips the operation. [LAW:dataflow-not-control-flow]
        let shown = listing.windows.filter { window in
            owner.map { window.owner?.localizedCaseInsensitiveContains($0) ?? false } ?? true
        }

        print(Self.scope(shown: shown.count, listing: listing))
        for window in shown {
            print(Self.row(window))
        }
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
    static func scope(shown: Int, listing: WindowListing) -> String {
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
    }

    /// One window as a row: id, owner, layer, then the rectangle in the coordinates vhid
    /// clicks. Tab-separated because the owner is the one field that can hold a space.
    static func row(_ window: Window) -> String {
        let f = window.frame
        // A window whose owning process has no application name is still a window with a
        // place to click; it is named as unnamed rather than left blank, so the column
        // cannot be mistaken for an empty field.
        return "\(window.id)\t\(window.owner ?? "(unnamed)")\tL\(window.layer)"
            + "\t\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))"
    }
}
