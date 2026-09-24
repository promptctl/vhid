import DriverExtension
import Installations
import Testing

@testable import Doctor

/// The requirement table, over every reading each row can take rather than over the ones
/// this Mac happens to be in. What is checked is whether each reading is met and what its
/// step sends a reader to - never how the switch is written. [LAW:behavior-not-structure]
@Suite struct RequirementTests {
    /// An installation of a test's own, so every name a step prints can be traced back to
    /// the value it came from rather than to one of vhid's own two.
    static let installation = Installation(service: "com.example.doctor-test")!

    /// Every daemon reading, one of each.
    static let daemonReadings: [DaemonReading] = [
        .answered(holder: nil), .answered(holder: 4242), .refusedThisSignature,
        .unreachable(reason: "NSCocoaErrorDomain 4099"), .silent(reason: "no answer in 5 seconds"),
        .failed(reason: "something new"),
    ]

    // MARK: - the driver extension

    /// Met exactly when macOS has the extension switched on, and every other word carries
    /// a step of its own.
    @Test func theDriverRowIsMetExactlyWhenTheExtensionIsSwitchedOn() {
        for state in DriverState.allCases {
            let row = Requirement.driverExtension(state)
            #expect(row.met == (state == .enabled || state == .running), "\(state)")
            #expect(row.reads == state.rawValue)
            #expect(row.name == "Driver extension")
        }
    }

    /// Not degrees of one problem: no two unmet driver states send a reader the same way.
    @Test func everyUnmetDriverStateHasAStepOfItsOwn() {
        let steps = DriverState.allCases.compactMap { Requirement.driverExtension($0).step }
        #expect(steps.count == DriverState.allCases.count - 2)
        #expect(Set(steps).count == steps.count)
    }

    /// What each unmet state sends a reader to do, state by state: the steps being distinct
    /// says nothing about any one of them being the right one.
    @Test func eachUnmetDriverStateSendsTheReaderToItsOwnFix() throws {
        let expected: [DriverState: [String]] = [
            .absent: [DriverPackage.version, "scripts/virtual-hid-driver install", "vhid's pkg"],
            .installedInactive: ["\(DriverProbe.managerExecutable) activate"],
            .awaitingApproval: ["Login Items & Extensions", DriverProbe.bundleID],
            .disabled: ["switched off", "Login Items & Extensions", DriverProbe.bundleID],
            .pendingReboot: ["Restart the Mac"],
            .residue: ["scripts/virtual-hid-driver remove", "scripts/virtual-hid-driver install"],
            .unknown: ["vhid driver state"],
        ]
        #expect(Set(expected.keys) == Set(DriverState.allCases.filter { !Requirement.driverExtension($0).met }))
        for (state, phrases) in expected {
            let step = try #require(Requirement.driverExtension(state).step)
            for phrase in phrases {
                #expect(step.contains(phrase), "\(state) does not say \(phrase)")
            }
        }
    }

    /// The click only a person can give names the pane and the extension it is given to.
    @Test func awaitingApprovalNamesThePaneAndTheExtension() throws {
        let step = try #require(Requirement.driverExtension(.awaitingApproval).step)
        #expect(step.contains("Login Items & Extensions"))
        #expect(step.contains(DriverProbe.bundleID))
    }

    /// A registration nobody approved at all is re-asked for by the Manager, run as the
    /// person and never as root: macOS attributes the request to whoever asks.
    @Test func installedButInactiveAsksForTheActivationAsThePerson() throws {
        let step = try #require(Requirement.driverExtension(.installedInactive).step)
        #expect(step.contains("\(DriverProbe.managerExecutable) activate"))
        #expect(!step.contains("sudo \(DriverProbe.managerExecutable)"))
    }

    // MARK: - the launchd job

    @Test func theJobRowIsMetExactlyWhenTheJobHoldsTheService() {
        for standing in JobStanding.allCases {
            for daemon in Self.daemonReadings {
                let row = Requirement.launchdJob(standing, daemon: daemon, installation: Self.installation)
                #expect(row.met == (standing == .holdingTheService), "\(standing) \(daemon)")
                #expect(row.name == "launchd job")
            }
        }
    }

