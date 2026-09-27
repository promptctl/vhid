import Foundation
import Testing
import VirtualHID
@testable import vhidd

/// The daemon's lifecycle as a policy over what the world answers: reached when it runs,
/// started when it does not, and stopped only when vhidd started it and could not
/// use it. Driven with answers of the test's own and no daemon. [LAW:behavior-not-structure]
@Suite struct DaemonProcessTests {
    /// The devices the policy hands back as it was given. Held by the test, so identity
    /// compares the object and not whatever is allocated at its address next.
    private final class Device {}

    /// What the world answered, and what was asked of it.
    private final class World {
        var connections: [Result<Device, DaemonError>]
        var bringUp: Result<DaemonProcess.Startups, DaemonError>
        var launched = 0
        var terminated: [pid_t] = []
        var limitGiven: Duration?
        var lost: (@Sendable (DaemonError) -> Void)?

        init(connections: [Result<Device, DaemonError>], bringUp: Result<DaemonProcess.Startups, DaemonError> = .success(World.up)) {
            self.connections = connections
            self.bringUp = bringUp
        }

        static let up = DaemonProcess.Startups(keyboard: Startup(answered: .milliseconds(4), ready: .seconds(1)), mouse: Startup(answered: .milliseconds(3), ready: .seconds(1)))
        static let pid: pid_t = 7

        /// Answers each connection in turn and the last one thereafter.
        var effects: DaemonProcess.Effects<Device> {
            DaemonProcess.Effects(
                connect: { whenLost in
                    let answer = self.connections.count > 1 ? self.connections.removeFirst() : self.connections[0]
                    let device = try answer.get()
                    self.lost = whenLost
                    return device
                },
                bringUp: { _, limit in
                    self.limitGiven = limit
                    return try self.bringUp.get()
                },
                launch: { self.launched += 1; return World.pid },
                terminate: {
                    self.terminated.append($0)
                    // A stopped daemon closes its connection on the way down.
                    self.lost?(.closed)
                }
            )
        }
    }

