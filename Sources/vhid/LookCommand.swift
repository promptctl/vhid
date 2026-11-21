import ArgumentParser
import EyesVerbs
import enum Seeing.SourceKind
import enum Seeing.Until

/// What is on screen, as the `look` tool answers it: the arguments are the tool's, each
/// said by the one phrase both show, and read by the one rule both read by.
/// [LAW:one-source-of-truth]
struct LookCommand: AsyncParsableCommand {
    static let configuration = Help.look.configuration

    @Option(help: .sentence(LookHelp.text))
    var text: String?

    @Flag(help: .sentence(LookHelp.exact))
    var exact = false

    @Option(help: .sentence(LookHelp.edits))
    var edits: Int?

    @Option(help: .sentence(LookHelp.near))
    var near: String?

    @Option(help: .sentence(LookHelp.until))
    var until: Until?

    @Option(help: .sentence(LookHelp.timeout))
    var timeout: Double?

    /// The place, declared once for `vhid look` and `eyes find` and `read`.
    @OptionGroup var place: Where

    @Option(help: .sentence(LookHelp.limit))
    var limit: Int?

    @Option(help: .sentence(LookHelp.source))
    var source: SourceKind?

    @Option(help: .sentence(LookHelp.role))
    var role: String?

    @Option(parsing: .unconditional, help: .sentence(Help.lookX))
    var x: Double?

    @Option(parsing: .unconditional, help: .sentence(Help.lookY))
    var y: Double?

    func validate() throws { _ = try asked() }

    @MainActor
    func run() async throws { print(try await asked().answer()) }

    private func asked() throws -> Asked {
        try Asked.parsed(text: text, exact: exact, edits: edits, near: near, until: until, timeout: timeout,
                         display: place.display, window: place.window, page: place.page, rect: place.rect, app: place.app,
                         limit: limit, source: source, role: role, x: x, y: y, as: .flag)
    }
}