    /// No job under this label while something answers the service is a job under another
    /// label holding it - and loading this installation's own job would lose to it, exit 0
    /// and no endpoint. So the step finds the holder and never loads anything.
    @Test func noJobWhileSomethingHoldsTheServiceFindsTheHolderInsteadOfLoadingAJob() throws {
        for daemon in Self.daemonReadings where daemon.someoneHoldsTheService {
            let row = Requirement.launchdJob(.noJob, daemon: daemon, installation: Self.installation)
            #expect(row.reads == "no job, and something else holds the service", "\(daemon)")
            let step = try #require(row.step)
            #expect(step.contains("grep -lF -- '>com.example.doctor-test<' /Library/LaunchDaemons/*.plist"))
            #expect(!step.contains("bootstrap"), "\(daemon)")
        }
        for daemon in Self.daemonReadings where !daemon.someoneHoldsTheService {
            #expect(Requirement.launchdJob(.noJob, daemon: daemon, installation: Self.installation).step?.contains("bootstrap") == true)
        }
    }

    /// No job: the step writes, enables and loads the plist under this installation's own
    /// label, and names the service that label must carry.
    @Test func noJobLoadsThisInstallationsOwnPlist() throws {
        let step = try #require(Requirement.launchdJob(.noJob, daemon: .unreachable(reason: "4099"), installation: Self.installation).step)
        #expect(step.contains("scripts/launchd-plist com.example.doctor-test"))
        #expect(step.contains("sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.doctor-test.plist"))
        #expect(step.contains("sudo launchctl enable system/com.example.doctor-test"))
    }

    /// Another holder is found, not guessed at: every plist is searched for the service's own
    /// name, as a fixed string.
    @Test func anotherHolderIsSearchedForByTheServiceName() throws {
        let step = try #require(Requirement.launchdJob(.anotherJobHoldsTheService, daemon: .silent(reason: "x"), installation: Self.installation).step)
        #expect(step.contains("grep -lF -- '>com.example.doctor-test<' /Library/LaunchDaemons/*.plist"))
        // A search of processes lists this job's own daemon, running without the endpoint.
        #expect(!step.contains("pgrep"))
    }

    // MARK: - the daemon

    /// An answer and a refusal both prove a listening daemon; everything else is unmet.
    @Test func theDaemonRowIsMetWheneverADaemonWasListening() {
        for reading in Self.daemonReadings {
            let row = Requirement.daemon(reading, installation: Self.installation)
            let listening = switch reading {
            case .answered, .refusedThisSignature: true
            case .unreachable, .silent, .failed: false
            }
            #expect(row.met == listening, "\(reading)")
        }
    }

    /// Each way of not answering carries what the call said, and sends the reader where the
    /// reason is: this installation's own log, when there is a daemon to have written it.
    @Test func eachWayOfNotAnsweringQuotesTheCallAndThisInstallationsLog() throws {
        for reading in Self.daemonReadings where !Requirement.daemon(reading, installation: Self.installation).met {
            let step = try #require(Requirement.daemon(reading, installation: Self.installation).step)
            let said = switch reading {
            case .unreachable(let reason), .silent(let reason), .failed(let reason): reason
            case .answered, .refusedThisSignature: ""
            }
            #expect(step.contains(said), "\(reading)")
            // Nothing holding the service leaves no daemon whose log could say why: the
            // launchd row does, or the two readings disagree and a second look is the step.
            if case .unreachable = reading {
                #expect(step.contains(Requirement.Row.launchdJob.rawValue))
                #expect(step.contains("run doctor again"))
            } else {
                #expect(step.contains("subsystem == \"com.example.doctor-test\""), "\(reading)")
            }
        }
    }

    /// A daemon that is held and silent is, usually, one whose devices cannot come up, and
    /// the step says which row that is.
    @Test func aSilentDaemonPointsAtTheDriverRow() throws {
        let step = try #require(Requirement.daemon(.silent(reason: "x"), installation: Self.installation).step)
        #expect(step.contains(Requirement.Row.driverExtension.rawValue))
    }

    // MARK: - the signature

    @Test func theSignatureRowIsMetOnlyByAnAnswer() {
        for reading in Self.daemonReadings {
            let row = Requirement.signature(reading, installation: Self.installation)
            let answered = if case .answered = reading { true } else { false }
            #expect(row.met == answered, "\(reading)")
        }
    }

    /// The refusal is named as a refusal of the signature, and the step is the one that
    /// fixes an ad hoc tree - not a reconnect.
    @Test func aRefusalNamesTheSignatureAndHowToSignTheTree() throws {
        let row = Requirement.signature(.refusedThisSignature, installation: Self.installation)
        #expect(row.reads.contains("not signed with the daemon's certificate"))
        #expect(try #require(row.step).contains("make sign"))
    }

    /// A daemon that never answered judged no signature, so the row claims nothing and
    /// sends the reader to the row in the way.
    @Test func aSignatureNobodyJudgedWaitsOnTheDaemonRow() {
        for reading in Self.daemonReadings where !reading.daemonHasStarted {
            let row = Requirement.signature(reading, installation: Self.installation)
            #expect(row.reads == "not asked")
            #expect(row.step == "Read once the Daemon row above is met.")
        }
    }

