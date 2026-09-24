import DriverExtension
import Installations

/// Reading launchd for where this installation's job stands.
///
/// [LAW:effects-at-boundaries] The one command is run here and read by a pure function
/// beside it, so every standing - including a job that lost its service to another, which
/// takes a second job to produce - is checked against launchd's real output on a Mac that
/// is in none of them.
///
/// Read without root: `launchctl print` answers any user about a system-domain job.
public enum LaunchdProbe {
    /// Where launchd stands on the job under this installation's label, asked now.
    public static func standing(of installation: Installation) throws -> JobStanding {
        try standing(from: Command("/bin/launchctl", "print", "system/\(installation.launchdLabel)").run(), installation: installation)
    }

    /// What launchd said, read.
    ///
    /// A label launchd has never heard of is a normal answer, and the one this returns
    /// `noJob` for - measured: exit 113, and `Could not find service "<label>" in domain for
    /// system` on stderr. Any other failure is refused: a launchd that could not be read,
    /// reported as "no job", would send a reader to load a job that is already loaded.
    /// [LAW:no-silent-failure]
    static func standing(from printed: Command.Output, installation: Installation) throws -> JobStanding {
        guard printed.status == 0 else {
            guard printed.merged.contains("Could not find service \"\(installation.launchdLabel)\"") else {
                throw LaunchdUnreadable(label: installation.launchdLabel, status: printed.status, complaint: printed.merged)
            }
            return .noJob
        }
        // The endpoint is handed out at load, so a job that holds the service names it in
        // its `endpoints` block from then on, whether or not its daemon has run a line. A
        // job that asked for the service and lost has no such entry - measured, no
        // `endpoints` block at all - because launchd does not make the loser loud.
        //
        // [LAW:one-source-of-truth] The same marker pkg/scripts/postinstall greps for when
        // it decides whether the job it just loaded got the endpoint, so the installer and
        // doctor cannot come to disagree about one job; a test holds the two together.
        return printed.stdout.contains(endpointMarker(installation)) ? .holdingTheService : .anotherJobHoldsTheService
    }

    /// The line launchd prints for a job's hold on this installation's service.
    static func endpointMarker(_ installation: Installation) -> String {
        "\"\(installation.service)\" = {"
    }
}

/// Why launchd could not be read. Never a standing: "I could not look" and "there is no
/// job" are different facts, and a reader that cannot tell them apart acts on the second.
/// [LAW:no-silent-failure]
public struct LaunchdUnreadable: Error, CustomStringConvertible, Equatable {
    public let label: String
    public let status: Int32
    public let complaint: String

    public var description: String {
        "`launchctl print system/\(label)` exited \(status)\(complaint.isEmpty ? "" : ": \(complaint)")"
    }
}
