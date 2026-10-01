import DriverExtension
import Foundation
import OwnThread
import Testing
import VirtualHID
@testable import vhidd

/// The daemon's lifecycle as a policy over what the world answers: reached when it runs,
/// started when it does not, and stopped only when vhidd started it and could not
/// use it. Driven with answers of the test's own and no daemon. [LAW:behavior-not-structure]
@Suite(.ownThread) struct DaemonProcessTests {
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
    /// failure as every client's refusal.
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
        let readiness = Readiness(driver: { .running })
        var downWhileWaiting: [Bool] = []
        let clock = HandClock()
        #expect(throws: Stop.self) {
            try logged.keepUp(within: .milliseconds(20), backoff: Backoff(first: .seconds(2), most: .seconds(5)), lookingEvery: .seconds(5), readiness: readiness, serve: { _ in RecordingDevices() }, driver: { nil }, now: { clock.now }) { wait in
                clock.advance(wait)
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
        let readiness = Readiness(driver: { .running })
        var served = 0
        var downWhileWaiting: [Bool] = []
        var waits: [Duration] = []
        let clock = HandClock()
        #expect(throws: Stop.self) {
            try world.effects.keepUp(within: .seconds(1), backoff: Backoff(first: .seconds(2), most: .seconds(60)), lookingEvery: .seconds(60), readiness: readiness, serve: { _ in
                served += 1
                let lose = world.lost!
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { lose(.closed) }
                return RecordingDevices()
            }, driver: { nil }, now: { clock.now }) { wait in
                clock.advance(wait)
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

    /// Attempts that fail in a world whose driver reads as `driver` says, on a clock that
    /// only the pauses move: what was launched, stopped and waited, in order, up to the
    /// `pauses`th pause.
    private func paced(_ pauses: Int, backoff: Backoff, driver: @escaping (_ launched: Int, _ waited: Duration) -> DriverState?) -> [String] {
        let world = World(connections: [.failure(.noSocket(path: "nowhere"))])
        var events: [String] = []
        let clock = HandClock()
        let began = clock.now
        let effects = world.effects
        let logged = DaemonProcess.Effects<Device>(
            connect: effects.connect,
            bringUp: effects.bringUp,
            launch: { events.append("launch"); return try effects.launch() },
            terminate: effects.terminate
        )
        #expect(throws: Stop.self) {
            try logged.keepUp(within: .milliseconds(20), backoff: backoff, lookingEvery: .seconds(2), readiness: Readiness(driver: { .running }), serve: { _ in RecordingDevices() }, driver: { driver(world.launched, clock.now - began) }, now: { clock.now }) { wait in
                clock.advance(wait)
                events.append("wait \(wait)")
                if events.count(where: { $0.hasPrefix("wait") }) == pauses { throw Stop() }
            }
        }
        return events
    }

    /// The person approving the driver is waiting on this loop: the wait it is in ends at
    /// the look that reads the driver on, not at the end of the minute.
    @Test func aDriverTurnedOnDuringAWaitEndsIt() {
        let events = paced(3, backoff: Backoff(first: .seconds(60), most: .seconds(60))) { _, waited in
            waited < .seconds(4) ? .awaitingApproval : .enabled
        }
        #expect(events == ["launch", "wait 2.0 seconds", "wait 2.0 seconds", "launch", "wait 60.0 seconds"])
    }

    /// The failures before were of a driver that was off, so the attempt made once it is
    /// on is followed by the shortest wait again: 3 s, then 6 s ended 4 s in, then 3 s
    /// where the next in the row would have been 12. That last one is taken whole: the
    /// driver is on, so there is nothing in it to look for.
    @Test func theAttemptAfterTheDriverTurnsOnIsFollowedByTheShortestWait() {
        let events = paced(5, backoff: Backoff(first: .seconds(3), most: .seconds(60))) { _, waited in
            waited < .seconds(7) ? .disabled : .running
        }
        #expect(events == ["launch", "wait 2.0 seconds", "wait 1.0 seconds", "launch", "wait 2.0 seconds", "wait 2.0 seconds", "launch", "wait 3.0 seconds"])
    }

    /// A driver turned on while an attempt was already failing was last read off in the
    /// wait before that attempt, so the first look of the wait after it ends it.
    @Test func aDriverTurnedOnDuringTheFailingAttemptEndsTheWaitAtItsFirstLook() {
        let events = paced(4, backoff: Backoff(first: .seconds(4), most: .seconds(4))) { launched, _ in
            launched == 1 ? .awaitingApproval : .enabled
        }
        #expect(events == ["launch", "wait 2.0 seconds", "wait 2.0 seconds", "launch", "wait 2.0 seconds", "launch", "wait 4.0 seconds"])
    }

    /// A wait whose attempt ended with the driver on, or with a driver that could not be
    /// read, is not waiting for the driver: it is taken whole and reads nothing.
    @Test(arguments: [DriverState.enabled, .running, nil])
    func aWaitWhoseAttemptEndedWithTheDriverOnOrUnreadRunsWhole(ended: DriverState?) {
        var read = 0
        let events = paced(2, backoff: Backoff(first: .seconds(6), most: .seconds(6))) { _, _ in
            read += 1
            return ended
        }
        #expect(events == ["launch", "wait 6.0 seconds", "launch", "wait 6.0 seconds"])
        #expect(read == 2)
    }

    /// One reading that could not be taken does not end the looking: the driver was last
    /// read off, and the look after it still finds it on.
    @Test func anUnreadDriverLeavesTheWaitLooking() {
        let readings: [DriverState?] = [.awaitingApproval, nil, .enabled]
        var read = 0
        let events = paced(3, backoff: Backoff(first: .seconds(60), most: .seconds(60))) { _, _ in
            defer { read += 1 }
            return readings[min(read, readings.count - 1)]
        }
        #expect(events == ["launch", "wait 2.0 seconds", "wait 2.0 seconds", "launch", "wait 60.0 seconds"])
    }

    /// Devices that come up and are lost as they are handed over, in a world whose
    /// daemon is running and whose driver reads as `driver` says: the waits taken, up to
    /// the `pauses`th. `before` is run ahead of each wait.
    ///
    /// Lost from inside `serve` and not a moment later from another thread: a test that
    /// holds its thread until a dispatch queue calls back waits on the runner having a
    /// thread to spare, and three of them on a three-core runner wait forever.
    private func lostEachTime(_ pauses: Int, world: World, backoff: Backoff, driver: @escaping (_ served: Int, _ waited: Duration) -> DriverState?, before: @escaping (World) -> Void = { _ in }) -> [Duration] {
        var served = 0
        var waits: [Duration] = []
        let clock = HandClock()
        #expect(throws: Stop.self) {
            try world.effects.keepUp(within: .seconds(1), backoff: backoff, lookingEvery: .seconds(2), readiness: Readiness(driver: { .running }), serve: { _ in
                served += 1
                world.lost!(.closed)
                return RecordingDevices()
            }, driver: { driver(served, waits.reduce(.zero, +)) }, now: { clock.now }) { wait in
                clock.advance(wait)
                before(world)
                waits.append(wait)
                if waits.count == pauses { throw Stop() }
            }
        }
        return waits
    }

