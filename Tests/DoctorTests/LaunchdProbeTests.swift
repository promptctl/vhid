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

    @Test func aJobHoldingItsServiceReadsAsHoldingIt() throws {
        let printed = Command.Output(status: 0, stdout: LaunchdFixtures.holding, stderr: "")
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.development) == .holdingTheService)
    }

    /// Loaded, running or not, and never given the endpoint: its service name is in its
    /// environment and nowhere in an `endpoints` block, and only the second counts.
    @Test func aJobThatLostItsServiceReadsAsAnotherHoldingIt() throws {
        let printed = Command.Output(status: 0, stdout: LaunchdFixtures.lost, stderr: "")
        #expect(LaunchdFixtures.lost.contains(Self.fixture.service))
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.fixture) == .anotherJobHoldsTheService)
    }

    @Test func aLabelLaunchdHasNoJobUnderReadsAsNoJob() throws {
        let printed = Command.Output(status: 113, stdout: "", stderr: LaunchdFixtures.noJob)
        #expect(try LaunchdProbe.standing(from: printed, installation: Self.fixture) == .noJob)
    }

    /// A job holding some other service is not holding this one: the marker is the whole
    /// quoted name, so a service whose name another merely begins with is not a match.
    @Test func holdingAServiceWhoseNameBeginsWithThisOneIsNotHoldingThisOne() throws {
        let prefix = Installation(service: "ai.promptctl.vhid.vhidd")!
        let printed = Command.Output(status: 0, stdout: LaunchdFixtures.holding, stderr: "")
        #expect(try LaunchdProbe.standing(from: printed, installation: prefix) == .anotherJobHoldsTheService)
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
        ]
        for printed in refusals {
            #expect(throws: LaunchdUnreadable.self, "\(printed.stderr)") {
                try LaunchdProbe.standing(from: printed, installation: Self.development)
            }
        }
    }

    /// The refusal names the command and says what launchd said, so the row reads it.
    @Test func theRefusalSaysWhatLaunchdSaid() {
        let refusal = LaunchdUnreadable(label: "x.y", status: 1, complaint: "Operation not permitted")
        #expect(refusal.description == "`launchctl print system/x.y` exited 1: Operation not permitted")
    }

    /// The installer decides whether the job it just loaded got the endpoint by grepping
    /// for the same marker this reads, and the two must not come to disagree about one job.
    /// [LAW:one-source-of-truth]
    @Test func postinstallLooksForTheSameEndpointMarker() throws {
        let postinstall = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("pkg/scripts/postinstall")
        let script = try String(contentsOf: postinstall, encoding: .utf8)
        let marker = LaunchdProbe.endpointMarker(Installation(service: "$service")!)
        #expect(script.contains(#"grep -q "\#(marker.replacingOccurrences(of: "\"", with: "\\\""))" <<<"$record""#))
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
