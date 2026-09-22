import ArgumentParser

/// The verbs, against a daemon that owns the two virtual devices.
///
/// **A driver, not a nanny.** It types what it is told to type and clicks where it is
/// told to click. Which app is in front, whether a dialog is covering it, and whether the
/// caller meant to do this are not its questions to ask, so no verb here takes a target
/// app, raises one, or reads the screen - and nothing it prints tells the caller what to
/// do next. What it reports is what the devices did.
@main
struct Vhid: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vhid",
        abstract: "Type and click on a virtual keyboard and mouse that macOS sees as hardware.",
        discussion: """
            The reports go to a root daemon that owns the devices, reached over its Mach service. \
            The daemon admits a caller carrying the certificate the daemon itself carries, so this \
            binary has to be signed with it: build with `make`, which signs, rather than with \
            `swift build`, which ad hoc signs and leaves every call refused.

            Coordinates are screen points from the top left of the main display, the same ones the \
            cursor is read back in.
            """,
        subcommands: [TypeCommand.self, KeysCommand.self, ClickCommand.self, PointerCommand.self])
}
