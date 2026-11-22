import Foundation
import Installations
import Keystrokes
import OwnThread
import TestClock
import Time
import Testing
@testable import Helper
@testable import vhidd

/// The listener as a client meets it: the real `Listener` on an anonymous listener in this
/// process, with a requirement this process satisfies, and devices of the test's own
/// behind it. Every client's connection is accepted; the first to send a command holds the
/// devices, a second's command is refused while it does, and the first going away releases everything and frees
/// them. A client that only asks who holds them takes nothing.
/// [LAW:behavior-not-structure]
@Suite(.ownThread) struct ListenerTests {
    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a delegate held by nothing is gone before the first connection.
    private struct Served {
        let listener: NSXPCListener
        let delegate: Listener
        let devices: RecordingDevices
        /// The one clock its clients and its seats share, never moved: no request's deadline
        /// passes here.
        let clock: ManualClock
    }

    private func serve(requiring requirement: String? = nil, releasing: Released = Released(keyboard: nil, mouse: nil)) throws -> Served {
        let (devices, clock) = (RecordingDevices(releasing: releasing), ManualClock())
        let delegate = Listener(readiness: .serving(devices), callers: try CallerIdentity(requirement: try requirement ?? OwnProcess.requirement()), screen: FixedScreen(), clock: Clock(clock))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, devices: devices, clock: clock)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (helper: HelperConnection, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperConnection(connection: connection, service: "ai.promptctl.vhid.tests.far", clock: Clock(served.clock), replyTimeout: .seconds(5)), connection)
    }

    /// Whether a fresh client pressing `usage` was served. A client refused as busy hears
    /// the daemon's own refusal; anything else it hears is not an answer to this, and is
    /// thrown.
    private func isServed(_ served: Served, pressing usage: Usage) throws -> Bool {
        do {
            try client(of: served).helper.keyboard.down(usage)
            return true
        } catch let refused as HelperConnection.Refused where refused.domain == Installation.refusalDomain {
            #expect(refused.code == Installation.seatRefusedCode)
            return false
        }
    }

    @Test func theFirstClientIsAdmittedAndASecondIsRefusedWhileItHolds() throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try keyboard.down(.leftShift)
        #expect(served.devices.done == ["down 225"])
        #expect(try isServed(served, pressing: .space) == false)
        #expect(served.devices.done == ["down 225"])
        withExtendedLifetime((served, first)) {}
    }

    /// The first client going away releases everything, and the devices are then another
    /// client's. The release and the free are one step under the devices' lock, so once
    /// the release is in the log the next client is served on its first try.
    @Test func aClientGoingAwayReleasesEverythingAndFreesTheDevices() throws {
        let served = try serve()
        let first = client(of: served)
        try first.helper.keyboard.down(.leftShift)
        first.connection.invalidate()
        try #require(served.devices.await(["down 225", "a client went away"]))
        #expect(try isServed(served, pressing: .space))
        #expect(served.devices.done == ["down 225", "a client went away", "down 44"])
        withExtendedLifetime((served, first)) {}
    }

    /// The race `leave` exists to close. A client that leaves is answered only once the
    /// devices are free, so the next client is served on the first try - no retry loop,
    /// unlike the test above. The leaver's connection is still open: it is refused if it
    /// calls again, and when it does end, its ending releases nothing, because the keys
    /// down by then are the next client's. [LAW:no-ambient-temporal-coupling]
    @Test func aClientThatLeavesFreesTheDevicesBeforeTheAnswer() throws {
        let served = try serve()
        let first = client(of: served)
        let (leaver, keyboard) = (first.helper, first.helper.keyboard)
        try keyboard.down(.leftShift)
        try leaver.leave()
        #expect(served.devices.done == ["down 225", "a client left"])

        let second = client(of: served)
        let next = second.helper.keyboard
        try next.down(.space)
        #expect(served.devices.done == ["down 225", "a client left", "down 44"])

        #expect(throws: (any Error).self) { try keyboard.down(.tab) }
        #expect(served.devices.done == ["down 225", "a client left", "down 44"])

        first.connection.invalidate()
        // The ending runs on the connection's own queue, so it is waited for the only way
        // the far end shows it: the next thing the holder serves comes after it.
        try next.down(.tab)
        #expect(served.devices.done == ["down 225", "a client left", "down 44", "down 43"], "the leaver's ending released the next client's keys")
        withExtendedLifetime((served, first, second)) {}
    }

    /// A client asking who holds the devices is answered with the holder's pid, and takes
    /// nothing from it: the holder goes on sending, and a third client's command is still
    /// refused as the holder's. Before anyone sends one, nobody holds them.
    @Test func holdingAnswersTheHolderWithoutTakingTheDevices() throws {
        let served = try serve()
        let asker = client(of: served).helper
        #expect(try asker.holding(by: .within(.seconds(5), on: asker.clock)) == .nobody)

        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try keyboard.down(.leftShift)
        #expect(try asker.holding(by: .within(.seconds(5), on: asker.clock)) == .client(pid: getpid()))

        try keyboard.down(.space)
        #expect(try isServed(served, pressing: .tab) == false)
        #expect(served.devices.done == ["down 225", "down 44"])
        withExtendedLifetime((served, first)) {}
    }

    /// A command after `leave` is refused, and does not acquire the devices back: nobody holds
    /// them afterwards.
    @Test func aCommandAfterLeavingAcquiresNothing() throws {
        let served = try serve()
        let first = client(of: served)
        let (leaver, keyboard) = (first.helper, first.helper.keyboard)
        try keyboard.down(.leftShift)
        try leaver.leave()
        let refused = #expect(throws: HelperConnection.Refused.self) { try keyboard.down(.tab) }
        #expect(refused?.domain == Installation.refusalDomain)
        #expect(refused?.reason == "\(Seat.Ended())")
        #expect(try leaver.holding(by: .within(.seconds(5), on: leaver.clock)) == .nobody)
        #expect(served.devices.done == ["down 225", "a client left"])
        withExtendedLifetime((served, first)) {}
    }

    /// A client whose keys vhidd could not release hears it when it leaves, in vhidd's
    /// words, and the next to ask reads the devices as stuck: not free, though nobody
    /// holds them.
    @Test func aClientWhoseReleaseFailedHearsItAndTheDevicesReadStuck() throws {
        let failed = Released(keyboard: "the driver did not answer", mouse: nil)
        let served = try serve(releasing: failed)
        let first = client(of: served)
        try first.helper.keyboard.down(.leftShift)
        let refused = #expect(throws: HelperConnection.Refused.self) { try first.helper.leave() }
        #expect(refused?.reason == "\(Stuck(released: failed))")
        let asker = client(of: served).helper
        #expect(try asker.holding(by: .within(.seconds(5), on: asker.clock)) == .stuck)
        withExtendedLifetime((served, first)) {}
    }

    /// A caller the requirement does not admit is refused before its connection opens,
    /// and hears it as an interrupted connection: the code `vhid doctor` reads as a
    /// refused signature, which it can only because admission refuses on nothing else.
    @Test func aCallerOutsideTheRequirementHearsAnInterruptedConnection() throws {
        let served = try serve(requiring: #"identifier "ai.promptctl.vhid.tests.nobody""#)
        let asker = client(of: served).helper
        let refused = #expect(throws: HelperConnection.Unreachable.self) { try asker.holding(by: .within(.seconds(5), on: asker.clock)) }
        guard case .connection(let domain, let code, _) = refused?.cause else {
            Issue.record("refused for another cause: \(String(describing: refused))")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == NSXPCConnectionInterrupted)
        withExtendedLifetime(served) {}
    }
}
