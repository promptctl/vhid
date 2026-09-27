import DriverExtension
import Foundation
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
        #expect(refusal(Readiness()) == "devices not up: vhidd is still bringing them up")
    }

    /// The refusal names what the pqrs daemon said. [LAW:no-silent-failure]
    @Test func aFailedAttemptIsTheRefusal() {
        let readiness = Readiness()
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure)
        #expect(refusal(readiness) == "devices not up: \(failure)")
    }

    /// pqrs says "not activated" for several driver states alike, so the refusal carries
    /// the step for the state read on this Mac - the switch only when the switch is it.
    @Test(arguments: [DriverState.awaitingApproval, .installedInactive, .pendingReboot])
    func aFailureWhileTheDriverIsOffNamesItsStep(state: DriverState) throws {
        let readiness = Readiness()
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(BringUpFailure(failure, driver: state))
        let step = try #require(state.step)
        #expect(refusal(readiness) == "devices not up: \(failure)\nThe driver extension reads \(state.rawValue):\n\(step)")
    }

    /// A driver that is on, or a state that could not be read, adds nothing.
    @Test(arguments: [DriverState.enabled, .running, nil])
    func aFailureWithTheDriverOnIsTheFailureAlone(state: DriverState?) {
        #expect("\(BringUpFailure(DaemonError.closed, driver: state))" == "\(DaemonError.closed)")
    }

    @Test func devicesThatComeUpAreHandedOut() throws {
        let devices = RecordingDevices()
        let readiness = Readiness.serving(devices)
        #expect(try readiness.devices().devices === devices)
        readiness.releaseEverything(because: "a client went away")
        #expect(devices.done == ["a client went away"])
    }

    @Test func aLossTakesTheDevicesDownWithItsReason() {
        let readiness = Readiness()
        let attempt = readiness.begin()
        readiness.up(RecordingDevices())
        #expect(readiness.lost(DaemonError.closed, in: attempt))
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    /// A loss that arrives before the devices are handed over keeps them down: they are
    /// devices on a connection that is gone.
    @Test func devicesWhoseConnectionWasLostBeforeTheyCameUpStayDown() {
        let readiness = Readiness()
        let attempt = readiness.begin()
        _ = readiness.lost(DaemonError.closed, in: attempt)
        readiness.up(RecordingDevices())
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    /// An earlier attempt's connection going says nothing about the devices up now.
    @Test func aLossFromAnEarlierAttemptLeavesTheDevicesUp() throws {
        let readiness = Readiness()
        let earlier = readiness.begin()
        _ = readiness.begin()
        let devices = RecordingDevices()
        readiness.up(devices)
        #expect(!readiness.lost(DaemonError.closed, in: earlier))
        #expect(try readiness.devices().devices === devices)
    }

    /// A failing attempt stops the daemon it started, so its connection closes before the
    /// failure is told; the failure, which names the driver's step, is the refusal.
    @Test func aFailureReplacesTheLossItsOwnAttemptReportedOnTheWay() {
        let readiness = Readiness()
        let attempt = readiness.begin()
        _ = readiness.lost(DaemonError.closed, in: attempt)
        readiness.failed(DaemonError.silent)
        #expect(refusal(readiness) == "devices not up: \(DaemonError.silent)")
    }

    /// An attempt that failed keeps its reason: its connection closing afterwards is the
    /// failure's consequence, not a new cause.
    @Test func aLateLossDoesNotReplaceWhyTheAttemptFailed() {
        let readiness = Readiness()
        let attempt = readiness.begin()
        readiness.failed(DaemonError.silent)
        #expect(!readiness.lost(DaemonError.closed, in: attempt))
        #expect(refusal(readiness) == "devices not up: \(DaemonError.silent)")
    }
}
