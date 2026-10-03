import ArgumentParser
import Input
import KeyboardLayouts

/// Types text on the virtual keyboard, wherever the keyboard happens to be pointed.
struct TypeCommand: AsyncParsableCommand {
    static let configuration = Help.type.configuration

    @Argument(help: Help.sentence(Help.text))
    var text: String

    @OptionGroup var layoutOption: LayoutOption
    @OptionGroup var aimOption: AimOption
    @OptionGroup var service: ServiceOption

    func run() async throws {
        let (layout, aim) = (try layoutOption.layout(), try aimOption.aim())
        print(try await Devices.using(try service.installation()) { try await Self.type(text, on: layout, into: aim, with: $0.typist) })
    }

    /// The verb itself, over a typist from anywhere.
    ///
    /// [LAW:decomposition] What the verb does and where the keyboard came from are two
    /// things, and only the second needs a daemon - which is what lets the first be run
    /// against a keyboard that records instead of typing.
    static func type(_ text: String, on layout: KeyboardLayout, into aim: Aim, with typist: Typist,
                     front: () async -> FrontApp? = FrontApp.inFront) async throws -> String {
        // [LAW:parse-dont-validate] Lowered whole before a key goes down, so text the
        // layout cannot type moves nothing: half a sentence in a document is worse than
        // none, because only one of the two is obviously wrong.
        let lowered = try typist.lower(text, on: layout)
        // Last, so the app in front is asked as near the first key as anything can be.
        try await aim.admit(front)
        let typed = try await typist.type(lowered)
        return "typed \(counted(typed, "character")) on \(layout.name)\(aim.said)"
    }
}
