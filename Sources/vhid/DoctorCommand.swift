import Time
import ChildProcess
import ArgumentParser
import Doctor
import EyesVerbs
import enum Grants.Grant
import Telemetry

/// Every requirement a verb needs before it can reach the devices, as this Mac stands.
///
/// **A driver, not a nanny.** It reads and names the step; it fixes nothing. The status
/// call it makes of the daemon claims nothing, so it can be run while another client holds
/// the devices.
///
/// [CLI] On stdout a verdict, `ready` or `not ready`, then the rows, every one every time.
/// Exit 0 when every row is met and 1 when any is not, so `vhid doctor && vhid type ...`
/// types only on a Mac that can.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = Help.doctor.configuration

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let installation = try service.installation()
        let readiness = try await reading(within: Command.limit, on: Vhid.timeline) { Readiness.read(for: installation, by: $0, or: $1) }
        print(Self.doctor(readiness, grants: try await Self.grants()))
        guard readiness.ready else { throw Verdict(1) }
    }

    /// What the verb prints and its MCP tool answers: the verdict in a word, then the rows,
    /// then the grants a look reads by and the app that must hold them. [LAW:one-source-of-truth]
    ///
    /// The verdict is the devices' alone: `vhid doctor && vhid type` types on a Mac that can,
    /// and typing needs no grant.
    static func doctor(_ readiness: Readiness, grants: Result<String, any Error>) -> String {
        let grants = switch grants {
        case .success(let rows): rows
        case .failure(let error): "Whether \(Grant.allCases.map(\.name).joined(separator: " and ")) are granted is unknown: \(error)"
        }
        return "\(readiness.ready ? "ready" : "not ready")\n\(readiness)\n\n\(grants)"
    }

    /// A fresh reading of the grants, or why there is none: an answer either way, except a
    /// withdrawal, which ends the verb as any cancel does.
    static func grants(_ read: () async throws -> String = { try await GrantsVerb.answer() }) async throws -> Result<String, any Error> {
        do { return .success(try await read()) } catch where !error.isCancellation { return .failure(error) }
    }
}
