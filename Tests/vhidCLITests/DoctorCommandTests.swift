import ArgumentParser
import Installations
import OwnThread
import Testing
@testable import vhid

/// The verb's contract with a shell: the rows on stdout, and exit 1 when any is unmet.
@Suite(.ownThread) struct DoctorCommandTests {
    /// A service nothing registers is never ready, on any Mac, so this exit is fixed.
    @Test func aMacThatIsNotReadyExitsOne() async throws {
        let doctor = try DoctorCommand.parse(["--service", Installation.nobody.service])
        let exit = await #expect(throws: ExitCode.self) { try await doctor.run() }
        #expect(exit == ExitCode(1))
    }

    /// A --service that names nothing is refused before anything is read. [LAW:single-enforcer]
    @Test func aServiceThatIsNotANameIsRefused() {
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--service", "bad name"]) }
    }
}
