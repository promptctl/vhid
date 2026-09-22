import Installations
import Testing
@testable import vhid

/// What `--service` becomes before any verb holds it. [LAW:parse-dont-validate]
@Suite struct ServiceOptionTests {
    @Test func noServiceIsTheCopyBuiltFromThisTree() throws {
        #expect(try ServiceOption.parse([]).installation() == .development)
    }

    @Test func aServiceNameIsTheInstallationItNames() throws {
        #expect(try ServiceOption.parse(["--service", "com.example.daemon"]).installation().service == "com.example.daemon")
    }

    /// launchd registers no label with a space in it, so a name holding one is refused
    /// at the parse rather than dialled and never answered.
    ///
    /// Thrown by `parse` and not by `installation()`, and that is the point being pinned:
    /// ArgumentParser runs `validate()` before any `run`, so a refused name comes back as
    /// the verb's own usage and before the keyboard layout is read or anything connected.
    @Test func aNameLaunchdCouldNotRegisterIsRefusedAtTheParse() {
        #expect(throws: (any Error).self) { try ServiceOption.parse(["--service", "two words"]) }
    }

    @Test func anEmptyNameIsRefusedAtTheParse() {
        #expect(throws: (any Error).self) { try ServiceOption.parse(["--service", ""]) }
    }

    /// The message names the flag and says what a service name may not be, because the
    /// operator reading it is holding a plist. [LAW:no-silent-failure]
    @Test func theRefusalSaysWhatIsWrongWithTheName() {
        let refusal = #expect(throws: (any Error).self) { try ServiceOption.parse(["--service", "two words"]) }
        let said = "\(refusal!)"
        #expect(said.contains("--service"))
        #expect(said.contains("whitespace"))
    }
}