    /// A driver approved while an attempt was coming up was read off before it. The
    /// devices that came up prove it on, so their loss later is not the driver turning
    /// on: the waits after it are taken whole and go on growing.
    @Test func aDriverReadOffBeforeTheDevicesCameUpEndsNoWaitAfterTheyAreLost() {
        let world = World(connections: [.success(Device())], bringUp: .failure(.silent))
        let waits = lostEachTime(3, world: world, backoff: Backoff(first: .seconds(2), most: .seconds(60)), driver: { served, _ in
            served == 0 ? .awaitingApproval : .running
        }, before: { $0.bringUp = .success(World.up) })
        #expect(waits == [.seconds(2), .seconds(4), .seconds(8)])
    }

    /// Devices lost to a driver that was switched off are waited for as any are: the
    /// driver read off at the loss is what the wait is for, and turning it on ends it.
    @Test func aDriverTurnedOnAfterTheDevicesWereLostToItEndsTheWait() {
        let world = World(connections: [.success(Device())])
        let waits = lostEachTime(3, world: world, backoff: Backoff(first: .seconds(6), most: .seconds(60))) { _, waited in
            waited < .seconds(4) ? .disabled : .enabled
        }
        #expect(waits == [.seconds(2), .seconds(2), .seconds(6)])
    }

