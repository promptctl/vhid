import ArgumentParser
import Eyes

/// Where a piece of text is, as the point `vhid click` presses.
struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find text on screen and print the point vhid clicks to hit it.",
        discussion: "Case never matters. With nothing found, prints the nearest runs and how many edits off each is."
    )

    @Argument(help: "The text to look for. Matches any run that contains it.")
    var text: String

    @Flag(help: "Match only a run that is exactly this text.")
    var exact = false

    @Option(help: "Match a run within this many single-character edits of the text, for recogniser slips.")
    var edits: Int?

    @Option(help: "The most matches to print.")
    var limit = Limit.default.count

    @OptionGroup var place: Where

    func validate() throws {
        _ = try Self.match(text, exact: exact, edits: edits, flag: "--")
        _ = try Self.limit(limit, flag: "--")
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: Self.match(text, exact: exact, edits: edits, flag: "--"),
                             region: place.region, limit: Self.limit(limit, flag: "--")))
    }

    /// What to match, or the refusal - one rule for the verb and the MCP tool, each naming
    /// an argument the way its caller spells it (`flag` is `--` or nothing).
    /// [LAW:single-enforcer]
    static func match(_ text: String, exact: Bool, edits: Int?, flag: String) throws -> Match {
        guard Text(text) != nil else { throw ValidationError("the text to find is blank") }
        guard !(exact && edits != nil) else { throw ValidationError("give \(flag)exact or \(flag)edits, not both") }
        guard let edits else { return exact ? .exact(text) : .contains(text) }
        guard let within = Edits(edits) else { throw ValidationError("\(flag)edits cannot be negative") }
        return .within(edits: within, of: text)
    }

    static func limit(_ count: Int, flag: String) throws -> Limit {
        guard let limit = Limit(count) else { throw ValidationError("\(flag)limit must be at least 1") }
        return limit
    }
}

/// Every piece of text in a region, each with its point, in reading order.
struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the text in a region, one run per row, with the point vhid clicks to hit it."
    )

    @Option(help: "The most runs to print.")
    var limit = Limit.default.count

    @OptionGroup var place: Where

    func validate() throws {
        _ = try Find.limit(limit, flag: "--")
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: nil, region: place.region, limit: Find.limit(limit, flag: "--")))
    }
}
