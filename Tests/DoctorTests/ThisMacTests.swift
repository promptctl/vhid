import ChildProcess
import DriverExtension
import Foundation
import Installations
import OwnThread
import Testing

@testable import Doctor

/// Doctor's reading of this Mac, against this Mac.
@Suite(.ownThread) struct ThisMacTests {
    /// A stopped reading stops the commands it runs: the driver and launchd rows read as
    /// the cancel rather than as whatever `systemextensionsctl` and `launchctl` would have
    /// said by their limit.
    @Test(.timeLimit(.minutes(1))) func aStoppedReadingReadsTheDriverAndTheJobAsCancelled() throws {
        let deadline = Command.Deadline.within(.seconds(3600))
        deadline.stop.pull()
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), by: deadline)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension] == "could not be read: \(CancellationError())")
        #expect(rows[.launchdJob] == "could not be read: \(CancellationError())")
    }

    /// The driver and launchd are read by one limit, the caller's: a limit already spent
    /// starts neither, and each row says so, where a limit apiece would have run both.
    @Test(.timeLimit(.minutes(1))) func aSpentLimitStartsNeitherProbeAndEachRowSaysSo() throws {
        let deadline = Command.Deadline.within(.zero)
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), by: deadline)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension]?.contains("was not started: the limit of 0.0 seconds was spent before it") == true)
        #expect(rows[.launchdJob]?.contains("was not started: the limit of 0.0 seconds was spent before it") == true)
    }
}
