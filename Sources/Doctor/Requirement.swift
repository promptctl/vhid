import DriverExtension
import Foundation
import Installations

/// One thing that must hold before a vhid verb can reach the devices, as this Mac actually
/// stands.
///
/// [LAW:one-type-per-behavior] Six very different facts - a driver extension's
/// registration, a launchd job's hold on a Mach service, a daemon's answer, a signature it
/// admits, which process holds the devices, a setup assistant's cached answer - are one
/// type with six instances, because what a reader does with them does not differ: read
/// what is there, and do the step when there is one.
///
/// Ported in shape from low-talker's onboarding, whose reader of these same facts did not
/// come across when vhid was extracted from it. Keyed on `Installation` rather than on
/// low-talker's two flavors, and with no menu to feed: `vhid doctor` and its MCP tool are
/// the readers.
public struct Requirement: Sendable, Hashable {
    /// Which of doctor's rows this is.
    public let row: Row
    /// What must hold, in the words every surface uses.
    public var name: String { row.rawValue }
    /// What was read off this Mac. Shown whether or not there is a step, because a
    /// requirement that says only "not ready" is one nobody can act on or report.
    public let reads: String
    /// What is left for a person to do, and nil when nothing is. Genuinely absent rather
    /// than an empty string: "nothing to do" and "a step nobody wrote" are different
    /// facts, and a reader that cannot tell them apart prints the second as the first.
    public let step: String?

    /// What a button can do toward the step, when macOS offers anything to press: nil for
    /// every step a person does in a Terminal or in System Settings by hand.
    public let ask: Ask?

    /// Where System Settings holds the switch the step names, when it does: only states a
    /// person turns on there have one, so a surface never offers a pane with nothing in it.
    public let settingsPane: URL?

    /// The earlier row whose being unmet is why this one could not be read, when that is
    /// the whole of its step: nothing can be done here until that row is. A surface that
    /// walks the rows one at a time passes over these, since the row they wait on is the
    /// step. [LAW:types-are-the-program]
    public let waitsOn: Row?

    public var met: Bool { step == nil }

    init(row: Row, reads: String, step: String?, ask: Ask? = nil, settingsPane: URL? = nil) {
        self.row = row
        self.reads = reads
        self.step = step
        self.ask = ask
        self.settingsPane = settingsPane
        waitsOn = nil
    }

    /// A row that waits on another says so in the words every waiting row uses, derived
    /// from the row it waits on, so the step and `waitsOn` cannot disagree.
    init(row: Row, reads: String, waitsOn earlier: Row, why: String? = nil) {
        self.row = row
        self.reads = reads
        ask = nil
        settingsPane = nil
        step = [why, "Read once the \(earlier.rawValue) row above is met."].compactMap { $0 }.joined(separator: "\n")
        waitsOn = earlier
    }

    /// The requests a surface can make on a person's behalf, each one making macOS ask them.
    public enum Ask: Sendable, Hashable {
        /// Run the driver package's Manager `activate` as the person, so macOS asks them to
        /// approve the driver extension.
        case activateDriver
    }
}

public extension Requirement {
    /// What each row is called, in the order doctor prints them.
    ///
    /// The order is the order the facts depend on each other: no daemon answers without a
    /// launchd job to hold its service, no signature is judged by a daemon that did not
    /// answer, and nobody can say who holds the devices without an answer to say it in.
    /// A row whose fact waits on an earlier one names that row in its step, so a reader
    /// working top to bottom is never sent past the thing actually in the way.
    ///
    /// One home for the names, because the factories, the rows a failed reading becomes,
    /// and the tests all say them. [LAW:one-source-of-truth]
    enum Row: String, Sendable, Hashable, CaseIterable {
        case driverExtension = "Driver extension"
        case launchdJob = "launchd job"
        case daemon = "Daemon"
        case signature = "Signature"
        case devices = "Devices"
        case keyboardSetupAssistant = "Keyboard Setup Assistant"
    }

