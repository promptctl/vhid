import ArgumentParser
import Doctor
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

    /// A grant reading that failed is said as unknown, naming why, and the rows still stand.
    @Test func grantsThatCouldNotBeReadAreSaidAsUnknown() async throws {
        struct Unread: Error, CustomStringConvertible { var description: String { "the child exited 1" } }
        let grants = try await DoctorCommand.grants { throw Unread() }
        let readiness = Readiness(installation: .development, driver: .success(.running), job: .success(.holdingTheService),
                                  daemon: .answered(holder: nil), keyboardSetupAssistantAnswered: .success(true))
        #expect(DoctorCommand.doctor(readiness, grants: grants).hasSuffix(
            "\n\nWhether Screen Recording and Accessibility are granted is unknown: the child exited 1"))
    }

    /// A doctor withdrawn while it reads the grants is withdrawn, not answered as unknown.
    @Test func aWithdrawnGrantReadingWithdrawsTheDoctor() async {
        await #expect(throws: CancellationError.self) { _ = try await DoctorCommand.grants { throw CancellationError() } }
    }
}
