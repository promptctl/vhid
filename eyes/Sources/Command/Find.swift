import ArgumentParser
import Eyes

/// Where a piece of text is, as the point `vhid click` presses.
struct Find: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find text on screen and print the point vhid clicks to hit it.",
        discussion: "Case never matters. With nothing found, prints the nearest runs and how many edits off each is."
    )

    @Argument(help: .init(stringLiteral: Help.text))
    var text: String

    @Flag(help: .init(stringLiteral: Help.exact))
    var exact = false

    @Option(help: .init(stringLiteral: Help.edits))
    var edits: Int?

    @Option(help: "The most matches to print.")
    var limit = Limit.default.count

    @OptionGroup var place: Where

    @Option(help: .init(stringLiteral: Help.source))
    var source = SourceKind.merged

    func validate() throws {
        _ = try Self.match(text, exact: exact, edits: edits, as: .flag)
        _ = try Where.limit(limit, as: .flag)
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: Self.match(text, exact: exact, edits: edits, as: .flag),
                             region: place.region, limit: Where.limit(limit, as: .flag)), source: source)
    }

    /// What to match, or the refusal - one rule for the verb and the MCP tool, each naming
    /// an argument the way its caller spells it. [LAW:single-enforcer]
    static func match(_ text: String, exact: Bool, edits: Int?, as s: Spelling) throws -> Match {
        guard Text(text) != nil else { throw ValidationError("the text to find is blank") }
        guard !(exact && edits != nil) else { throw ValidationError("give \(s("exact")) or \(s("edits")), not both") }
        guard let edits else { return exact ? .exact(text) : .contains(text) }
        guard let within = Edits(edits) else { throw ValidationError("\(s("edits")) cannot be negative") }
        return .within(edits: within, of: text)
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

    @Option(help: .init(stringLiteral: Help.source))
    var source = SourceKind.merged

    func validate() throws {
        _ = try Where.limit(limit, as: .flag)
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: nil, region: place.region, limit: Where.limit(limit, as: .flag)), source: source)
    }
}
