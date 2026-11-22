@testable import ChildProcess
import DriverExtension
import Foundation
import Installations
import OwnThread
import Testing
import Waiting

@testable import Doctor

/// Doctor's reading of this Mac, against this Mac.
@Suite(.ownThread) struct ThisMacTests {
    /// A stopped reading stops the commands it runs and makes no status call: the driver,
    /// launchd and daemon rows read as the cancel rather than as whatever
    /// `systemextensionsctl`, `launchctl` and the daemon would have said by their limit.
    @Test(.hangLimit) func aStoppedReadingReadsTheDriverAndTheJobAsCancelled() throws {
        let deadline = Command.Deadline.within(.seconds(3600))
        deadline.stop.pull()
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), by: deadline)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension] == "could not be read: \(CancellationError())")
        #expect(rows[.launchdJob] == "could not be read: \(CancellationError())")
        #expect(rows[.daemon] == "could not be read: \(CancellationError())")
    }

    /// The driver, launchd and the daemon are read by one limit, the caller's: a limit
    /// already spent starts none of them, and each row says so, where a limit apiece would
    /// have run them all.
    @Test(.hangLimit) func aSpentLimitStartsNeitherProbeAndEachRowSaysSo() throws {
        let deadline = Command.Deadline.within(.zero)
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), by: deadline)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension]?.contains("was not started: the limit of 0.0 seconds was spent before it") == true)
        #expect(rows[.launchdJob]?.contains("was not started: the limit of 0.0 seconds was spent before it") == true)
        #expect(rows[.daemon] == "could not be read: `the daemon's status call` was not started: the limit of 0.0 seconds was spent before it")
    }
}
