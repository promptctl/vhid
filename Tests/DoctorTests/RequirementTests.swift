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
            let row = Requirement.launchdJob(standing, installation: Self.installation)
            #expect(row.met == (standing == .holdingTheService), "\(standing)")
            #expect(row.name == "launchd job")
        }
    }

    /// No job: the step writes, enables and loads the plist under this installation's own
    /// label, and names the service that label must carry.
    @Test func noJobLoadsThisInstallationsOwnPlist() throws {
        let step = try #require(Requirement.launchdJob(.noJob, installation: Self.installation).step)
        #expect(step.contains("scripts/launchd-plist com.example.doctor-test"))
        #expect(step.contains("sudo launchctl bootstrap system /Library/LaunchDaemons/com.example.doctor-test.plist"))
        #expect(step.contains("sudo launchctl enable system/com.example.doctor-test"))
    }

    /// Another holder is found, not guessed at: both places it can be are searched for the
    /// service's own name.
    @Test func anotherHolderIsSearchedForByTheServiceName() throws {
        let step = try #require(Requirement.launchdJob(.anotherJobHoldsTheService, installation: Self.installation).step)
        #expect(step.contains("grep -l '>com.example.doctor-test<' /Library/LaunchDaemons/*.plist"))
        #expect(step.contains("pgrep -fl vhidd"))
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

    /// Each way of not answering carries what the call said, and sends the reader to this
    /// installation's own log.
    @Test func eachWayOfNotAnsweringQuotesTheCallAndThisInstallationsLog() throws {
        for reading in Self.daemonReadings where !Requirement.daemon(reading, installation: Self.installation).met {
            let step = try #require(Requirement.daemon(reading, installation: Self.installation).step)
            let said = switch reading {
            case .unreachable(let reason), .silent(let reason), .failed(let reason): reason
            case .answered, .refusedThisSignature: ""
            }
            #expect(step.contains(said), "\(reading)")
            #expect(step.contains("subsystem == \"com.example.doctor-test\""), "\(reading)")
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
            for started in [false, true] {
                let row = Requirement.keyboardSetupAssistant(answered: answered, daemonHasStarted: started, installation: Self.installation)
                #expect(row.met == answered)
            }
        }
    }

    /// With a daemon started, the filing has had its chance and failed, so the step sends
    /// the reader to the log it failed in - never to wait.
    @Test func anUnansweredAssistantAfterADaemonStartedSendsTheReaderToTheLog() throws {
        let step = try #require(Requirement.keyboardSetupAssistant(answered: false, daemonHasStarted: true, installation: Self.installation).step)
        #expect(step.contains("filing is what failed"))
        #expect(step.contains("subsystem == \"com.example.doctor-test\""))
        #expect(!step.contains("clears once"))
    }

    /// With no daemon started yet, nothing has failed: the answer is filed when one starts.
    @Test func anUnansweredAssistantBeforeAnyDaemonWaitsOnTheDaemon() throws {
        let step = try #require(Requirement.keyboardSetupAssistant(answered: false, daemonHasStarted: false, installation: Self.installation).step)
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

    // MARK: - the list

    /// A reading that could not be taken stays in the list as an unmet row, carrying why.
    @Test func anUnreadableRowIsUnmetAndSaysWhy() {
        struct Refused: Error, CustomStringConvertible { var description: String { "launchctl exited 113" } }
        let row = Requirement.unreadable(.launchdJob, Refused())
        #expect(!row.met)
        #expect(row.name == "launchd job")
        #expect(row.step == "launchctl exited 113")
    }

    /// Ready means every row met, and one unmet row anywhere is enough to say not.
    @Test func readinessIsEveryRowMet() {
        let met = Requirement.driverExtension(.running)
        let unmet = Requirement.devices(.answered(holder: 1))
        #expect(Readiness([met, met]).ready)
        #expect(!Readiness([met, unmet, met]).ready)
        #expect(Readiness([]).ready)
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