    // MARK: - the devices

    @Test func theDevicesRowIsMetOnlyWhenTheyAreFree() {
        for reading in Self.daemonReadings {
            #expect(Requirement.devices(reading).met == (reading == .answered(holder: nil)), "\(reading)")
        }
    }

    /// A holder is named by pid, with the one command that says which process it is.
    @Test func aHolderIsNamedByPid() throws {
        let row = Requirement.devices(.answered(holder: 4242))
        #expect(row.reads == "held by pid 4242")
        #expect(try #require(row.step).contains("ps -o command= -p 4242"))
    }

    /// A refused caller was told nothing about the devices, and what stands in its way is
    /// the signature - not the daemon, which answered.
    @Test func whoHoldsTheDevicesWaitsOnWhicheverRowIsInTheWay() {
        #expect(Requirement.devices(.refusedThisSignature).step == "Read once the Signature row above is met.")
        for reading in Self.daemonReadings where !reading.daemonHasStarted {
            #expect(Requirement.devices(reading).step == "Read once the Daemon row above is met.")
        }
    }

    // MARK: - the Keyboard Setup Assistant

    @Test func theAssistantRowIsMetExactlyWhenTheAnswerIsOnDisk() {
        for answered in [false, true] {
            for daemon in Self.daemonReadings {
                let row = Requirement.keyboardSetupAssistant(answered: answered, daemon: daemon, installation: Self.installation)
                #expect(row.met == answered)
            }
        }
    }

    /// With a daemon started, the filing has had its chance and failed, so the step sends
    /// the reader to the log it failed in - never to wait.
    @Test func anUnansweredAssistantAfterADaemonStartedSendsTheReaderToTheLog() throws {
        let step = try #require(Requirement.keyboardSetupAssistant(answered: false, daemon: .answered(holder: nil), installation: Self.installation).step)
        #expect(step.contains("filing is what failed"))
        #expect(step.contains("subsystem == \"com.example.doctor-test\""))
        #expect(!step.contains("clears once"))
    }

    /// With no daemon started yet, nothing has failed: the answer is filed when one starts.
    @Test func anUnansweredAssistantBeforeAnyDaemonWaitsOnTheDaemon() throws {
        let step = try #require(Requirement.keyboardSetupAssistant(answered: false, daemon: .unreachable(reason: "4099"), installation: Self.installation).step)
        #expect(step.contains("clears once a daemon"))
        #expect(!step.contains("log show"))
    }

    // MARK: - which daemon readings prove a start

    /// An answer and a refusal come from a daemon past its filing; nothing else proves one
    /// ever ran.
    @Test func onlyAnAnswerOrARefusalProvesADaemonStarted() {
        for reading in Self.daemonReadings {
            let proves = switch reading {
            case .answered, .refusedThisSignature: true
            case .unreachable, .silent, .failed: false
            }
            #expect(reading.daemonHasStarted == proves, "\(reading)")
        }
    }

    // MARK: - names pasted into commands

    /// A name the shell would read differently is quoted so it reads back exactly; vhid's
    /// own names, which hold nothing special, stay bare.
    @Test func aNameIsQuotedOnlyWhenTheShellWouldReadItDifferently() {
        #expect(shellQuoted("ai.promptctl.vhid.vhidd.dev") == "ai.promptctl.vhid.vhidd.dev")
        #expect(shellQuoted("com.a'b") == #"'com.a'\''b'"#)
        #expect(shellQuoted("a$b") == "'a$b'")
        #expect(shellQuoted("") == "''")
    }

    /// A service holding a character XML reserves is searched for as the plist spells it,
    /// and a quote in it cannot end the quoting around the log predicate.
    @Test func stepsSearchForTheNameAsThePlistSpellsItAndQuoteThePredicate() throws {
        let odd = Installation(service: "com.a&b'c")!
        let job = try #require(Requirement.launchdJob(.anotherJobHoldsTheService, daemon: .silent(reason: "x"), installation: odd).step)
        #expect(job.contains(#"grep -lF -- '>com.a&amp;b'\''c<'"#))
        let log = try #require(Requirement.daemon(.silent(reason: "x"), installation: odd).step)
        #expect(log.contains(#"--predicate 'subsystem == "com.a&b'\''c" OR subsystem == "ai.promptctl.vhid"'"#))
    }

