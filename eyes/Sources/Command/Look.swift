import ArgumentParser
import CoreGraphics
import Eyes
import Pixels

/// Where `find` and `read` look, shared so the two verbs cannot disagree about it.
struct Where: ParsableArguments {
    @Option(help: "Read this display, by its window-server id, which every scope line names. Defaults to the main display.")
    var display: UInt32?

    @Option(help: "Read this window's bounds, by the id `eyes windows` prints.")
    var window: UInt32?

    @Option(help: "Read this rectangle: x,y,width,height in the points vhid clicks.")
    var rect: String?

    func validate() throws {
        guard [display != nil, window != nil, rect != nil].filter({ $0 }).count <= 1 else {
            throw ValidationError("give at most one of --display, --window, --rect")
        }
        _ = try parsedRect()
    }

    private func parsedRect() throws -> ScreenRect? {
        try rect.map { spelled in
            let parts = spelled.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, let x = parts[0], let y = parts[1], let w = parts[2], let h = parts[3],
                  [x, y, w, h].allSatisfy({ abs($0) <= 1_000_000 }), w > 0, h > 0
            else { throw ValidationError("--rect wants x,y,width,height in points - a positive size, nothing past a million - got \(spelled)") }
            return ScreenRect(x: x, y: y, width: w, height: h)
        }
    }

    /// The main display is the default rather than every display, because `Region` has no
    /// word for everywhere; the scope line names which display was read, so the default is
    /// never mistaken for the whole desk.
    var region: Region {
        get throws {
            try parsedRect().map(Region.rect)
                ?? window.map(Region.window)
                ?? .display(display ?? CGMainDisplayID())
        }
    }
}

/// What `find` and `read` print. Pure, so the sentences a caller trusts are tested.
/// [LAW:effects-at-boundaries]
enum Report {
    static func lines(_ reading: Reading, query: Query) -> [String] {
        [scope(reading, query: query)] + rows(reading.outcome)
    }

    /// Names where it looked, how much it read, and every narrowing, before any row.
    /// [LAW:no-silent-failure]
    static func scope(_ reading: Reading, query: Query) -> String {
        let s = reading.scope
        let asked = query.match.map(wanted)
        let head: String = switch reading.outcome {
        case .matched(let m):
            asked.map { "\(m.count) matched \($0)" } ?? "\(m.count) run\(m.count == 1 ? "" : "s")"
        case .nearest:
            asked.map { "\($0) not found" } ?? "no text"
        }
        let clauses: [String?] = [
            "\(head) in \(place(query.region)) \(s.region)",
            "\(s.examined) run\(s.examined == 1 ? "" : "s") read",
            s.excluded.isEmpty ? nil : s.excluded.map { "\($0.count) \($0.reason.rawValue)" }.joined(separator: ", "),
            reach(s.reach),
            reading.outcome == .nearest([]) || reading.outcome.isMatched ? nil : "nearest follow",
        ]
        return clauses.compactMap { $0 }.joined(separator: "; ") + ". Points are centres, vhid click coordinates."
    }

    /// One run per row: the centre a click lands on, then the text. The nearest rows add
    /// how many edits off they were.
    static func rows(_ outcome: Outcome) -> [String] {
        switch outcome {
        case .matched(let m): m.all.map { "\(point($0.frame.centre))\t\($0.text)" }
        case .nearest(let near): near.map { "\(point($0.found.frame.centre))\t\($0.found.text)\t\($0.distance) off" }
        }
    }

    private static func wanted(_ match: Match) -> String {
        switch match {
        case .contains(let s): "\"\(s)\""
        case .exact(let s): "exactly \"\(s)\""
        case .within(let e, let s): "\"\(s)\" within \(e.count) edit\(e.count == 1 ? "" : "s")"
        }
    }

    private static func place(_ region: Region) -> String {
        switch region {
        case .display(let id): "display \(id)"
        // Its bounds, as pixels: a window partly under another reads what is on top.
        case .window(let id): "what is on top over window \(id)"
        case .rect: "rect"
        }
    }

    private static func reach(_ reach: Reach) -> String {
        switch reach {
        case .whole: "whole region read"
        case .stopped(.resultLimit(let l)): "stopped at the limit of \(l.count)"
        case .stopped(.elementLimit(let l)): "stopped at \(l.count) elements"
        case .stopped(.timeBudget(let d)): "stopped after \(d)"
        case .stopped(.unread): "parts left unread"
        }
    }

    private static func point(_ p: ScreenPoint) -> String { "\(Int(p.x.rounded())),\(Int(p.y.rounded()))" }
}

private extension Outcome {
    var isMatched: Bool { if case .matched = self { true } else { false } }
}

/// Reads with the pixel reader and prints. The one place the verbs meet the screen.
@MainActor
func look(_ query: Query) async throws {
    let reading = try await PixelReader().read(query)
    Report.lines(reading, query: query).forEach { print($0) }
}
