import ArgumentParser
import Input
import KeyboardLayout

/// Types text on the virtual keyboard, wherever the keyboard happens to be pointed.
struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text on the virtual keyboard.",
        discussion: """
            The text is typed wherever keys would go if they were pressed on hardware. Nothing here \
            chooses or checks what is in front.

            The console user's own keyboard layout decides which keys make which characters, and it \
            is read in this process rather than in the daemon: macOS answers that question per \
            process, and a root daemon asking it is told the US layout whatever the user is typing on. \
            Text it has no keys for is refused whole; paste puts text in through the clipboard instead.

            Text starting with - follows --, as in: vhid type -- "-5 degrees".
            """)

    @Argument(help: "The text to type: anything the layout has keys for, dead-key sequences and line breaks included.")
    var text: String

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let layout = try KeyboardLayout.current()
        print(try await Devices.using(try service.installation()) { try await Self.type(text, on: layout, with: $0.typist) })
    }

    /// The verb itself, over a typist from anywhere.
    ///
    /// [LAW:decomposition] What the verb does and where the keyboard came from are two
    /// things, and only the second needs a daemon - which is what lets the first be run
    /// against a keyboard that records instead of typing.
    static func type(_ text: String, on layout: KeyboardLayout, with typist: Typist) async throws -> String {
        // [LAW:parse-dont-validate] Lowered whole before a key goes down, so text the
        // layout cannot type moves nothing: half a sentence in a document is worse than
        // none, because only one of the two is obviously wrong.
        let lowered = try typist.lower(text, on: layout)
        let typed = try await typist.type(lowered)
        return "typed \(counted(typed, "character")) on \(layout.name)"
    }
}
