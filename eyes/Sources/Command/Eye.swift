import ArgumentParser

/// The binary.
///
/// Not named `main.swift`: a file by that name is the module's top-level entry point, and
/// a module with one cannot be imported, which would leave everything below it reachable
/// only by running the binary and reading its output. [LAW:verifiable-goals]
@main
struct Eye: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eyes",
        abstract: "Say what is on screen and where, in the coordinates vhid clicks.",
        subcommands: [Windows.self]
    )
}
