import Foundation
import Installations
import Keystrokes
import OwnThread
import Testing
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
        func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) { reply(nil) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { reply(nil) }
        func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) { reply(nil) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { reply(nil) }

        func releaseKeysHeldPastLimit() -> KeysLetGo? { nil }
        func releaseEverything(because reason: String) {
            lock.lock(); reasons.append(reason); lock.unlock()
            released.signal()
        }

        /// Blocks until the release. XPC delivers it on a queue of its own, which a loaded
        /// runner has taken seconds to run, so the bound only ends a hang: at two seconds CI
        /// missed it (run 36336822361).
        func awaitRelease() -> Bool {
            released.wait(timeout: .now() + .seconds(60)) == .success
        }
    }

    /// The real listener, and a word from each connection's far end once the ending the
    /// listener gave it has run: the ending runs on the connection's own queue, so a test
    /// that asks after what an ending did waits for this, not for its next request.
    /// [LAW:no-ambient-temporal-coupling]
    private final class Ending: NSObject, NSXPCListenerDelegate {
        let listener: Listener
        private let ended = DispatchSemaphore(value: 0)

        init(_ listener: Listener) {
            self.listener = listener
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            let accepted = self.listener.listener(listener, shouldAcceptNewConnection: connection)
            let ending = connection.invalidationHandler
            connection.invalidationHandler = { [ended] in
                ending?()
                ended.signal()
            }
            return accepted
        }

        /// Blocks until a connection's ending has run, bounded only against a hang, as the
        /// release is.
        func awaitEnding() -> Bool {
            ended.wait(timeout: .now() + .seconds(60)) == .success
        }
    }

    /// The far end as one thing a test holds: the listener holds its delegate weakly, so
    /// a delegate held by nothing is gone before the first connection.
    private struct Served {
        let listener: NSXPCListener
        let delegate: Ending
        let devices: FakeDevices
    }

    private func serve(requiring requirement: String? = nil) throws -> Served {
        let devices = FakeDevices()
        let delegate = Ending(Listener(readiness: .serving(devices), callers: try CallerIdentity(requirement: try requirement ?? OwnProcess.requirement()), screen: FixedScreen()))
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        return Served(listener: listener, delegate: delegate, devices: devices)
    }

    /// A client, with its connection alongside so the test can end it the way a client
    /// going away does.
    private func client(of served: Served) -> (helper: HelperConnection, connection: NSXPCConnection) {
        let connection = NSXPCConnection(listenerEndpoint: served.listener.endpoint)
        return (HelperConnection(connection: connection, service: "ai.promptctl.vhid.tests.far", replyTimeout: .seconds(20)), connection)
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
    /// client's. The release runs under the holder's lock with the freeing after it, and a
    /// claim takes that lock, so a client asking once the release is seen is admitted on
    /// its first ask.
    @Test func aClientGoingAwayReleasesEverythingAndFreesTheDevices() throws {
        let served = try serve()
        let first = client(of: served)
        let keyboard = first.helper.keyboard
        try keyboard.down(.leftShift)
        first.connection.invalidate()
        #expect(served.devices.awaitRelease())
        #expect(served.devices.releasedBecause == ["a client went away"])
        #expect(try admitted(served, pressing: .space), "no client was admitted after the first went away")
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
        #expect(served.delegate.awaitEnding())
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
