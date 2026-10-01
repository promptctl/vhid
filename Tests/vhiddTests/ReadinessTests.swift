import DriverExtension
import Foundation
import OwnThread
import Testing
import VirtualHID
@testable import vhidd

/// Devices that are not up are refused with the reason; devices that come up are handed
/// out until the attempt that brought them up loses its connection.
/// [LAW:behavior-not-structure]
@Suite struct ReadinessTests {
    private func refusal(_ readiness: Readiness) -> String? {
        do { _ = try readiness.devices(); return nil } catch { return "\(error)" }
    }

    @Test func beforeTheFirstAttemptEndsTheDevicesAreRefusedAsStarting() {
        #expect(refusal(Readiness(driver: { .running })) == "devices not up: vhidd is still bringing them up")
    }

    /// The refusal names what the pqrs daemon said. [LAW:no-silent-failure]
    @Test func aFailedAttemptIsTheRefusal() {
        let readiness = Readiness(driver: { .running })
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure)
        #expect(refusal(readiness) == "devices not up: \(failure)")
    }

    /// The refusal for `why` with the driver read as `state`, which is off.
    private func naming(_ state: DriverState, after why: Readiness.Down) throws -> String {
        "\(why)\nThe driver extension reads \(state.rawValue):\n\(try #require(state.step))"
    }

    /// pqrs says "not activated" for several driver states alike, so the refusal carries
    /// the step for the state read on this Mac - the switch only when the switch is it.
    @Test(arguments: [DriverState.awaitingApproval, .installedInactive, .pendingReboot])
    func aFailureWhileTheDriverIsOffNamesItsStep(state: DriverState) throws {
        let readiness = Readiness(driver: { state })
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure)
        #expect(refusal(readiness) == (try naming(state, after: .failed(failure))))
    }

    /// A driver that is on has no step to name.
    @Test(arguments: [DriverState.enabled, .running])
    func aFailureWithTheDriverOnIsTheFailureAlone(state: DriverState) {
        let readiness = Readiness(driver: { state })
        _ = readiness.begin()
        readiness.failed(DaemonError.closed)
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    private struct Unreadable: Error, CustomStringConvertible {
        var description: String { "systemextensionsctl list exited 1" }
    }

    /// A driver that could not be read is said so to the client refused, with why: no
    /// step named is not left to mean the driver is on.
    @Test func aDriverThatCouldNotBeReadIsSaidInTheRefusal() {
        let readiness = Readiness(driver: { throw Unreadable() })
        _ = readiness.begin()
        readiness.failed(DaemonError.closed)
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)\nThe driver extension could not be read: systemextensionsctl list exited 1")
    }

    /// The step named is the one for the driver as it reads when the act is refused, with
    /// nothing told in between: a person who asked for the activation is told of the
    /// switch on their next call, and one who turned it on is told of no step, with the
    /// failure standing all the while.
    @Test func eachRefusalNamesTheStepTheDriverIsAtNow() throws {
        var driver = DriverState.installedInactive
        let readiness = Readiness(driver: { driver })
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure)
        #expect(refusal(readiness) == (try naming(.installedInactive, after: .failed(failure))))
        driver = .awaitingApproval
        #expect(refusal(readiness) == (try naming(.awaitingApproval, after: .failed(failure))))
        driver = .enabled
        #expect(refusal(readiness) == "devices not up: \(failure)")
    }

    /// A person who skipped the installer's last page is told their step by a call made
    /// while the first attempt is still under way.
    @Test func aRefusalBeforeTheFirstAttemptEndsNamesTheDriversStep() throws {
        #expect(refusal(Readiness(driver: { .awaitingApproval })) == (try naming(.awaitingApproval, after: .starting)))
    }

    /// Devices lost to a driver that was switched off are refused with its step.
    @Test func aRefusalAfterALossNamesTheDriversStep() throws {
        let readiness = Readiness(driver: { .disabled })
        let attempt = readiness.begin()
        readiness.up(RecordingDevices())
        _ = readiness.lost(DaemonError.closed, in: attempt)
        #expect(refusal(readiness) == (try naming(.disabled, after: .failed(DaemonError.closed))))
    }

    /// The driver is read to refuse an act and for nothing else: what is done only on
    /// devices that are up - the sweep for keys held too long, a release - reads none,
    /// and nor does an act that is served.
    @Test func theDriverIsReadOnlyToRefuse() throws {
        var read = 0
        let readiness = Readiness(driver: { read += 1; return .awaitingApproval })
        #expect(readiness.up == nil)
        readiness.releaseEverything(because: "a client went away")
        #expect(read == 0)
        #expect(refusal(readiness) != nil)
        #expect(read == 1)
        _ = readiness.begin()
        let devices = RecordingDevices()
        readiness.up(devices)
        #expect(try readiness.devices().devices === devices)
        #expect(readiness.up?.devices === devices)
        #expect(read == 1)
    }

    @Test func devicesThatComeUpAreHandedOut() throws {
        let devices = RecordingDevices()
        let readiness = Readiness.serving(devices)
        #expect(try readiness.devices().devices === devices)
        readiness.releaseEverything(because: "a client went away")
        #expect(devices.done == ["a client went away"])
    }

    @Test func aLossTakesTheDevicesDownWithItsReason() {
        let readiness = Readiness(driver: { .running })
        let attempt = readiness.begin()
        readiness.up(RecordingDevices())
        #expect(readiness.lost(DaemonError.closed, in: attempt))
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    /// A loss that arrives before the devices are handed over keeps them down: they are
    /// devices on a connection that is gone.
    @Test func devicesWhoseConnectionWasLostBeforeTheyCameUpStayDown() {
        let readiness = Readiness(driver: { .running })
        let attempt = readiness.begin()
        _ = readiness.lost(DaemonError.closed, in: attempt)
        readiness.up(RecordingDevices())
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    /// An earlier attempt's connection going says nothing about the devices up now.
    @Test func aLossFromAnEarlierAttemptLeavesTheDevicesUp() throws {
        let readiness = Readiness(driver: { .running })
        let earlier = readiness.begin()
        _ = readiness.begin()
        let devices = RecordingDevices()
        readiness.up(devices)
        #expect(!readiness.lost(DaemonError.closed, in: earlier))
        #expect(try readiness.devices().devices === devices)
    }

    /// An attempt that failed keeps its reason: its connection closing afterwards is the
    /// failure's consequence, not a new cause.
    @Test func aLateLossDoesNotReplaceWhyTheAttemptFailed() {
        let readiness = Readiness(driver: { .running })
        let attempt = readiness.begin()
        readiness.failed(DaemonError.silent)
        #expect(!readiness.lost(DaemonError.closed, in: attempt))
        #expect(refusal(readiness) == "devices not up: \(DaemonError.silent)")
    }
}

/// A client refused while a tool that reads the driver never exits is still answered, at
/// the tool's limit: with why the devices are not up, and that the driver could not be
/// read, naming the tool and the limit. A suite of its own because it waits the limit out.
@Suite(.ownThread) struct StuckDriverReadTests {
    @Test(.timeLimit(.minutes(1))) func aDriverReadThatNeverReturnsStillAnswersTheRefusedClient() {
        let readiness = Readiness(driver: {
            _ = try Command("/bin/sleep", "600").run(within: .milliseconds(200))
            return .running
        })
        _ = readiness.begin()
        readiness.failed(DaemonError.closed)
        let began = ContinuousClock.now
        let refused = #expect(throws: Readiness.Refused.self) { try readiness.devices() }
        #expect(ContinuousClock.now - began < .seconds(5))
        #expect(refused?.description == "devices not up: \(DaemonError.closed)\nThe driver extension could not be read: `sleep 600` had not ended after 0.2 seconds and was stopped")
    }
}
