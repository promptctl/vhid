import ChildProcess
import DriverExtension
import Foundation
import Installations
import OwnThread
import TestClock
import Time
import Testing

@testable import Doctor

/// Doctor's reading of this Mac, against this Mac.
@Suite(.ownThread) struct ThisMacTests {
    /// A stopped reading stops the commands it runs: the driver and launchd rows read as
    /// the cancel, at once, rather than as whatever `systemextensionsctl` and `launchctl`
    /// would have said by their limit.
    @Test func aStoppedReadingReadsTheDriverAndTheJobAsCancelled() throws {
        let stop = Command.Stop()
        stop.pull()
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), by: .within(Command.limit, on: Clock(ManualClock())), or: stop)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension] == "could not be read: \(CancellationError())")
        #expect(rows[.launchdJob] == "could not be read: \(CancellationError())")
    }
}
