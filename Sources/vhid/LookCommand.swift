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

    @Option(help: .sentence(LookHelp.display))
    var display: UInt32?

    @Option(help: .sentence(LookHelp.window))
    var window: UInt32?

    @Option(help: .sentence(LookHelp.page))
    var page: UInt32?

    /// Takes the next argument whatever it starts with, as a coordinate below does: a box on
    /// a display left of or above the main one starts with a minus.
    @Option(parsing: .unconditional, help: .sentence(LookHelp.rect))
    var rect: String?

    @Option(help: .sentence(LookHelp.app))
    var app: String?

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
                         display: display, window: window, page: page, rect: rect, app: app,
                         limit: limit, source: source, role: role, x: x, y: y, as: .flag)
    }
}
