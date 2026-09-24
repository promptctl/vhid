import DriverExtension
import Foundation
import Installations
import Testing

@testable import Doctor

/// The launchd reading, against what `launchctl print` actually printed for each standing.
/// [LAW:behavior-not-structure] What is checked is the standing each capture reads as,
/// never how the output is searched.
@Suite struct LaunchdProbeTests {
    static let development = Installation.development
    static let fixture = Installation(service: "ai.promptctl.vhid.doctor-fixture")!

    /// The loser's record with the service's name as a quoted key in a block of its own -
    /// the shape an endpoint has, in a place an endpoint is not.
    static let nameOutsideTheEndpointsBlock = LaunchdFixtures.lost.replacingOccurrences(
        of: "\tenvironment = {", with: "\tevents = {\n\t\t\"\(fixture.service)\" = {\n\t\t}\n\t}\n\n\tenvironment = {")

    @Test func aJobHoldingItsServiceReadsAsHoldingIt() throws {
        let printed = Command.Output(status: 0, stdout: LaunchdFixtures.holding, stderr: "")
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.development) == .holdingTheService)
    }

    /// Loaded, running or not, and never given the endpoint: its service name is in its
    /// environment and nowhere in an `endpoints` block, and only the second counts.
    @Test func aJobThatLostItsServiceReadsAsLoadedWithoutIt() throws {
        let printed = Command.Output(status: 0, stdout: LaunchdFixtures.lost, stderr: "")
        #expect(LaunchdFixtures.lost.contains(Self.fixture.service))
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.fixture) == .loadedWithoutTheService)
    }

    @Test func aLabelLaunchdHasNoJobUnderReadsAsNoJob() throws {
        let printed = Command.Output(status: 113, stdout: "", stderr: LaunchdFixtures.noJob)
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.fixture) == .noJob)
    }

    /// A job holding some other service is not holding this one: the marker is the whole
    /// quoted name, so a service whose name another merely begins with is not a match.
    @Test func holdingAServiceWhoseNameBeginsWithThisOneIsNotHoldingThisOne() throws {
        let prefix = Installation(service: "ai.promptctl.vhid.vhidd")!
        // The holder's record, relabelled as a job under the shorter name whose endpoint
        // is the longer one's.
        let relabelled = LaunchdFixtures.holding.replacingOccurrences(
            of: "system/ai.promptctl.vhid.vhidd.dev = {", with: "system/ai.promptctl.vhid.vhidd = {")
        let printed = Command.Output(status: 0, stdout: relabelled, stderr: "")
        #expect(try LaunchdProbe.standing(from: printed, installation: prefix) == .loadedWithoutTheService)
    }

    /// Any failure that is not launchd saying it has no such job is refused, not read as
    /// "no job": a reader told there is no job loads one over the job already there.
    /// [LAW:no-silent-failure]
    @Test func aLaunchdThatCouldNotBeReadIsRefusedRatherThanReadAsNoJob() {
        let refusals = [
            Command.Output(status: 1, stdout: "", stderr: "Operation not permitted"),
            Command.Output(status: 64, stdout: "", stderr: "Unrecognized target specifier."),
            // No job, but under some other label: not an answer about this one.
            Command.Output(status: 113, stdout: "", stderr: LaunchdFixtures.noJob),
            // The words, with a status that is not the one launchd answers them with.
            Command.Output(status: 5, stdout: "", stderr: #"Could not find service "ai.promptctl.vhid.vhidd.dev" in domain for system"#),
        ]
        for printed in refusals {
            #expect(throws: DriverUnreadable.self, "\(printed.status) \(printed.stderr)") {
                try LaunchdProbe.standing(from: printed, installation: Self.development)
            }
        }
    }

    /// The refusal names the command and says what launchd said, so the row reads it.
    @Test func theRefusalSaysWhatLaunchdSaid() {
        let printed = Command.Output(status: 1, stdout: "", stderr: "Operation not permitted")
        let refusal = #expect(throws: DriverUnreadable.self) { try LaunchdProbe.standing(from: printed, installation: Self.development) }
        #expect(refusal?.description == "could not read the machine: `launchctl print system/ai.promptctl.vhid.vhidd.dev` exited 1: Operation not permitted")
    }

    /// A record that exits 0 and is not one this build can read is refused, never read as
    /// a job without its service: a changed format must not make every healthy job look
    /// like one that lost its endpoint. [LAW:no-silent-failure]
    @Test func aRecordThisBuildCannotReadIsRefused() {
        let unreadable = [
            "",
            "system/some.other.label = {\n}",
            LaunchdFixtures.holding.replacingOccurrences(of: "\n\t}\n", with: "\n"),
            // A record whose keys are not at the depth this build reads, with no endpoints
            // block it can find: not evidence of a job without its endpoint.
            LaunchdFixtures.holding.replacingOccurrences(of: "\n\t", with: "\n    "),
        ]
        for stdout in unreadable {
            #expect(throws: LaunchdRecordUnrecognised.self, "\(stdout.prefix(40))") {
                try LaunchdProbe.standing(from: Command.Output(status: 0, stdout: stdout, stderr: ""), installation: Self.development)
            }
        }
    }

    /// The service's name as a quoted key outside the `endpoints` block is not an endpoint.
    @Test func theServicesNameOutsideTheEndpointsBlockIsNotAnEndpoint() throws {
        #expect(Self.nameOutsideTheEndpointsBlock.contains("\"\(Self.fixture.service)\" = {"))
        let printed = Command.Output(status: 0, stdout: Self.nameOutsideTheEndpointsBlock, stderr: "")
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.fixture) == .loadedWithoutTheService)
    }

    /// The installer decides whether the job it just loaded got the endpoint, and doctor
    /// decides the same about a job it finds; the two must not come to disagree about one
    /// job. So postinstall's own check - the line itself, run by bash - is asked about every
    /// capture, and has to answer as this does. [LAW:one-source-of-truth]
    /// [LAW:behavior-not-structure]
    @Test func postinstallsCheckAnswersAsThisDoesForEveryCapture() throws {
        let postinstall = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pkg/scripts/postinstall")
        let script = try String(contentsOf: postinstall, encoding: .utf8)
        // The condition of the `if` that reads the record, continuation lines joined.
        let joined = script.replacingOccurrences(of: "\\\n", with: " ")
        let checks = joined.split(separator: "\n").compactMap { $0.firstMatch(of: /^if ! (.*<<<"\$record".*); then$/)?.output.1 }
        let check = try #require(checks.first, "postinstall no longer checks the record it loaded in one if")
        let cases: [(Installation, String)] = [
            (Self.development, LaunchdFixtures.holding),
            (Self.fixture, LaunchdFixtures.lost),
            (Self.fixture, Self.nameOutsideTheEndpointsBlock),
        ]
        for (installation, record) in cases {
            let ran = try Command("/bin/bash", "-c", "service=$1; record=$2; \(check)", "check", installation.service, record).run()
            let swift = try LaunchdProbe.standing(from: Command.Output(status: 0, stdout: record, stderr: ""), installation: installation)
            #expect((ran.status == 0) == (swift == .holdingTheService), "\(installation): postinstall's grep exited \(ran.status), doctor read \(swift)")
        }
    }

    /// Against this Mac's own launchd: whatever standing it reads, it reads one, for vhid's
    /// own two installations and for a label nothing registers.
    @Test func thisMacsLaunchdIsReadWithoutRoot() throws {
        for installation in Installation.vhids {
            _ = try LaunchdProbe.standing(of: installation)
        }
        #expect(try LaunchdProbe.standing(of: Installation(service: "ai.promptctl.vhid.tests.nobody")!) == .noJob)
    }
}