    /// A requirement whose fact could not be read.
    ///
    /// The row stays in the list rather than being dropped: every requirement is shown
    /// every time, and one that could not be read is never silently absent from a list a
    /// reader takes as complete. It carries a step, so it is never `met`.
    /// [LAW:no-silent-failure]
    ///
    /// The error is what was read, so it goes where readings go, folded onto the row's one
    /// line; the step is an instruction like every other step. An error in the step's place
    /// read as a step nobody wrote - and one whose description was empty printed as a row
    /// with no step at all while counting as unmet.
    static func unreadable(_ row: Row, _ error: any Error) -> Requirement {
        let said = "\(error)".split(whereSeparator: \.isNewline).joined(separator: "; ")
        return Requirement(
            row: row,
            reads: said.isEmpty ? "could not be read, and the failure gave no reason" : "could not be read: \(said)",
            step: """
                Until this is read, nothing says it holds. Run doctor again; a
                reason that stays is the thing to fix.
                """)
    }
}

public extension Requirement {
    /// The step as the lines it was written in, and no lines at all when there is nothing
    /// to do. Split once, so every surface that indents a step works from one shape.
    /// [LAW:one-source-of-truth]
    var stepLines: [String] { step.map { $0.components(separatedBy: "\n") } ?? [] }
}

extension Requirement: CustomStringConvertible {
    public var description: String {
        (["\(name): \(reads)"] + stepLines.map { "  \($0)" }).joined(separator: "\n")
    }
}

/// Where this Mac stands against everything a vhid verb needs, as one list.
///
/// Computed rather than printed, so a test reads it as a value and the CLI and the MCP
/// tool say the same words without either spelling them a second time.
/// [LAW:effects-at-boundaries]
public struct Readiness: Sendable, Hashable, CustomStringConvertible {
    public let requirements: [Requirement]

    /// The whole list, from the readings, and the one way a caller gets one.
    ///
    /// [LAW:types-are-the-program] Every row, once, in `Row` order, built here rather than
    /// assembled by each surface: a step that says "the Daemon row above" is true
    /// only of a list in which that row is above, and a list a caller put together by hand
    /// could drop a row, repeat one, or be empty and read as ready. A reading that could
    /// not be taken arrives as the failure it was and becomes that row's `unreadable`, so
    /// a failed probe never removes its row. [LAW:no-silent-failure]
    ///
    /// The status round trip is a reading and not a `Result`: every way it ends is already
    /// one of `DaemonReading`'s cases, the failures included.
    public init(
        installation: Installation,
        driver: Result<DriverState, any Error>,
        job: Result<JobStanding, any Error>,
        daemon: DaemonReading,
        keyboardSetupAssistantAnswered: Result<Bool, any Error>
    ) {
        func row<Reading>(_ row: Requirement.Row, _ reading: Result<Reading, any Error>, _ make: (Reading) -> Requirement) -> Requirement {
            switch reading {
            case .success(let read): make(read)
            case .failure(let error): .unreadable(row, error)
            }
        }
        self.init([
            row(.driverExtension, driver) { .driverExtension($0) },
            row(.launchdJob, job) { .launchdJob($0, daemon: daemon, installation: installation) },
            .daemon(daemon, installation: installation),
            .signature(daemon, installation: installation),
            .devices(daemon),
            row(.keyboardSetupAssistant, keyboardSetupAssistantAnswered) {
                .keyboardSetupAssistant(answered: $0, daemon: daemon, installation: installation)
            },
        ])
    }

    /// Any list at all, for a test to read how one is printed and judged. Not public: a
    /// surface builds the whole list from readings, above.
    init(_ requirements: [Requirement]) { self.requirements = requirements }

    /// Nothing is left for anyone to do.
    public var ready: Bool { requirements.allSatisfy(\.met) }

