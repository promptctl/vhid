import ArgumentParser
import Version

/// The verbs, against a daemon that owns the two virtual devices.
///
/// **A driver, not a nanny.** It types what it is told to type and clicks where it is
/// told to click. Whether a dialog is covering an app and whether the caller meant to do
/// this are not its questions to ask, so no verb here raises an app or reads the screen
/// - and nothing it prints tells the caller what to do next. What it reports is what the
/// devices did. The one question it will ask for a caller is which app is in front, when
/// `type` or `press` is told the app its keys are for, and then only to refuse.
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

            When a verb fails, `vhid doctor` names what is not in place and the step left.

            Coordinates are \(Help.place).
            """,
        version: Version.current,
        subcommands: [
            TypeCommand.self, PressCommand.self, GestureCommand.self, ClickCommand.self, MoveCommand.self, ScrollCommand.self,
            DragCommand.self, CursorCommand.self, PlayCommand.self, RecordCommand.self, McpCommand.self, DriverCommand.self,
            ServiceCommand.self, DoctorCommand.self,
        ])
}
