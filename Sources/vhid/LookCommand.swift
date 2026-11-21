import ArgumentParser
import EyesVerbs

/// What is on screen, as the `look` tool reads it: the same arguments, read by the same
/// `Look.question`, answered by the same `Look.answer`. [LAW:one-source-of-truth]
///
/// [CLI] Prints the answer on stdout. A look that could not read exits 1, saying why.
struct LookCommand: AsyncParsableCommand {
    static let configuration = Help.look.configuration

    typealias Said = EyesVerbs.Help

    @Option(help: .sentence(Said.app)) var app: String?
    @Option(help: .sentence(Said.text)) var text: String?
    @Flag(help: .sentence(Said.exact)) var exact = false
    @Option(help: .sentence(Said.edits)) var edits: Int?
    @Option(help: .sentence(Said.near)) var near: String?
    @Option(help: .sentence(Said.role)) var role: String?
    @Option(help: .sentence(Said.source)) var source: String?
    @Option(help: .sentence(Said.limit)) var limit: Int?
    @Option(help: .sentence(Said.display)) var display: UInt32?
    @Option(help: .sentence(Said.window)) var window: UInt32?
    @Option(help: .sentence(Said.page)) var page: UInt32?
    /// Taken whatever it starts with: a box or a point left of or above the main display
    /// starts with a minus, which would otherwise read as a flag.
    @Option(parsing: .unconditional, help: .sentence(Said.rect)) var rect: String?
    @Option(parsing: .unconditional, help: .sentence(Help.lookX)) var x: Double?
    @Option(parsing: .unconditional, help: .sentence(Help.lookY)) var y: Double?
    @Option(help: .sentence(Said.until)) var until: String?
    @Option(help: .sentence(Said.timeout)) var timeout: Double?

    func validate() throws { _ = try question() }

    func run() async throws {
        print(try await Look.answer(try question(), on: .live))
    }

    private func question() throws -> Look.Question {
        try Look.question(app: app, text: text, exact: exact, edits: edits, near: near, role: role, source: source, limit: limit,
                          display: display, window: window, page: page, rect: rect, x: x, y: y, until: until, timeout: timeout,
                          as: .flag)
    }
}
