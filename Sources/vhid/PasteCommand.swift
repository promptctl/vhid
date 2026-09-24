import ArgumentParser
import Input
import KeyboardLayout

/// Puts text in through the clipboard: writes it there and presses the layout's Command-V.
struct PasteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paste",
        abstract: "Paste text through the clipboard with the virtual keyboard.",
        discussion: """
            The text is written to the clipboard and Command-V is pressed, wherever keys would go if \
            they were pressed on hardware. Nothing here chooses or checks what is in front. Text the \
            layout has no keys for can be pasted, emoji and other scripts included.

            The cost is the user's clipboard: the text replaces what was there and stays. Nothing \
            puts the old contents back.

            Which key is V is the console user's layout's to say, read in this process as for keys.

            Text starting with - follows --, as in: vhid paste -- "-5 degrees".
            """)

    @Argument(help: "The text to paste, emoji and scripts the layout has no keys for included.")
    var text: String

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let layout = try KeyboardLayout.current()
        print(try await Devices.using(try service.installation()) { try await Self.paste(text, on: layout, with: $0.typist) })
    }

    /// The verb itself, over a typist and a pasteboard from anywhere. [LAW:decomposition]
    /// The pasteboard every app pastes from is the default, so the CLI and the tool cannot
    /// come to write different ones. [LAW:one-source-of-truth]
    ///
    /// The chord is reported in the spelling that reads back, as `keys` reports its own:
    /// what was asked for was V, and what was pressed is the key this layout puts V on.
    @MainActor
    static func paste(_ text: String, on layout: KeyboardLayout, with typist: Typist,
                      through write: @MainActor (String) throws -> Void = { try Clipboard.general.write($0) }) async throws -> String {
        let chord = try await typist.paste(text, on: layout, through: write)
        return "pasted \(counted(text.count, "character")) with \(chord) on \(layout.name)"
    }
}
