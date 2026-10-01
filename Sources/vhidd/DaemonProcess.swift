import DriverExtension
import Foundation
import Synchronization
import VirtualHID

/// Karabiner-VirtualHIDDevice-Daemon, the root process that holds the driver open, and
/// the one thing that has to be running before anything can type.
///
/// The public package installs it and registers nothing to run it: there is no launchd
/// job for it on a Mac that has never had Karabiner-Elements, so a driver that is
/// enabled and running per `scripts/virtual-hid-driver state` still types nothing. This
/// vhidd owns that lifecycle alongside its own. [LAW:no-ambient-temporal-coupling] It
/// reaches for the daemon first and starts it only when nothing answers, so a daemon
/// somebody else is running - by hand, or by Karabiner-Elements' own job - is used as it
/// stands rather than doubled.
enum DaemonProcess {
    static let executable = "/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"

    /// Devices that are up, where the daemon behind them came from - found running, or
    /// started here, in which case it is vhidd's to stop - and what bringing them up
    /// cost. [LAW:types-are-the-program] Two origins, two duties, and no pid to wonder about.
    struct Reached<Device> {
        let devices: Device
        let daemon: Origin
        let startup: Startups
    }

    /// What each device cost to bring up. Two and not a sum, because the daemon discovers
    /// each device's readiness on its own one-second tick and the two numbers are the two
    /// things worth logging.
    struct Startups: Equatable {
        let keyboard: Startup
        let mouse: Startup
    }

    /// The two devices of one connection: pqrs's daemon keeps a keyboard and a pointing
    /// device per client, and takes both when the client goes.
    struct HID {
        let keyboard: VirtualKeyboard
        let mouse: VirtualPointing
    }

    enum Origin: Equatable {
        case alreadyRunning
        case startedHere(pid_t)
    }

    /// What reaching the daemon does to the world, taken as values: connect to it, bring
    /// the devices up on the connection, launch the daemon, terminate it. The policy over
    /// them - reach first, launch only when nothing answers, stop only what was launched
    /// here - is then a function of what they answer, and a test drives it with answers of
    /// its own and no daemon at all. [LAW:effects-at-boundaries]
    struct Effects<Device> {
        /// The devices on a connection to a daemon that is running, or `DaemonError` when
        /// none answers. `whenLost` is told when that connection ends underneath them.
        let connect: (_ whenLost: @escaping @Sendable (DaemonError) -> Void) throws -> Device
        /// The devices brought up on their connection, each within the limit.
        let bringUp: (Device, Duration) throws -> Startups
        /// The daemon started as this process's child.
        let launch: () throws -> pid_t
        let terminate: (pid_t) -> Void
    }

    /// The effects done for real. The daemon outlives any one connection on purpose, and
    /// only `stop` ends it.
    static var real: Effects<HID> {
        Effects(
            connect: { whenLost in
                let daemon = try DaemonConnection(whenLost: whenLost)
                return HID(keyboard: VirtualKeyboard(daemon: daemon), mouse: VirtualPointing(daemon: daemon))
            },
            bringUp: { Startups(keyboard: try $0.keyboard.start(within: $1), mouse: try $0.mouse.start(within: $1)) },
            launch: { try spawn(executable, [], stdio: [:]) },
            terminate: end
        )
    }

    /// Stops a daemon this process started and reaps it, so it is gone - not a zombie, and
    /// not a dying daemon the next attempt connects to as somebody else's - when this
    /// returns. SIGTERM first, and SIGKILL for one still there after two seconds.
    private static func end(_ pid: pid_t) {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if waitpid(pid, nil, WNOHANG) != 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
    }
}

extension DaemonProcess.Effects {
    /// Brings the devices up: connects to the daemon, starting it when it is not there to
    /// connect to, then starts each device on the connection. Each wait is given the whole
    /// of `limit`: a socket that answers and a driver that reports a device ready are
    /// different waits, so none is handed what another left.
    /// [LAW:no-ambient-temporal-coupling]
    ///
    /// [LAW:single-enforcer] The one unit that can leave a daemon running that vhidd
    /// started, so it is the one that makes sure it does not: a daemon started here that
    /// never answers, or one whose devices will not start, is stopped before the failure
    /// leaves. The caller holds no pid to orphan. `whenLost` is told the daemon's origin
    /// with the loss, for the same reason: what it may stop is this unit's knowledge.
    ///
    /// A daemon stopped here closes its connection on the way down, and that close is
    /// this failure's consequence, not a loss: told, it would stand in for the failure as
    /// the reason every client is refused with. So `whenLost` hears nothing from the
    /// moment the stop is decided. [LAW:no-silent-failure]
    func reach(within limit: Duration, whenLost: @escaping @Sendable (DaemonError, DaemonProcess.Origin) -> Void) throws -> DaemonProcess.Reached<Device> {
        let stopping = Mutex(false)
        let (devices, origin) = try connection(by: .now + limit) { error, origin in
            if !stopping.withLock({ $0 }) { whenLost(error, origin) }
        }
        do {
            return DaemonProcess.Reached(devices: devices, daemon: origin, startup: try bringUp(devices, limit))
        } catch {
            stopping.withLock { $0 = true }
            stop(origin)
            throw error
        }
    }