    /// What `whenLost` was told, readable from the test.
    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var losses: [(DaemonError, DaemonProcess.Origin)] = []
        @Sendable func record(_ error: DaemonError, _ origin: DaemonProcess.Origin) {
            lock.lock(); losses.append((error, origin)); lock.unlock()
        }
        var heard: [(DaemonError, DaemonProcess.Origin)] {
            lock.lock(); defer { lock.unlock() }
            return losses
        }
    }

    @Test func aDaemonFoundRunningIsUsedAndNeverStarted() throws {
        let device = Device()
        let world = World(connections: [.success(device)])
        let reached = try world.effects.reach(within: .seconds(1)) { _, _ in }
        #expect(reached.devices === device)
        #expect(reached.daemon == .alreadyRunning)
        #expect(reached.startup == World.up)
        #expect(world.launched == 0)
        #expect(world.terminated.isEmpty)
    }

    /// Nothing answers, so the daemon is started and reached once it comes up; the loss
    /// handler is told the daemon is vhidd's, so it may stop it.
    @Test func aDaemonThatDoesNotAnswerIsStartedAndReachedWhenItComesUp() throws {
        let device = Device()
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .failure(.socket("connect", ECONNREFUSED)), .success(device)])
        let told = Told()
        let reached = try world.effects.reach(within: .seconds(1), whenLost: told.record)
        #expect(reached.devices === device)
        #expect(reached.daemon == .startedHere(World.pid))
        #expect(world.launched == 1)
        #expect(world.terminated.isEmpty)
        let whenLost = try #require(world.lost)
        whenLost(.closed)
        #expect(told.heard.count == 1)
        #expect(told.heard.first?.0 == .closed)
        #expect(told.heard.first?.1 == .startedHere(World.pid))
    }

    /// Connecting and bringing up wait on different things, so the devices are given the
    /// whole limit however long the connection took of it.
    @Test func bringingUpIsGivenTheWholeLimit() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())])
        _ = try world.effects.reach(within: .milliseconds(300)) { _, _ in }
        #expect(world.limitGiven == .milliseconds(300))
    }

    /// A daemon started here that never answers is stopped before the failure leaves, and
    /// the failure is the daemon's last refusal.
    @Test func aStartedDaemonThatNeverAnswersIsStoppedAndTheRefusalThrown() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere"))])
        #expect(throws: DaemonError.noSocket(path: "nowhere")) { try world.effects.reach(within: .milliseconds(150)) { _, _ in } }
        #expect(world.launched == 1)
        #expect(world.terminated == [World.pid])
    }

    @Test func aDeviceThatWillNotComeUpStopsTheDaemonThisStarted() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())], bringUp: .failure(.silent))
        #expect(throws: DaemonError.silent) { try world.effects.reach(within: .seconds(1)) { _, _ in } }
        #expect(world.terminated == [World.pid])
    }

    /// The close of a daemon stopped for failing is not a loss: told, it would replace the
    /// failure - and the driver step it carries - as every client's refusal.
    @Test func theDaemonAFailedReachStopsIsNotReportedLost() throws {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())], bringUp: .failure(.silent))
        let told = Told()
        #expect(throws: DaemonError.silent) { try world.effects.reach(within: .seconds(1), whenLost: told.record) }
        #expect(world.terminated == [World.pid])
        #expect(told.heard.isEmpty)
    }

    @Test func aDeviceThatWillNotComeUpLeavesADaemonSomebodyElseRuns() throws {
        let world = World(connections: [.success(Device())], bringUp: .failure(.silent))
        #expect(throws: DaemonError.silent) { try world.effects.reach(within: .seconds(1)) { _, _ in } }
        #expect(world.launched == 0)
        #expect(world.terminated.isEmpty)
    }

    @Test func stoppingEndsOnlyTheDaemonThisStarted() {
        let world = World(connections: [])
        world.effects.stop(.alreadyRunning)
        #expect(world.terminated.isEmpty)
        world.effects.stop(.startedHere(World.pid))
        #expect(world.terminated == [World.pid])
    }

    private struct Stop: Error {}

    /// A daemon started for devices that will not come up is stopped before each wait, and
    /// not started again until the whole wait has passed: one spawn per backoff window.
    /// Every failure is told to readiness as the reason acts are refused.
    @Test func eachFailedAttemptStopsTheDaemonItStartedAndWaitsOutTheBackoff() {
        let world = World(connections: [.failure(.noSocket(path: "nowhere"))])
        var events: [String] = []
        let effects = world.effects
        let logged = DaemonProcess.Effects<Device>(
            connect: effects.connect,
            bringUp: effects.bringUp,
            launch: { events.append("launch"); return try effects.launch() },
            terminate: { events.append("stop"); effects.terminate($0) }
        )
        let readiness = Readiness()
        var downWhileWaiting: [Bool] = []
        #expect(throws: Stop.self) {
            try logged.keepUp(within: .milliseconds(20), backoff: Backoff(first: .seconds(2), most: .seconds(5)), readiness: readiness, serve: { _ in RecordingDevices() }, driver: { nil }, now: { .now }) { wait in
                events.append("wait \(wait)")
                downWhileWaiting.append((try? readiness.devices()) == nil)
                if events.filter({ $0.hasPrefix("wait") }).count == 3 { throw Stop() }
            }
        }
        #expect(events == ["launch", "stop", "wait 2.0 seconds", "launch", "stop", "wait 4.0 seconds", "launch", "stop", "wait 5.0 seconds"])
        #expect(downWhileWaiting == [true, true, true])
    }

    /// Devices whose connection is lost are taken down, the daemon started for them is
    /// stopped, and after a wait they are reached and served again - the process never
    /// ends over it. Devices lost as soon as they came up count as failures, so the wait
    /// grows rather than restarting the daemon every two seconds.
    @Test func lostDevicesAreStoppedAndBroughtUpAgain() {
        let world = World(connections: [.failure(.noSocket(path: "nowhere")), .success(Device())])
        let readiness = Readiness()
        var served = 0
        var downWhileWaiting: [Bool] = []
        var waits: [Duration] = []
        #expect(throws: Stop.self) {
            try world.effects.keepUp(within: .seconds(1), backoff: Backoff(first: .seconds(2), most: .seconds(60)), readiness: readiness, serve: { _ in
                served += 1
                let lose = world.lost!
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { lose(.closed) }
                return RecordingDevices()
            }, driver: { nil }, now: { .now }) { wait in
                waits.append(wait)
                downWhileWaiting.append((try? readiness.devices()) == nil)
                if waits.count == 2 { throw Stop() }
            }
        }
        #expect(served == 2)
        #expect(waits == [.seconds(2), .seconds(4)])
        #expect(downWhileWaiting == [true, true])
        #expect(world.terminated == [World.pid])
    }

    /// Once stopping has begun, every daemon started is stopped and none is started after:
    /// a launch racing SIGTERM is refused rather than orphaned.
    @Test func stoppingAllStopsWhatWasStartedAndRefusesLaterStarts() throws {
        let world = World(connections: [])
        let children = Children()
        let tracked = children.tracking(world.effects)
        let pid = try tracked.launch()
        children.stopAll(world.effects)
        #expect(world.terminated == [pid])
        #expect(throws: Children.Stopping.self) { try tracked.launch() }
        #expect(world.launched == 1)
        tracked.terminate(pid)
        #expect(world.terminated == [pid])
    }

    @Test func theBackoffDoublesToItsCap() {
        let backoff = Backoff(first: .seconds(2), most: .seconds(60))
        #expect((1...7).map(backoff.after) == [.seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(32), .seconds(60), .seconds(60)])
        #expect(backoff.after(10_000) == .seconds(60))
    }
}