    /// A driver that goes from one off state to another has not turned on.
    @Test func aDriverThatChangesWithoutTurningOnEndsNoWait() {
        let events = paced(4, backoff: Backoff(first: .seconds(6), most: .seconds(6))) { _, waited in
            waited == .zero ? .installedInactive : .awaitingApproval
        }
        #expect(events == ["launch", "wait 2.0 seconds", "wait 2.0 seconds", "wait 2.0 seconds", "launch", "wait 2.0 seconds"])
    }

    @Test func aWaitIsTakenALookAtATimeAndEndsWithWhatALookFinds() throws {
        let clock = HandClock()
        var pauses: [Duration] = []
        let pause: (Duration) -> Void = { clock.advance($0); pauses.append($0) }
        let whole = waitOut(.seconds(5), lookingEvery: .seconds(2), now: { clock.now }, pause: pause, for: { String?.none })
        #expect(whole == nil)
        #expect(pauses == [.seconds(2), .seconds(2), .seconds(1)])

        pauses = []
        let ended = try #require(waitOut(.seconds(60), lookingEvery: .seconds(2), now: { clock.now }, pause: pause, for: { pauses.count == 3 ? "found" : nil }))
        #expect(ended.found == "found")
        #expect(ended.after == .seconds(6))
        #expect(pauses == [.seconds(2), .seconds(2), .seconds(2)])
    }

    /// A look takes time, and that time is the wait's: with a look that takes as long as
    /// the pause before it, three of its five pauses fit, and the wait is over one look past
    /// its length at the latest. What a look finds is found that far in, its own time counted.
    @Test func theTimeALookTakesIsPartOfTheWait() throws {
        let clock = HandClock()
        var pauses: [Duration] = []
        let pause: (Duration) -> Void = { clock.advance($0); pauses.append($0) }
        let began = clock.now
        let whole = waitOut(.seconds(10), lookingEvery: .seconds(2), now: { clock.now }, pause: pause, for: { clock.advance(.seconds(2)); return String?.none })
        #expect(whole == nil)
        #expect(pauses == [.seconds(2), .seconds(2), .seconds(2)])
        #expect(clock.now - began == .seconds(12))

        pauses = []
        let ended = try #require(waitOut(.seconds(60), lookingEvery: .seconds(2), now: { clock.now }, pause: pause, for: { clock.advance(.seconds(2)); return pauses.count == 2 ? "found" : nil }))
        #expect(ended.after == .seconds(8))
    }

    /// A driver read that runs to vhidd's two-second limit at every look - a stuck pkgutil,
    /// systemextensionsctl or ioreg - does not stretch the wait the log gave: the next
    /// attempt starts within that wait and one reading of it.
    @Test func aDriverThatIsSlowToReadDoesNotStretchTheWait() {
        let world = World(connections: [.failure(.noSocket(path: "nowhere"))])
        let clock = HandClock()
        let (wait, reading) = (Duration.seconds(10), Duration.seconds(2))
        var launches: [ContinuousClock.Instant] = []
        var waitBegan: ContinuousClock.Instant?
        let effects = world.effects
        let logged = DaemonProcess.Effects<Device>(
            connect: effects.connect,
            bringUp: effects.bringUp,
            launch: { launches.append(clock.now); return try effects.launch() },
            terminate: effects.terminate
        )
        #expect(throws: Stop.self) {
            try logged.keepUp(within: .milliseconds(20), backoff: Backoff(first: wait, most: wait), lookingEvery: .seconds(2), readiness: Readiness(driver: { .running }), serve: { _ in RecordingDevices() }, driver: { clock.advance(reading); return .awaitingApproval }, now: { clock.now }) { pause in
                if launches.count == 2 { throw Stop() }
                waitBegan = waitBegan ?? clock.now
                clock.advance(pause)
            }
        }
        #expect(launches.count == 2)
        #expect(launches[1] - waitBegan! <= wait + reading)
        #expect(launches[1] - waitBegan! >= wait)
    }

    /// What the log says of a wait cut short: both states, as they were read.
    @Test func aDriverTurnedOnSaysWhatItReadBeforeAndSince() throws {
        let on = try #require(TurnedOn(from: .awaitingApproval, to: .enabled))
        #expect("\(on)" == "the driver extension reads enabled, from awaiting-approval")
        #expect(TurnedOn(from: .awaitingApproval, to: nil) == nil)
        #expect(TurnedOn(from: .awaitingApproval, to: .disabled) == nil)
        #expect(TurnedOn(from: .enabled, to: .running) == nil)
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
