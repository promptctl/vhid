import DriverExtension
import Installations
import Foundation
import Helper
import Signals
import VirtualHID
import os

/// Which installation this daemon serves, from the `--service` its plist passes.
///
/// Resolved before anything else, because every name below is read off it - the service
/// listened on, the subsystem logged under - and a daemon that does not know which
/// installation it belongs to has nothing it can correctly do. A plist that does not say
/// is a broken installation rather than a passing condition, so this ends the process
/// rather than choosing for it. Exit 0 is the one code that stops launchd's KeepAlive
/// from starting it again, which is right here: starting again will not add the argument.
/// [LAW:no-silent-failure]
///
/// The refusal is filed under `Installation.unnamedSubsystem`, because which installation
/// this would have been is exactly what is not known and the set of them is open, so
/// there is no "every one" left to file it under. The arguments it prints say which plist
/// it was. That subsystem is a different string from any installation's, so the predicate
/// below is written to span both - an exact match on a service name finds a daemon that
/// started and misses every daemon that refused to, which is the one message most worth
/// finding.
///
/// "no usable" rather than "no": the flag being absent and its name being refused are one
/// answer here, because this daemon does the same thing either way and the argv it prints
/// is the evidence for whichever it was. A message that said the flag was missing would
/// send an operator whose plist does carry it looking in the wrong place.
let installation: Installation = {
    guard let installation = serviceArgument(CommandLine.arguments) else {
        Logger(subsystem: Installation.unnamedSubsystem, category: "helper").fault(
            "will not start: no usable --service <name> in \(CommandLine.arguments, privacy: .public)")
        exit(0)
    }
    return installation
}()

/// Said where `log show` will find it, under this installation's service name - which is what
/// keeps the two installations' logs apart. A daemon's only voice is its log, and a
/// daemon that fails silently at startup looks exactly like one that is working. Public
/// on purpose: nothing here is the user's data, and a redacted reason is no reason.
///
/// Both installations and the refusal above are spanned by one predicate, because all
/// three subsystems are built from the one namespace:
///
///     log show --last 10m --predicate 'subsystem BEGINSWITH "ai.promptctl.vhid"'
private let logger = Logger(subsystem: installation.service, category: "helper")
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}

/// Ends the process, saying why. The way out for every reason this process ends on
/// purpose, reached only by whoever claimed the departure, once it has stopped whatever
/// daemon of its own it knows of. [LAW:single-enforcer]
func leave(because reason: String, status: Int32) -> Never {
    log("\(reason); exiting \(status)")
    exit(status)
}

do {
    let callers = try CallerIdentity.sameSignerAsThisProcess()
    log("callers must satisfy: \(callers.text)")
    let departure = Departure()

    // Before the devices come up, and that ordering is the whole point: macOS raises
    // Keyboard Setup Assistant when the keyboard ENUMERATES, so an answer filed after
    // `reach` would be a race with the dialog it exists to prevent.
    // [LAW:no-ambient-temporal-coupling]
    //
    // A failure here does not stop vhidd. The keyboard still types; what is lost is
    // that the assistant may take the first line of it, which is worth saying loudly and
    // is not worth refusing to type over. Said here, and read back by `vhid doctor`'s
    // Keyboard Setup Assistant row, which stays unmet until the answer is on disk and
    // readable without privilege - so this is reported twice and swallowed nowhere.
    // [LAW:no-silent-failure]
    // The failure says what it cost, because only it knows: a mode that could not be set
    // leaves the answer filed and the assistant answered, and a frame written here would
    // have told an operator to expect a dialog that is never going to appear.
    // [LAW:one-source-of-truth] Typed, so this is every failure `file` has rather than
    // whichever ones were thought of here.
    do {
        let filing = try KeyboardTypeAnswer.file()
        log("this keyboard's answer \(filing) with Keyboard Setup Assistant under \(VirtualKeyboardIdentity.keyboardTypeKey)")
    } catch {
        log("\(error)")
    }

    // Listening comes first, and bringing the devices up after, on a thread of its own:
    // a client that calls while they are down is answered at once with the reason, from
    // `readiness`, rather than finding no service at all. [LAW:no-silent-failure]
    let readiness = Readiness()
    let listener = NSXPCListener(machServiceName: installation.service)
    let delegate = Listener(devices: readiness, callers: callers)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(installation.service)")

    // launchd stops a job with SIGTERM. The departure is claimed before the keys are
    // released: the release is a request, and a request that finds the daemon gone
    // reports the loss on this thread, into the handler below, which must find the
    // departure already taken. [LAW:no-ambient-temporal-coupling]
    let termination = SignalWatch(on: [SIGTERM], answeringOn: .main) { _ in
        guard departure.claim() else { return }
        readiness.releaseEverything(because: "asked to stop")
        readiness.stop(with: DaemonProcess.real)
        leave(because: "asked to stop", status: 0)
    }

    Thread.detachNewThread {
        // The connection is lost on the reading thread, and no key can be released over a
        // connection that is gone. What can be done is to stop the daemon vhidd
        // started, which takes the device and whatever it held down with it; a daemon
        // somebody else runs stays theirs. Then end: launchd restarts this job after an
        // unsuccessful exit, and the next start reaches or restarts the daemon.
        // [LAW:no-silent-failure] A loss found while already leaving is that departure's to
        // finish, with the status it chose.
        let reached = DaemonProcess.real.reachEventually(
            within: .seconds(10),
            backoff: Backoff(first: .seconds(2), most: .seconds(60)),
            pause: { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) },
            whenDown: { readiness.become(.down(.failed($0))) }
        ) { lost, daemon in
            guard departure.claim() else { return }
            DaemonProcess.real.stop(daemon)
            leave(because: "the daemon's connection was lost (\(lost)); exiting for launchd to start this again", status: 1)
        }
        log("the keyboard is up: the daemon answered in \(reached.startup.keyboard.answered), ready after \(reached.startup.keyboard.ready)")
        log("the mouse is up: the daemon answered in \(reached.startup.mouse.answered), ready after \(reached.startup.mouse.ready)")
        let devices = Devices(keyboard: reached.devices.keyboard, mouse: reached.devices.mouse)
        // Whatever the daemon was holding for its last occupant - a vhidd that exited on a
        // lost connection while the daemon lived on, or a hand-run session - is up before
        // any client is served: the devices are handed to `readiness` only after.
        // Unconditionally: the daemon's origin says who started it, not what it holds.
        // [LAW:dataflow-not-control-flow] [LAW:no-ambient-temporal-coupling]
        devices.releaseEverything(because: "starting")
        readiness.become(.up(devices, daemon: reached.daemon))
        log("serving")
    }

    // Held so the delegate and the watch outlive this scope; `resume` retains neither
    // the listener nor the sources the watch owns.
    withExtendedLifetime((delegate, termination)) { dispatchMain() }
} catch let refused as CallerIdentity.Refused {
    // The installation is wrong and starting again will not fix it. launchd cannot be
    // told EX_CONFIG: KeepAlive restarts on anything but a successful exit, so 0 is the
    // one code that says do not start this again. The reason is in the log.
    log("will not start: \(refused)")
    exit(0)
} catch {
    log("could not start: \(error)")
    exit(1)
}