    /// A connection to the daemon and where the daemon came from.
    private func connection(by deadline: ContinuousClock.Instant, whenLost: @escaping @Sendable (DaemonError, DaemonProcess.Origin) -> Void) throws -> (Device, DaemonProcess.Origin) {
        do {
            return (try connect { whenLost($0, .alreadyRunning) }, .alreadyRunning)
        } catch let unreachable as DaemonError {
            log("no driver's daemon to reach (\(unreachable)); starting it")
        }
        let pid = try launch()
        log("started the driver's daemon as pid \(pid)")
        let origin = DaemonProcess.Origin.startedHere(pid)
        while true {
            do {
                return (try connect { whenLost($0, origin) }, origin)
            } catch let unreachable as DaemonError {
                guard ContinuousClock.now < deadline else { stop(origin); throw unreachable }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    /// Ends the daemon vhidd started. A daemon somebody else started is theirs to end.
    func stop(_ origin: DaemonProcess.Origin) {
        switch origin {
        case .alreadyRunning:
            log("leaving the driver's daemon running: vhidd did not start it")
        case .startedHere(let pid):
            terminate(pid)
            log("stopped the driver's daemon as pid \(pid), which vhidd started")
        }
    }
}

/// How long to wait before each attempt after a failed one: `first`, doubled per failure,
/// never more than `most`. A pure schedule, so the pace at which the daemon is started and
/// stopped is a value a test reads rather than a clock it waits on.
/// [LAW:effects-at-boundaries]
struct Backoff: Equatable {
    let first: Duration
    let most: Duration

    /// The wait after the `failures`th failure in a row, counting from one.
    func after(_ failures: Int) -> Duration {
        // Doubled at most 20 times, which is past any cap worth having: `<<` on Int does not
        // trap but gives 0 from a shift of 64, and a zero wait would start and stop the
        // daemon as fast as it can.
        min(first * (1 << min(max(failures - 1, 0), 20)), most)
    }
}

/// Waits out `whole` a `look` at a time, and ends at the first look that finds something:
/// what it found and how much of the wait had passed, or nil when the whole wait did.
///
/// [LAW:no-ambient-temporal-coupling] A wait is for something, and `find` says what: the
/// time is the bound on it rather than the thing waited for, so what the wait was for
/// ends it the moment it is there to find.
func waitOut<Found>(
    _ whole: Duration,
    lookingEvery look: Duration,
    pause: (Duration) throws -> Void,
    for find: () -> Found?
) rethrows -> (found: Found, after: Duration)? {
    var waited = Duration.zero
    while waited < whole {
        let next = min(look, whole - waited)
        try pause(next)
        waited += next
        if let found = find() { return (found, waited) }
    }
    return nil
}

/// A driver extension that read as not on and reads as on since: the one change between
/// attempts that a person makes and the next attempt is waiting for.
///
/// Both ends are states that were read. A state that could not be read is neither, so a
/// probe that fails and recovers turns nothing on. [LAW:parse-dont-validate]
struct TurnedOn: Equatable, CustomStringConvertible {
    let from: DriverState
    let to: DriverState

    init?(from: DriverState, to: DriverState?) {
        guard !from.isOn, let to, to.isOn else { return nil }
        self.from = from
        self.to = to
    }

    var description: String { "the driver extension reads \(to.rawValue), from \(from.rawValue)" }
}

/// The daemons this process started and has not yet stopped.
///
/// [LAW:one-source-of-truth] Recorded by the launch itself, not reported by whoever
/// launched, so SIGTERM mid-attempt - with the pid still inside `reach` - stops it all the
/// same, and a pid stopped once is never signalled again, whatever has since taken it.
final class Children: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    /// Set by `stopAll`, after which nothing is launched: a launch racing SIGTERM would
    /// otherwise start a daemon after the stop had already been made.
    private var stopping = false

    struct Stopping: Error, CustomStringConvertible {
        var description: String { "vhidd is stopping, so it starts no driver's daemon" }
    }

    /// `effects` with every launch recorded and every termination limited to what is.
    func tracking<Device>(_ effects: DaemonProcess.Effects<Device>) -> DaemonProcess.Effects<Device> {
        DaemonProcess.Effects(
            connect: effects.connect,
            bringUp: effects.bringUp,
            launch: {
                self.lock.lock(); defer { self.lock.unlock() }
                guard !self.stopping else { throw Stopping() }
                let pid = try effects.launch()
                self.pids.insert(pid)
                return pid
            },
            terminate: { pid in
                self.lock.lock(); defer { self.lock.unlock() }
                guard self.pids.remove(pid) != nil else { return }
                effects.terminate(pid)
            }
        )
    }

    /// Stops every daemon still recorded, and every launch after it refuses.
    func stopAll(_ effects: DaemonProcess.Effects<some Any>) {
        lock.lock(); defer { lock.unlock() }
        stopping = true
        pids.forEach(effects.terminate)
        pids.removeAll()
    }
}

extension DaemonProcess.Effects {
    /// Keeps the devices up for as long as this process runs: reaches them, hands them to
    /// `readiness` through `serve`, and when an attempt fails or its devices are lost, says
    /// why through `readiness`, waits out `backoff`, and reaches them again.
    ///
    /// [LAW:dataflow-not-control-flow] A failed start and a lost connection are one path:
    /// both take the devices down with a reason and retry, so neither ends the process and
    /// neither is the spawn loop launchd's restarts used to make. `reach` stops any daemon
    /// it started before it throws, and a loss stops the one behind it, so every start is
    /// separated from the one before by a wait: the whole of it, or no less than a `look`
    /// of one cut short. [LAW:no-ambient-temporal-coupling]
    ///
    /// Failures count until the devices stay up for `backoff.most`, so a daemon that comes
    /// up and dies at once is started ever less often, and one that served for a while is
    /// reached again after the shortest wait.
    ///
    /// A wait ends early for one thing: the driver extension turning on. A person who has
    /// just approved it is waiting on this loop, and the failures counted against a driver
    /// that was off say nothing of one that is on, so the count starts again with it. The
    /// driver is read where each attempt ends, at its failure or at the loss of what it
    /// brought up, and a reading of it not on is what the waits from then are for: the
    /// driver is read every `look` of them until it reads on or the devices come up. Any
    /// other wait is taken whole and reads nothing.
    ///
    /// Returns only by `pause` throwing, which the daemon's never does.
    func keepUp(
        within limit: Duration,
        backoff: Backoff,
        lookingEvery look: Duration,
        readiness: Readiness,
        serve: (DaemonProcess.Reached<Device>) -> any ServedDevices,
        driver: () -> DriverState?,
        now: () -> ContinuousClock.Instant,
        pause: (Duration) throws -> Void
    ) rethrows -> Never {
        var failures = 0
        // The driver as it was last read not on, since the devices were last up: what a
        // wait is for. Kept across attempts, so a driver turned on while an attempt was
        // already failing is still one turned on since, and one reading that could not
        // be taken leaves the wait looking. [LAW:no-ambient-temporal-coupling]
        var off: DriverState?
        while true {
            let attempt = readiness.begin()
            let ended: DriverState?
            do {
                let reached = try reach(within: limit) { lost, _ in _ = readiness.lost(lost, in: attempt) }
                readiness.up(serve(reached))
                log("serving")
                // Devices that came up did so on a driver that is on, whatever it read
                // before them: a loss of these is not that driver turning on.
                off = nil
                let since = now()
                let why = readiness.whileUp()
                // Lost, so whatever the daemon held for vhidd went with the connection; a
                // daemon started here is stopped so the next attempt starts it afresh.
                stop(reached.daemon)
                failures = now() - since >= backoff.most ? 1 : failures + 1
                logFailure("the devices went down (\(why)); bringing them up again in \(backoff.after(failures))")
                ended = driver()
            } catch {
                failures += 1
                ended = driver()
                readiness.failed(BringUpFailure(error, driver: ended))
                logFailure("could not bring the devices up (\(error)); trying again in \(backoff.after(failures))")
            }
            if let ended, !ended.isOn { off = ended }
            let wait = backoff.after(failures)
            // [LAW:dataflow-not-control-flow] Every wait is waited out the same way: one
            // with nothing to look for is a single look as long as itself, finding nothing.
            if let on = try waitOut(wait, lookingEvery: off == nil ? wait : look, pause: pause, for: { off.flatMap { TurnedOn(from: $0, to: driver()) } }) {
                log("\(on.found), \(on.after) into a wait of \(wait); bringing the devices up now")
                failures = 0
                off = nil
            }
        }
    }
}

/// A failed bring-up, and the driver extension's step when the driver is not on.
///
/// pqrs's status says only "not activated" for an extension awaiting approval, one whose
/// activation never landed and one half removed alike, so the state is read from this Mac
/// at the failure and its step is the one named: a person who skipped the installer's
/// last page learns it from their first refused call. Read at each failure, since the
/// state is what the person changes between attempts. Nothing is added when the state
/// could not be read or the driver is on. [LAW:one-source-of-truth] with `vhid doctor`.
struct BringUpFailure: Error, CustomStringConvertible {
    let error: any Error
    let driver: DriverState?

    init(_ error: any Error, driver: DriverState?) {
        self.error = error
        self.driver = driver
    }

    var description: String {
        guard let driver, let step = driver.step else { return "\(error)" }
        return "\(error)\nThe driver extension reads \(driver.rawValue):\n\(step)"
    }
}
