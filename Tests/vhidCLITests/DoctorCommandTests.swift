import ArgumentParser
import Installations
import Testing
@testable import vhid

/// The verb's contract with a shell: the rows on stdout, and exit 1 when any is unmet.
@Suite struct DoctorCommandTests {
    /// A service nothing registers is never ready, on any Mac, so this exit is fixed.
    @Test func aMacThatIsNotReadyExitsOne() throws {
        let doctor = try DoctorCommand.parse(["--service", Installation.nobody.service])
        let exit = #expect(throws: ExitCode.self) { try doctor.run() }
        #expect(exit == ExitCode(1))
    }

    /// A --service that names nothing is refused before anything is read. [LAW:single-enforcer]
    @Test func aServiceThatIsNotANameIsRefused() {
        #expect(throws: (any Error).self) { try DoctorCommand.parse(["--service", "bad name"]) }
    }
}
