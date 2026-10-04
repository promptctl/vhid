import DriverExtension
import Foundation
import Installations
import OwnThread
import Testing

@testable import Doctor

/// Doctor's reading of this Mac, against this Mac.
@Suite(.ownThread) struct ThisMacTests {
    /// A stopped reading stops the commands it runs: the driver and launchd rows read as
    /// the cancel, at once, rather than as whatever `systemextensionsctl` and `launchctl`
    /// would have said by their limit.
    @Test(.timeLimit(.minutes(1))) func aStoppedReadingReadsTheDriverAndTheJobAsCancelled() throws {
        let stop = Command.Stop()
        stop.pull()
        let began = ContinuousClock.now
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), stoppedBy: stop)
        #expect(ContinuousClock.now - began < .seconds(10))
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension] == "could not be read: \(CancellationError())")
        #expect(rows[.launchdJob] == "could not be read: \(CancellationError())")
    }
}