    /// Every requirement, every time, in a fixed order - the met ones included. A list
    /// that showed only what was wrong would leave a reader unable to tell "checked and
    /// fine" from "never checked". [LAW:dataflow-not-control-flow]
    public var description: String { requirements.map(\.description).joined(separator: "\n") }
}

// MARK: - shared wording


/// The daemon's log, which is where it says anything it has to say: it is a daemon, and
/// its only voice is `os_log` under its own service name.
///
/// Both subsystems a daemon can speak under, not only its own: one started without a
/// usable `--service` refuses under `Installation.unnamedSubsystem` and exits 0, which
/// launchd does not restart - so its endpoint stays held and nothing answers, the silent
/// reading exactly. An exact match on the service finds every daemon that started and
/// misses the one that refused to, and an empty answer reads as a clean log.
/// [LAW:no-silent-failure]
private func daemonLog(_ installation: Installation, last window: String) -> String {
    let predicate = [installation.service, Installation.unnamedSubsystem]
        .map { "subsystem == \(predicateString($0))" }
        .joined(separator: " OR ")
    return "/usr/bin/log show --predicate \(shellQuoted(predicate)) --last \(window)"
}

/// A name as a string literal in an `NSPredicate`, which `log show` parses: a quote or a
/// backslash in it would otherwise end the literal early or escape what follows.
func predicateString(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

/// A word as the shell reads back exactly, for a name pasted into a command a person runs.
///
/// A service name is anything `Installation` admits, which is everything but whitespace:
/// a quote in one would end the quoting it was pasted into, and the command a person
/// copies would be a different command. Left bare when nothing in it is special to the
/// shell, which is every name vhid itself registers, so the steps stay readable.
/// [LAW:parse-dont-validate]
func shellQuoted(_ word: String) -> String {
    let plain = word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-/:@%+=,".contains($0)) }
    return plain && !word.isEmpty ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// A name as `scripts/launchd-plist` writes it into a plist, which escapes what XML
/// reserves. A search of the plists has to look for the name as it is on disk, or a name
/// holding one of these is never found. [LAW:one-source-of-truth] with that script's `xml`.
func xmlEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

/// The one search for which plist names a service, as a fixed string rather than a
/// pattern: every `.` in a reverse-DNS name is a regex wildcard.
private func plistsNaming(_ installation: Installation) -> String {
    "grep -lF -- \(shellQuoted(">\(xmlEscaped(installation.service))<")) /Library/LaunchDaemons/*.plist"
}

// MARK: - the driver extension

public extension Requirement {
    /// The driver extension the virtual devices are published through.
    ///
    /// Every word `DriverState` can take gets its own step, because they are not degrees
    /// of one problem: a Mac with no package needs an install, a Mac holding a
    /// registration nobody approved needs a click, and a Mac mid-removal needs a restart.
    static func driverExtension(_ state: DriverState) -> Requirement {
        // Only an inactive registration is one a button can ask for: the Manager's
        // `activate` files the request macOS then shows. Only a registration awaiting
        // approval or switched off is a switch in System Settings. Every other state is an
        // install, a removal, or a restart.
        Requirement(row: .driverExtension, reads: state.rawValue, step: state.step,
                    ask: state == .installedInactive ? .activateDriver : nil,
                    settingsPane: [.awaitingApproval, .disabled].contains(state)
                        ? URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") : nil)
    }
}

// MARK: - the launchd job

public extension Requirement {
    /// The launchd job that holds this installation's Mach service.
    ///
    /// [LAW:one-source-of-truth] The installation itself, not names lifted off it: the
    /// label, the service and the plist path are three readings of one value, and passing
    /// them separately would let a step name one installation's plist and another's
    /// service.
    ///
    /// The daemon's reading as well, because launchd asked about this label cannot see a
    /// job under some other label that names this service - and that job is exactly what
    /// the no-job step's bootstrap would lose to, exit 0 and no endpoint. Whether anyone
    /// holds the service is what the round trip says, so "no job here" and "something
    /// holds the service" together are read as the stray job they are, not as a job to
    /// load. [LAW:no-silent-failure]
    static func launchdJob(_ standing: JobStanding, daemon: DaemonReading, installation: Installation) -> Requirement {
        let strayHolder = standing == .noJob && daemon.someoneHoldsTheService
        return Requirement(row: .launchdJob,
            reads: strayHolder ? "no job, and something else holds the service" : reads(for: standing),
            step: strayHolder ? strayHolderStep(installation) : step(for: standing, installation: installation))
    }

    private static func reads(for standing: JobStanding) -> String {
        switch standing {
        case .holdingTheService: "loaded, holding the service"
        case .loadedWithoutTheService: "loaded, without the service's endpoint"
        case .noJob: "no job"
        }
    }

    /// Where vhid's plist for this installation lives, whoever wrote it: the pkg for the
    /// installed copy, a person with `scripts/launchd-plist` for a copy built from a tree.
    private static func plist(_ installation: Installation) -> String {
        "/Library/LaunchDaemons/\(installation.launchdLabel).plist"
    }

    private static func step(for standing: JobStanding, installation: Installation) -> String? {
        let (label, service, plist) = (shellQuoted(installation.launchdLabel), shellQuoted(installation.service), shellQuoted(plist(installation)))
        switch standing {
        case .holdingTheService:
            return nil
        // Both ways a job reaches this label, named rather than chosen between: which one
        // this installation came by is not something the reading says, and the set of
        // installations is open, so no case here may pick the route by which one it is.
        // [LAW:dataflow-not-control-flow]
        case .noJob:
            return """
                launchd holds no job under \(installation.launchdLabel), so nothing
                answers \(installation.service). The installed copy's job is loaded
                by vhid's pkg: install it again. A copy built from a tree is loaded
                by hand, from the root of that tree after `make`:
                    scripts/launchd-plist \(service) "$PWD/.build/debug/vhidd" \\
                        | sudo tee \(plist) >/dev/null
                    sudo launchctl enable system/\(label)
                    sudo launchctl bootstrap system \(plist)
                """
        // Only a job can hold a system-domain Mach service - launchd hands the endpoint to
        // the job whose plist names it, and a process launchd did not start cannot check
        // one in - so both causes are found by one search of the plists: another label's
        // among them is the holder, and this label's missing from them is a plist that
        // never asked. A search of processes would list this job's own daemon, running
        // without the endpoint, and invite the reader to kill the wrong one.
        case .loadedWithoutTheService:
            return """
                A job is loaded under \(installation.launchdLabel), and launchd holds
                no endpoint for \(installation.service) for it, so its daemon answers
                nothing however healthy it looks. Either a job under another label
                holds the service, or this job's plist never named it. Every plist
                that names the service - another label's is the holder, and this
                label's missing means its plist is the one to fix:
                    \(plistsNaming(installation))
                """
        }
    }

    /// No job under this label, and a daemon on the service all the same: a job under
    /// another label holds it, and loading this installation's own would lose to it.
    private static func strayHolderStep(_ installation: Installation) -> String {
        """
        launchd holds no job under \(installation.launchdLabel), yet something
        holds \(installation.service): a job under another label names it,
        and a job loaded under this one would never get the endpoint. Every
        plist that names the service, before loading anything:
            \(plistsNaming(installation))
        """
    }
}

// MARK: - the daemon's answer

public extension Requirement {
    /// Whether a daemon is listening on the service with its devices up.
    ///
    /// A refusal of the signature is an answer here: the daemon was listening to refuse
    /// it, and the one thing known wrong is the signature - the next row's to say. Whether
    /// its devices are up it did not say, since it refuses a caller before it is asked.
    static func daemon(_ reading: DaemonReading, installation: Installation) -> Requirement {
        Requirement(row: .daemon, reads: daemonReads(reading), step: daemonStep(reading, installation: installation))
    }

    private static func daemonReads(_ reading: DaemonReading) -> String {
        switch reading {
        case .answered: "listening, both devices up"
        case .refusedThisVhid: "listening"
        case .devicesDown: "listening, devices not up"
        case .unreachable: "nothing holds the service"
        case .silent: "the service is held, and nothing answered"
        case .failed: "the call failed"
        }
    }

    private static func daemonStep(_ reading: DaemonReading, installation: Installation) -> String? {
        switch reading {
        case .answered, .refusedThisVhid:
            nil
        case .devicesDown(let reason):
            """
            The daemon is up and cannot bring the devices up: \(reason)
            An unmet \(Row.driverExtension.rawValue) row above is the usual reason. It
            keeps trying, and serves once they come up. Its log says:
                \(daemonLog(installation, last: "10m"))
            """
        case .unreachable(let reason):
            """
            Nothing holds \(installation.service) (\(reason)).
            When the \(Row.launchdJob.rawValue) row above is unmet, that is why. When it
            is met, the two readings disagree - launchd holds a loaded job's
            endpoint whether or not its daemon runs - so the job changed
            between them: run doctor again.
            """
        case .silent(let reason):
            """
            launchd holds \(installation.service) and the daemon did not answer
            (\(reason)). Its log says:
                \(daemonLog(installation, last: "10m"))
            """
        case .failed(let reason):
            """
            The status call failed in a way this build cannot name: \(reason)
            The daemon's log for the same moment:
                \(daemonLog(installation, last: "10m"))
            """
        }
    }
}

// MARK: - the signature

public extension Requirement {
    /// Whether the daemon admits this binary.
    ///
    /// The daemon admits a caller signed with the certificate it carries itself and refuses
    /// everything else, and the refusal reaches a client as NSCocoaErrorDomain 4097 - which
    /// reads like broken XPC and costs an afternoon before anyone suspects the signature.
    /// This row is that afternoon, spent once.
    static func signature(_ reading: DaemonReading, installation: Installation) -> Requirement {
        let reads = signatureReads(reading)
        return switch reading {
        case .answered, .devicesDown: Requirement(row: .signature, reads: reads, step: nil)
        case .refusedThisVhid: Requirement(row: .signature, reads: reads, step: refusedStep(installation))
        // [LAW:no-silent-failure] Unmet rather than met or dropped: nothing was read, so
        // nothing may be claimed, and the step names the row in the way.
        case .unreachable, .silent, .failed: Requirement(row: .signature, reads: reads, waitsOn: .daemon)
        }
    }

    private static func signatureReads(_ reading: DaemonReading) -> String {
        switch reading {
        case .answered, .devicesDown: "admitted"
        case .refusedThisVhid: "refused: vhidd ended this vhid's connection"
        case .unreachable, .silent, .failed: "not asked"
        }
    }

    private static func refusedStep(_ installation: Installation) -> String {
        """
            The daemon on \(installation.service) admits only callers signed with
            its own certificate. A tree built with bare `swift build` is signed
            ad hoc; sign it from the root of that tree:
                make sign
            The installed vhid and a build from a tree carry different
            certificates, so each reaches its own daemon: --service says which.
            A daemon older than this vhid refuses it the same way; when this
            vhid is signed, restart the daemon so it runs the build beside it:
                sudo launchctl kickstart -k system/\(installation.launchdLabel)
            """
    }
}

// MARK: - the devices

public extension Requirement {
    /// Whether the devices are free for a verb, or which process holds them.
    ///
    /// The daemon serves one client at a time, so a held device is a verb from here
    /// refused as busy. Nothing here takes them back: which process that is and whether it
    /// should stop is its owner's call, and doctor says only whose they are.
    static func devices(_ reading: DaemonReading) -> Requirement {
        let reads = devicesReads(reading)
        return switch reading {
        case .answered(nil): Requirement(row: .devices, reads: reads, step: nil)
        case .answered(let holder?): Requirement(row: .devices, reads: reads, step: heldStep(holder))
        // The daemon refused to say, and it refused on the signature: that row is what
        // stands in the way, not the daemon's.
        case .refusedThisVhid: Requirement(row: .devices, reads: reads, waitsOn: .signature)
        case .devicesDown, .unreachable, .silent, .failed: Requirement(row: .devices, reads: reads, waitsOn: .daemon)
        }
    }

    private static func devicesReads(_ reading: DaemonReading) -> String {
        switch reading {
        case .answered(nil): "free"
        case .answered(let holder?): "held by pid \(holder)"
        case .devicesDown: "not up"
        case .refusedThisVhid, .unreachable, .silent, .failed: "not asked"
        }
    }

    private static func heldStep(_ holder: Int32) -> String {
        """
        pid \(holder) holds the devices, and a verb from here is refused as
        busy until it hands them back. Which process that is:
            ps -o command= -p \(holder)
        """
    }
}

// MARK: - the Keyboard Setup Assistant

public extension Requirement {
    /// Whether Keyboard Setup Assistant already holds a verdict for the virtual keyboard.
    ///
    /// The only row that bites on first *use* rather than at install: the moment the
    /// virtual keyboard enumerates, macOS raises the assistant, it takes focus, and it
    /// swallows the keystrokes meant for the app in front. The daemon files this keyboard's
    /// answer itself as it starts, before it brings the keyboard up, so what is left to say
    /// is whether that filing has had its chance.
    ///
    /// Which makes the daemon's reading part of this row's step and not context around it.
    /// "Wait for the daemon to file it" is true only while no daemon has started; said to
    /// someone whose daemon has, it is an instruction to wait for something that already
    /// happened, and the one thing that can actually be wrong - the filing failed, and the
    /// daemon logged why - goes unmentioned. [LAW:no-silent-failure]
    ///
    /// - Parameter daemon: the same reading the Daemon row above is built from, and not a
    ///   flag lifted off it, so this row cannot say a daemon started while that one says
    ///   none answered. [LAW:one-source-of-truth] [LAW:no-ambient-temporal-coupling]
    static func keyboardSetupAssistant(answered: Bool, daemon: DaemonReading, installation: Installation) -> Requirement {
        let reads = answered ? "answered ANSI for the virtual keyboard" : "no ANSI answer on file for the virtual keyboard"
        return switch (answered, daemon.daemonHasStarted) {
        case (true, _): Requirement(row: .keyboardSetupAssistant, reads: reads, step: nil)
        case (false, true):
            Requirement(row: .keyboardSetupAssistant, reads: reads, step: """
                \(keyboardSetupAssistantOpening) and it has started - so the
                filing is what failed. It logged why as it started, which may be
                further back than this window; widen it if nothing comes back:
                    \(daemonLog(installation, last: "24h"))
                """)
        case (false, false):
            Requirement(row: .keyboardSetupAssistant, reads: reads, waitsOn: .daemon,
                        why: "\(keyboardSetupAssistantOpening) so this clears once a daemon\nhas started.")
        }
    }

    /// Both arms open the same way, because the reader needs the same fact either way: the
    /// assistant is about to take the first line typed. They differ in what is left to do.
    ///
    /// The started arm's window is wide and says it may not be wide enough: the filing is
    /// logged once, at the daemon's start, and a `KeepAlive` daemon can have started long
    /// before this ran. An empty window is what a reader takes for "no failure here", which
    /// is the silence this arm exists to break. [LAW:no-silent-failure]
    private static let keyboardSetupAssistantOpening = """
        macOS raises Keyboard Setup Assistant the first time the virtual
        keyboard types, and it takes those keystrokes. The daemon files the
        keyboard's answer as it starts,
        """
}
