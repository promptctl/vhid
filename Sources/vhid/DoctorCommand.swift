import ArgumentParser
import Doctor

/// Every requirement a verb needs before it can reach the devices, as this Mac stands.
///
/// **A driver, not a nanny.** It reads and names the step; it fixes nothing. The status
/// call it makes of the daemon claims nothing, so it can be run while another client holds
/// the devices.
///
/// [CLI] On stdout a verdict, `ready` or `not ready`, then the rows, every one every time.
/// Exit 0 when every row is met and 1 when any is not, so `vhid doctor && vhid type ...`
/// types only on a Mac that can.
struct DoctorCommand: ParsableCommand {
    static let configuration = Help.doctor.configuration

    @OptionGroup var service: ServiceOption

    func run() throws {
        let readiness = Readiness.read(for: try service.installation())
        print(Self.doctor(readiness))
        guard readiness.ready else { throw ExitCode(1) }
    }

    /// What the verb prints and its MCP tool answers: the verdict in a word, then the rows.
    /// [LAW:one-source-of-truth]
    static func doctor(_ readiness: Readiness) -> String {
        "\(readiness.ready ? "ready" : "not ready")\n\(readiness)"
    }
}
