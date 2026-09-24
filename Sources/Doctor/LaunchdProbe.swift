import DriverExtension
import Installations

/// Reading launchd for where this installation's job stands.
///
/// [LAW:effects-at-boundaries] The one command is run here and read by a pure function
/// beside it, so every standing - including a job loaded without its service, which takes
/// a second job to produce - is checked against launchd's real output on a Mac that is in
/// none of them.
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
    /// system` on stderr. Both are required, the status and the words: any other failure is
    /// refused, because a launchd that could not be read, reported as "no job", would send
    /// a reader to load a job that is already loaded. [LAW:no-silent-failure]
    static func standing(from printed: Command.Output, installation: Installation) throws -> JobStanding {
        let label = installation.launchdLabel
        guard printed.status == 0 else {
            guard printed.status == 113, printed.stderr.contains("Could not find service \"\(label)\"") else {
                throw DriverUnreadable.toolFailed(tool: "launchctl print system/\(label)", status: printed.status, complaint: printed.merged)
            }
            return .noJob
        }
        return try holds(endpointsIn: printed.stdout, label: label, service: installation.service) ? .holdingTheService : .loadedWithoutTheService
    }

    /// Whether the record launchd printed for `label` holds an endpoint for `service`.
    ///
    /// [LAW:parse-dont-validate] Read as the structure it is, not searched as text. The
    /// record has to open as the record for this label, or it is not an answer about this
    /// job and is refused - a format some later macOS prints differently must not read as
    /// every healthy job having lost its service. Then only the job's own `endpoints`
    /// block counts: the service's name appears elsewhere in a record that lacks the
    /// endpoint (measured, in its environment), and a quoted block key of the same shape
    /// could appear in any other block.
    ///
    /// The endpoint is handed out at load, so a job that holds the service names it in
    /// that block from then on, whether or not its daemon has run a line. A job without it
    /// has no such entry - measured, no `endpoints` block at all.
    ///
    /// pkg/scripts/postinstall asks the same question of the record it just loaded, with a
    /// grep; a test runs that grep against the same captures and holds the two to the same
    /// answers. [LAW:one-source-of-truth]
    static func holds(endpointsIn record: String, label: String, service: String) throws -> Bool {
        let lines = record.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "system/\(label) = {" else {
            throw LaunchdRecordUnrecognised(label: label, reason: "it does not open as the record for system/\(label)")
        }
        guard let open = lines.firstIndex(of: "\tendpoints = {") else { return false }
        guard let close = lines[open...].firstIndex(of: "\t}") else {
            throw LaunchdRecordUnrecognised(label: label, reason: "its endpoints block never closes")
        }
        return lines[open..<close].contains("\t\t\"\(service)\" = {")
    }
}

/// A record `launchctl print` printed that this build cannot read. Never a standing: a
/// shape nobody here has seen is not evidence of any one of them. [LAW:no-silent-failure]
public struct LaunchdRecordUnrecognised: Error, CustomStringConvertible, Equatable {
    public let label: String
    public let reason: String

    public var description: String {
        "`launchctl print system/\(label)` printed a record this build cannot read: \(reason)"
    }
}
