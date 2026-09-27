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
        guard Text(text) != nil else { throw ValidationError("the text to find is blank") }
        guard !(exact && edits != nil) else { throw ValidationError("give --exact or --edits, not both") }
        guard edits.map({ Edits($0) != nil }) ?? true else { throw ValidationError("--edits cannot be negative") }
        guard Limit(limit) != nil else { throw ValidationError("--limit must be at least 1") }
    }

    var match: Match {
        edits.flatMap(Edits.init).map { .within(edits: $0, of: text) } ?? (exact ? .exact(text) : .contains(text))
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: match, region: place.region, limit: Limit(limit)!))
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
        guard Limit(limit) != nil else { throw ValidationError("--limit must be at least 1") }
    }

    @MainActor
    func run() async throws {
        try await look(Query(match: nil, region: place.region, limit: Limit(limit)!))
    }
}
