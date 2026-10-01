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
        readiness.failed(failure, driver: nil)
        #expect(refusal(readiness) == "devices not up: \(failure)")
    }

    /// The refusal for `failure` with the driver read as `state`, which is off.
    private func naming(_ state: DriverState, after failure: any Error) throws -> String {
        "devices not up: \(failure)\nThe driver extension reads \(state.rawValue):\n\(try #require(state.step))"
    }

    /// pqrs says "not activated" for several driver states alike, so the refusal carries
    /// the step for the state read on this Mac - the switch only when the switch is it.
    @Test(arguments: [DriverState.awaitingApproval, .installedInactive, .pendingReboot])
    func aFailureWhileTheDriverIsOffNamesItsStep(state: DriverState) throws {
        let readiness = Readiness()
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure, driver: state)
        #expect(refusal(readiness) == (try naming(state, after: failure)))
    }

    /// A driver that is on, or a state that could not be read, adds nothing.
    @Test(arguments: [DriverState.enabled, .running, nil])
    func aFailureWithTheDriverOnIsTheFailureAlone(state: DriverState?) {
        let readiness = Readiness()
        _ = readiness.begin()
        readiness.failed(DaemonError.closed, driver: state)
        #expect(refusal(readiness) == "devices not up: \(DaemonError.closed)")
    }

    /// The step named is the one for the driver as it was last read: a person who asked
    /// for the activation is told of the switch, and one who turned it on is told of none,
    /// with the failure standing all the while.
    @Test func aDriverReadSinceTheFailureIsTheOneWhoseStepIsNamed() throws {
        let readiness = Readiness()
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        _ = readiness.begin()
        readiness.failed(failure, driver: .installedInactive)
        readiness.driver(reads: .awaitingApproval)
        #expect(refusal(readiness) == (try naming(.awaitingApproval, after: failure)))
        readiness.driver(reads: nil)
        #expect(refusal(readiness) == "devices not up: \(failure)")
        readiness.driver(reads: .enabled)
        #expect(refusal(readiness) == "devices not up: \(failure)")
    }

    /// Devices lost to a driver that was switched off name its step once it is read.
    @Test func aDriverReadAfterALossNamesItsStep() throws {
        let readiness = Readiness()
        let attempt = readiness.begin()
        readiness.up(RecordingDevices())
        _ = readiness.lost(DaemonError.closed, in: attempt)
        readiness.driver(reads: .disabled)
        #expect(refusal(readiness) == (try naming(.disabled, after: DaemonError.closed)))
    }

    /// A reading says nothing of devices that are up, or of an attempt still under way.
    @Test func aDriverReadWhileNothingHasFailedChangesNothing() throws {
        let starting = Readiness()
        starting.driver(reads: .awaitingApproval)
        #expect(refusal(starting) == "devices not up: vhidd is still bringing them up")
        let devices = RecordingDevices()
        let serving = Readiness.serving(devices)
        serving.driver(reads: .awaitingApproval)
        #expect(try serving.devices().devices === devices)
    }

    /// An attempt whose connection was lost before it failed keeps the loss as its reason,
    /// and names the step for the driver as read at the failure.
    @Test func aFailureAfterALossKeepsTheLossAndNamesTheDriversStep() throws {
        let readiness = Readiness()
        let attempt = readiness.begin()
        _ = readiness.lost(DaemonError.closed, in: attempt)
        readiness.failed(DaemonError.silent, driver: .awaitingApproval)
        #expect(refusal(readiness) == (try naming(.awaitingApproval, after: DaemonError.closed)))
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

    /// An attempt that failed keeps its reason: its connection closing afterwards is the
    /// failure's consequence, not a new cause.
    @Test func aLateLossDoesNotReplaceWhyTheAttemptFailed() {
        let readiness = Readiness()
        let attempt = readiness.begin()
        readiness.failed(DaemonError.silent, driver: nil)
        #expect(!readiness.lost(DaemonError.closed, in: attempt))
        #expect(refusal(readiness) == "devices not up: \(DaemonError.silent)")
    }
}
