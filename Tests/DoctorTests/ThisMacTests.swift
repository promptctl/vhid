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
    /// said. A command is refused before it starts once its stop is pulled, so neither
    /// is run at all.
    @Test(.timeLimit(.minutes(1))) func aStoppedReadingReadsTheDriverAndTheJobAsCancelled() throws {
        let stop = Command.Stop()
        stop.pull()
        let readiness = Readiness.read(for: try #require(Installation(service: "ai.promptctl.vhid.tests.nobody")), stoppedBy: stop)
        let rows = Dictionary(uniqueKeysWithValues: readiness.requirements.map { ($0.row, $0.reads) })
        #expect(rows[.driverExtension] == "could not be read: \(CancellationError())")
        #expect(rows[.launchdJob] == "could not be read: \(CancellationError())")
    }
}
