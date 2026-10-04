import DriverExtension
import Installations
import Foundation
import Helper
import Signals
import VirtualHID
import os

// A cursor reader is this executable run by the daemon, and is nothing else of it: it
// takes no --service and serves nothing. See `FrontCursor`.
if let session = cursorReaderArgument(CommandLine.arguments) { readCursor(in: session) }

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
        Logger(subsystem: Installation.unnamedSubsystem, category: "vhidd").fault(
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
private let logger = Logger(subsystem: installation.service, category: "vhidd")
func log(_ message: String) {
    logger.notice("\(message, privacy: .public)")
}

/// Said at info level: kept in memory and shown by `log show --info`, not persisted.
/// For what happens routinely - vhid's menu bar item connects every few seconds - so it
/// does not bury what `log` says.
func logRoutine(_ message: String) {
    logger.info("\(message, privacy: .public)")
}

/// Said as `log` says it, at error level, and kept as the daemon's last failure for a
/// client to read. [LAW:single-enforcer] The one way a failure of the daemon's own is
/// told, so none reaches the log without also reaching `lastFailure`.
func logFailure(_ message: String) {
    logger.error("\(message, privacy: .public)")
    lastFailure.record(message)
}

do {
    let callers = try CallerIdentity.sameSignerAsThisProcess()
    log("callers must satisfy: \(callers.text)")

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
        logFailure("\(error)")
    }

    // Listening comes first, and bringing the devices up after, on a thread of its own:
    // a client that calls while they are down is answered at once with the reason, from
    // `readiness`, rather than finding no service at all. [LAW:no-silent-failure]
    let driver: @Sendable () throws -> DriverState = { try DriverState(DriverProbe.facts(by: .within(Readiness.driverReadLimit, or: .never))) }
    let readiness = Readiness(driver: driver)
    let listener = NSXPCListener(machServiceName: installation.service)
    let delegate = Listener(readiness: readiness, callers: callers, cursor: FrontCursor.real)
    listener.delegate = delegate
    listener.resume()
    log("listening on \(installation.service)")

    let children = Children()

    // launchd stops a job with SIGTERM. Whatever is held is released first, then every
    // daemon this process started is stopped - one an attempt started a moment ago as
    // much as one serving - and a daemon somebody else runs stays theirs.
    let termination = SignalWatch(on: [SIGTERM], answeringOn: .main) { _ in
        readiness.releaseEverything(because: "asked to stop")
        children.stopAll(DaemonProcess.real)
        log("asked to stop; exiting 0")
        exit(0)
    }

    Thread.detachNewThread {
        children.tracking(DaemonProcess.real).keepUp(
            within: .seconds(10),
            backoff: Backoff(first: .seconds(2), most: .seconds(60)),
            lookingEvery: .seconds(2),
            readiness: readiness,
            serve: { reached in
                log("the keyboard is up: the driver's daemon answered in \(reached.startup.keyboard.answered), ready after \(reached.startup.keyboard.ready)")
                log("the mouse is up: the driver's daemon answered in \(reached.startup.mouse.answered), ready after \(reached.startup.mouse.ready)")
                let devices = Devices(keyboard: reached.devices.keyboard, mouse: reached.devices.mouse)
                // Whatever the daemon was holding for its last occupant - a vhidd that
                // exited while the daemon lived on, or a hand-run session - is up before
                // any client is served: the devices are handed over only after.
                // Unconditionally: the daemon's origin says who started it, not what it
                // holds. [LAW:dataflow-not-control-flow] [LAW:no-ambient-temporal-coupling]
                devices.releaseEverything(because: "starting")
                return devices
            },
            // A driver that could not be read ends no wait, so the reason it could not is
            // said here, where it would otherwise be lost. [LAW:no-silent-failure]
            driver: {
                do {
                    return try driver()
                } catch {
                    log("could not read the driver extension: \(error)")
                    return nil
                }
            },
            now: { .now },
            pause: { Thread.sleep(forTimeInterval: Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) }
        )
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