    /// A quote or a backslash in a name stays inside the predicate's string literal.
    @Test func aNameIsAPredicateStringLiteralWhateverItHolds() {
        #expect(predicateString(#"com.a"b"#) == #""com.a\"b""#)
        #expect(predicateString(#"a\b"#) == #""a\\b""#)
    }

    /// The log a step sends a reader to spans the subsystem a daemon with no usable
    /// `--service` refuses under - the refusal that leaves a held service silent.
    @Test func theLogSpansTheRefusalOfADaemonThatCouldNotNameItself() throws {
        let step = try #require(Requirement.daemon(.silent(reason: "x"), installation: Self.installation).step)
        #expect(step.contains(#"subsystem == "\#(Installation.unnamedSubsystem)""#))
    }

    // MARK: - the list

    /// A reading that could not be taken stays in the list as an unmet row, carrying why.
    @Test func anUnreadableRowIsUnmetAndSaysWhy() {
        struct Refused: Error, CustomStringConvertible { var description: String { "launchctl exited 113" } }
        let row = Requirement.unreadable(.launchdJob, Refused())
        #expect(!row.met)
        #expect(row.name == "launchd job")
        #expect(row.reads == "could not be read: launchctl exited 113")
        #expect(row.step?.contains("Run doctor again") == true)
    }

    /// A failure with nothing to say still reads as a failure, and one that says several
    /// lines stays on its row's one line.
    @Test func anUnreadableRowSaysSomethingWhateverTheErrorSaid() {
        struct Silent: Error, CustomStringConvertible { var description: String { "" } }
        struct Wordy: Error, CustomStringConvertible { var description: String { "first\nsecond" } }
        #expect(Requirement.unreadable(.daemon, Silent()).reads == "could not be read, and the failure gave no reason")
        #expect(Requirement.unreadable(.daemon, Wordy()).reads == "could not be read: first; second")
    }

    /// Ready means every row met, and one unmet row anywhere is enough to say not.
    @Test func readinessIsEveryRowMet() {
        let met = Requirement.driverExtension(.running)
        let unmet = Requirement.devices(.answered(holder: 1))
        #expect(Readiness([met, met]).ready)
        #expect(!Readiness([met, unmet, met]).ready)
    }

    /// The list from readings is every row, once, in `Row` order - whatever the readings
    /// said, including the ones that could not be taken. A step that says "the row above"
    /// is only true of a list in that order.
    @Test func theListFromReadingsIsEveryRowOnceInOrder() {
        struct Failed: Error {}
        let readings: [(Result<DriverState, any Error>, Result<JobStanding, any Error>, Result<Bool, any Error>)] = [
            (.success(.running), .success(.holdingTheService), .success(true)),
            (.failure(Failed()), .failure(Failed()), .failure(Failed())),
        ]
        for (driver, job, answered) in readings {
            for daemon in Self.daemonReadings {
                let list = Readiness(installation: Self.installation, driver: driver, job: job, daemon: daemon,
                                     keyboardSetupAssistantAnswered: answered)
                #expect(list.requirements.map(\.name) == Requirement.Row.allCases.map(\.rawValue))
            }
        }
    }

    /// A Mac where every reading is the working one is ready, and the list says so.
    @Test func aWorkingMacIsReady() {
        let list = Readiness(installation: Self.installation, driver: .success(.running), job: .success(.holdingTheService),
                             daemon: .answered(holder: nil), keyboardSetupAssistantAnswered: .success(true))
        #expect(list.ready)
    }

    /// A reading that could not be taken becomes that row's unreadable, never a missing row.
    @Test func aFailedReadingBecomesItsOwnRowUnread() {
        struct Failed: Error, CustomStringConvertible { var description: String { "no" } }
        let list = Readiness(installation: Self.installation, driver: .success(.running), job: .failure(Failed()),
                             daemon: .answered(holder: nil), keyboardSetupAssistantAnswered: .success(true))
        #expect(!list.ready)
        #expect(list.requirements[1].reads == "could not be read: no")
    }

    /// Every row printed, met ones included, each step indented under its row.
    @Test func theListPrintsEveryRowAndIndentsEachStep() {
        let list = Readiness([
            Requirement.driverExtension(.running),
            Requirement.devices(.answered(holder: 7)),
        ]).description
        let lines = list.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "Driver extension: running")
        #expect(lines[1] == "Devices: held by pid 7")
        #expect(lines.dropFirst(2).allSatisfy { $0.hasPrefix("  ") })
    }

    /// Every row has a name of its own, so no two rows can be told apart only by position.
    @Test func everyRowHasANameOfItsOwn() {
        #expect(Set(Requirement.Row.allCases.map(\.rawValue)).count == Requirement.Row.allCases.count)
    }
}
