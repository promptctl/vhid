import ArgumentParser
import Doctor

/// Every requirement a verb needs before it can reach the devices, as this Mac stands.
///
/// **A driver, not a nanny.** It reads and names the step; it changes nothing. The status
/// call it makes of the daemon claims nothing, so it can be run while another client holds
/// the devices.
///
/// [CLI] The rows on stdout, every one every time. Exit 0 when every row is met and 1
/// when any is not, so `vhid doctor && vhid type ...` types only on a Mac that can.
struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Print every requirement a verb needs, and the step left for any that is not met.",
        discussion: """
            One row per requirement, in the order they depend on each other: what it is, what was \
            read on this Mac, and, indented under it, the step left for a person. Exits 1 when any \
            row has a step. Nothing is changed on the Mac, and the devices are not taken from a \
            client that holds them.
            """)

    @OptionGroup var service: ServiceOption

    func run() throws {
        let readiness = Readiness.read(for: try service.installation())
        print(readiness)
        guard readiness.ready else { throw ExitCode(1) }
    }
}
