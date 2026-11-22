import Foundation
import Installations
import Keystrokes
import OwnThread
import Pointing
import Testing
import Timeline
import Waiting
@testable import Helper
@testable import vhidd

/// The listener as a client meets it: the real `Listener` on an anonymous listener in this
/// process, with a requirement this process satisfies, and devices of the test's own
/// behind it. Every client is admitted; the first to act holds the devices, a second's
/// act is refused while it does, and the first going away releases everything and frees
/// them. A client that only asks who holds them takes nothing.
/// [LAW:behavior-not-structure]
@Suite(.ownThread) struct ListenerTests {
    /// The devices served: remember what they were asked, and say when they were released.
    private final class FakeDevices: ServedDevices, @unchecked Sendable {
        private let lock = NSLock()
        private var usages: [UInt16] = []
        private let reasons = Latch<[String]>([])

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        var releasedBecause: [String] { reasons.current }

        func down(_ usage: Usage, by deadline: Deadline) throws {
            lock.lock(); usages.append(usage.rawValue); lock.unlock()
        }

        func releaseAll(by deadline: Deadline) throws {}
        func hold(_ keys: HeldKeys, by deadline: Deadline) throws {}
        func buttonDown(_ button: Button, by deadline: Deadline) throws {}
        func releaseButtons(by deadline: Deadline) throws {}
        func holdButtons(_ buttons: Set<Button>, by deadline: Deadline) throws {}
        func move(_ delta: Move, by deadline: Deadline) throws {}
        func scroll(_ delta: Scroll, by deadline: Deadline) throws {}
        func release(by deadline: Deadline) throws {}

        func releaseKeysHeldPastLimit(heldBy holder: () -> pid_t?) -> KeysLetGo? { nil }
        func releaseEverything(because reason: String) -> Release {
            reasons.update { $0.append(reason) }
            return .released
        }

        /// The reason of the first release, once there is one.
        func awaitRelease() throws -> String {
            try reasons.wait(for: "a release") { $0.first }
        }
    }

    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a delegate held by nothing is gone before the first connection.
    private struct Served {
        let listener: NSXPCListener
        let delegate: Listener
        let devices: FakeDevices
    }

    private func serve(requiring requirement: String? = nil) throws -> Served {
        let devices = FakeDevices()
        let delegate = Listener(readiness: .serving(devices), callers: try CallerIdentity(requirement: try requirement ?? OwnProcess.requirement()), screen: FixedScreen(), timeline: .suspending)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, devices: devices)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (helper: HelperConnection, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperConnection(connection: connection, service: "ai.promptctl.vhid.tests.far", replyTimeout: hangGuard), connection)
    }

    /// Whether a fresh client pressing `usage` was served. A client refused as busy hears
    /// the daemon's own refusal; anything else it hears is not an answer to this, and is
    /// thrown.
    private func admitted(_ served: Served, pressing usage: Usage) throws -> Bool {
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
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        #expect(try admitted(served, pressing: .space) == false)
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// The first client going away releases everything, and the devices are then another
    /// client's. The release comes before the devices are let go, and the test can see
    /// only the first of the two: the far end says the devices are free only by admitting
    /// the next client, so the next client asks until it is admitted, each ask a round
    /// trip of its own, within the guard. Admitted at last at any pace, so the asking
    /// decides nothing but when.
    @Test(.hangGuarded) func aClientGoingAwayReleasesEverythingAndFreesTheDevices() throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try keyboard.down(.leftShift)
        first.connection.invalidate()
        #expect(try served.devices.awaitRelease() == "a client went away")

        let guardEnds = ContinuousClock.now + hangGuard
        var next = try admitted(served, pressing: .space)
        while !next, ContinuousClock.now < guardEnds {
            next = try admitted(served, pressing: .space)
        }
        #expect(next, "no client was admitted after the first went away")
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])
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
        #expect(served.devices.releasedBecause == ["a client left"])

        let second = client(of: served)
        let next = second.helper.keyboard
        try next.down(.space)
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])

        #expect(throws: (any Error).self) { try keyboard.down(.tab) }
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])

        first.connection.invalidate()
        // The ending runs on the connection's own queue, so it is waited for the only way
        // the far end shows it: the next thing the holder serves comes after it.
        try next.down(.tab)
        #expect(served.devices.releasedBecause == ["a client left"], "the leaver's ending released the next client's keys")
        withExtendedLifetime((served, first, second)) {}
    }

    /// A client asking who holds the devices is answered with the holder's pid, and takes
    /// nothing from it: the holder goes on acting, and a third client's act is still
    /// refused as the holder's. Before anyone acts, nobody holds them.
    @Test func statusAnswersTheHolderWithoutTakingTheDevices() throws {
        let served = try serve()
        let asker = client(of: served).helper
        #expect(try asker.status() == nil)

        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try keyboard.down(.leftShift)
        #expect(try asker.status() == getpid())

        try keyboard.down(.space)
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])
        #expect(try admitted(served, pressing: .tab) == false)
        #expect(served.devices.releasedBecause.isEmpty)
        withExtendedLifetime((served, first)) {}
    }

    /// An act after `leave` is refused, and does not take the devices back: nobody holds
    /// them afterwards.
    @Test func anActAfterLeavingTakesNothingBack() throws {
        let served = try serve()
        let first = client(of: served)
        let (leaver, keyboard) = (first.helper, first.helper.keyboard)
        try keyboard.down(.leftShift)
        try leaver.leave()
        let refused = #expect(throws: HelperConnection.Refused.self) { try keyboard.down(.tab) }
        #expect(refused?.domain == Installation.refusalDomain)
        #expect(refused?.reason == "\(Seat.Ended())")
        #expect(try leaver.status() == nil)
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// A caller the requirement does not admit is refused before its connection opens,
    /// and hears it as an interrupted connection: the code `vhid doctor` reads as a
    /// refused signature, which it can only because admission refuses on nothing else.
    @Test func aCallerOutsideTheRequirementHearsAnInterruptedConnection() throws {
        let served = try serve(requiring: #"identifier "ai.promptctl.vhid.tests.nobody""#)
        let asker = client(of: served).helper
        let refused = #expect(throws: HelperConnection.Unreachable.self) { try asker.status() }
        guard case .connection(let domain, let code, _) = refused?.cause else {
            Issue.record("refused for another cause: \(String(describing: refused))")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == NSXPCConnectionInterrupted)
        withExtendedLifetime(served) {}
    }
}
