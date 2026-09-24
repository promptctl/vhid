import Foundation
import Installations
import Keystrokes
import Testing
@testable import Helper
@testable import vhidd

/// The listener as a client meets it: the real `Listener` on an anonymous listener in this
/// process, with a requirement this process satisfies, and devices of the test's own
/// behind it. Every client is admitted; the first to act holds the devices, a second's
/// act is refused while it does, and the first going away releases everything and frees
/// them. A client that only asks who holds them takes nothing.
/// [LAW:behavior-not-structure]
@Suite struct ListenerTests {
    /// The devices served: remember what they were asked, and say when they were released.
    private final class FakeDevices: NSObject, ServedDevices, @unchecked Sendable {
        private let lock = NSLock()
        private var usages: [UInt16] = []
        private var reasons: [String] = []
        private let released = DispatchSemaphore(value: 0)

        var asked: [UInt16] {
            lock.lock(); defer { lock.unlock() }
            return usages
        }

        var releasedBecause: [String] {
            lock.lock(); defer { lock.unlock() }
            return reasons
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
            lock.lock(); usages.append(usage); lock.unlock()
            reply(nil)
        }

        func releaseAll(reply: @escaping (Error?) -> Void) { reply(nil) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { reply(nil) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }

        func releaseEverything(because reason: String) {
            lock.lock(); reasons.append(reason); lock.unlock()
            released.signal()
        }

        func awaitRelease() -> Bool {
            released.wait(timeout: .now() + .seconds(2)) == .success
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
        let delegate = Listener(devices: devices, callers: try CallerIdentity(requirement: try requirement ?? OwnProcess.requirement()))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, devices: devices)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (helper: HelperConnection, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperConnection(connection: connection, replyTimeout: .seconds(20)), connection)
    }

    /// Runs `body` on a thread of the test's own and awaits what it returned or threw:
    /// `HelperConnection` blocks until the helper answers, and a wait on the cooperative
    /// pool starves the reply it is waiting for. [LAW:no-ambient-temporal-coupling]
    private func blocking<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    /// Whether a fresh client pressing `usage` was served. A client refused as busy hears
    /// the daemon's own refusal; anything else it hears is not an answer to this, and is
    /// thrown.
    private func admitted(_ served: Served, pressing usage: Usage) async throws -> Bool {
        let keyboard = client(of: served).helper.keyboard
        do {
            try await blocking { try keyboard.down(usage) }
            return true
        } catch let refused as NSError where refused.domain == Installation.refusalDomain {
            return false
        }
    }

    @Test func theFirstClientIsAdmittedAndASecondIsRefusedWhileItHolds() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        #expect(try await admitted(served, pressing: .space) == false)
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// The first client going away releases everything, and the devices are then another
    /// client's. The release comes before the devices are let go, and the test can see
    /// only the first of the two, so the next client's admission is asked for until it
    /// comes or two seconds pass.
    @Test func aClientGoingAwayReleasesEverythingAndFreesTheDevices() async throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        first.connection.invalidate()
        #expect(served.devices.awaitRelease())
        #expect(served.devices.releasedBecause.first == "a client went away")

        let deadline = ContinuousClock.now + .seconds(2)
        var next = try await admitted(served, pressing: .space)
        while !next, ContinuousClock.now < deadline {
            next = try await admitted(served, pressing: .space)
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
    @Test func aClientThatLeavesFreesTheDevicesBeforeTheAnswer() async throws {
        let served = try serve()
        let first = client(of: served)
        let (leaver, keyboard) = (first.helper, first.helper.keyboard)
        try await blocking { try keyboard.down(.leftShift) }
        try await blocking { try leaver.leave() }
        #expect(served.devices.releasedBecause == ["a client left"])

        let second = client(of: served)
        let next = second.helper.keyboard
        try await blocking { try next.down(.space) }
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])

        await #expect(throws: (any Error).self) { try await blocking { try keyboard.down(.tab) } }
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])

        first.connection.invalidate()
        // The ending runs on the connection's own queue, so it is waited for the only way
        // the far end shows it: the next thing the holder serves comes after it.
        try await blocking { try next.down(.tab) }
        #expect(served.devices.releasedBecause == ["a client left"], "the leaver's ending released the next client's keys")
        withExtendedLifetime((served, first, second)) {}
    }

    /// A client asking who holds the devices is answered with the holder's pid, and takes
    /// nothing from it: the holder goes on acting, and a third client's act is still
    /// refused as the holder's. Before anyone acts, nobody holds them.
    @Test func statusAnswersTheHolderWithoutTakingTheDevices() async throws {
        let served = try serve()
        let asker = client(of: served).helper
        #expect(try await blocking { try asker.status() } == nil)

        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try await blocking { try keyboard.down(.leftShift) }
        #expect(try await blocking { try asker.status() } == getpid())

        try await blocking { try keyboard.down(.space) }
        #expect(served.devices.asked == [Usage.leftShift.rawValue, Usage.space.rawValue])
        #expect(try await admitted(served, pressing: .tab) == false)
        #expect(served.devices.releasedBecause.isEmpty)
        withExtendedLifetime((served, first)) {}
    }

    /// An act after `leave` is refused, and does not take the devices back: nobody holds
    /// them afterwards.
    @Test func anActAfterLeavingTakesNothingBack() async throws {
        let served = try serve()
        let first = client(of: served)
        let (leaver, keyboard) = (first.helper, first.helper.keyboard)
        try await blocking { try keyboard.down(.leftShift) }
        try await blocking { try leaver.leave() }
        let refused = await #expect(throws: NSError.self) { try await blocking { try keyboard.down(.tab) } }
        #expect(refused?.domain == Installation.refusalDomain)
        #expect(refused?.localizedDescription == "\(Seat.Ended())")
        #expect(try await blocking { try leaver.status() } == nil)
        #expect(served.devices.asked == [Usage.leftShift.rawValue])
        withExtendedLifetime((served, first)) {}
    }

    /// A caller the requirement does not admit is refused before its connection opens,
    /// and hears it as an interrupted connection: the code `vhid doctor` reads as a
    /// refused signature, which it can only because admission refuses on nothing else.
    @Test func aCallerOutsideTheRequirementHearsAnInterruptedConnection() async throws {
        let served = try serve(requiring: #"identifier "ai.promptctl.vhid.tests.nobody""#)
        let asker = client(of: served).helper
        let refused = await #expect(throws: HelperConnection.Unreachable.self) { try await blocking { try asker.status() } }
        guard case .connection(let domain, let code, _) = refused?.cause else {
            Issue.record("refused for another cause: \(String(describing: refused))")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == NSXPCConnectionInterrupted)
        withExtendedLifetime(served) {}
    }
}
