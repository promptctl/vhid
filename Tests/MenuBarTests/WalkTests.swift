import Doctor
import DriverExtension
import Installations
import Testing
@testable import MenuBar

/// The set-up walk over readings a test chooses: which page each Mac gets, and what the
/// walk remembers of the person. [LAW:behavior-not-structure]
@Suite struct WalkTests {
    static func readiness(driver: DriverState, daemon: DaemonReading = .answered(holder: nil)) -> Readiness {
        Readiness(installation: .development, driver: .success(driver), job: .success(.holdingTheService), daemon: daemon,
                  keyboardSetupAssistantAnswered: .success(true))
    }

    /// A driver awaiting approval opens the walk on the driver's page.
    @Test func aDriverAwaitingApprovalIsTheFirstPage() throws {
        guard case .step(let requirement, let left) = Walk().page(Self.readiness(driver: .awaitingApproval)) else {
            Issue.record("expected a step"); return
        }
        #expect(requirement.row == .driverExtension)
        #expect(left == 1)
        #expect(requirement.settingsPane?.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    /// Turning the driver on is the next reading, and the next reading is the summary with
    /// every row met.
    @Test func theDriverTurnedOnAdvancesToASummaryOfEveryRowMet() {
        guard case .summary(let met, let skipped) = Walk().page(Self.readiness(driver: .running)) else {
            Issue.record("expected the summary"); return
        }
        #expect(met.map(\.row) == Requirement.Row.allCases)
        #expect(skipped.isEmpty)
    }

    /// Skipping moves to the next unmet row; skipping the last shows the summary with it
    /// set aside; revisiting brings it back.
    @Test func skippingAndRevisiting() {
        let readiness = Self.readiness(driver: .awaitingApproval, daemon: .answered(holder: 7))
        var walk = Walk()
        guard case .step(let first, 2) = walk.page(readiness) else { Issue.record("expected two steps"); return }
        #expect(first.row == .driverExtension)
        walk.skip(.driverExtension)
        // The count is of steps still ahead: the skipped driver is not one of them.
        guard case .step(let second, 1) = walk.page(readiness) else { Issue.record("expected the devices step"); return }
        #expect(second.row == .devices)
        walk.skip(.devices)
        guard case .summary(_, let skipped) = walk.page(readiness) else { Issue.record("expected the summary"); return }
        #expect(skipped.map(\.row) == [.driverExtension, .devices])
        walk.revisit(.devices)
        guard case .step(let back, _) = walk.page(readiness) else { Issue.record("expected a step"); return }
        #expect(back.row == .devices)
    }

    /// Only an inactive registration can be asked for from a button, and it can be asked
    /// again for as long as it reads inactive: a request that never landed leaves it there.
    @Test func onlyAnInactiveDriverIsAskedFor() {
        #expect(Requirement.driverExtension(.installedInactive).ask == .activateDriver)
        for state: DriverState in [.absent, .awaitingApproval, .disabled, .pendingReboot, .residue, .unknown, .running] {
            #expect(Requirement.driverExtension(state).ask == nil, "\(state)")
        }
    }

    /// What the window logs names the row, its reading, the count, and a request's fate.
    @Test func setUpEventsNameWhatHappened() {
        #expect(SetUpEvent.page(Walk().page(Self.readiness(driver: .awaitingApproval))).description
            == "setup page: step Driver extension (awaiting-approval), 1 left")
        #expect(SetUpEvent.page(Walk().page(Self.readiness(driver: .running))).description
            == "setup page: summary, \(Requirement.Row.allCases.count) met, 0 set aside")
        #expect(SetUpEvent.skip(.driverExtension).description == "setup skip: Driver extension")
        #expect(SetUpEvent.askFailed(.activateDriver, reason: "no Manager").description == "setup ask: activateDriver could not start: no Manager")
        #expect(SetUpEvent.askEnded(.activateDriver, status: 0, said: "").description == "setup ask: activateDriver ended 0: said nothing")
    }

    /// A Mac whose driver awaits approval has its daemon's devices down, and the rows that
    /// wait on the daemon are no steps of their own: the walk is the driver and the daemon.
    @Test func rowsWaitingOnAnEarlierRowAreNotSteps() {
        let readiness = Self.readiness(driver: .awaitingApproval, daemon: .devicesDown(reason: "the driver is not running"))
        var walk = Walk()
        guard case .step(let first, let left) = walk.page(readiness) else { Issue.record("expected a step"); return }
        #expect(first.row == .driverExtension)
        #expect(left == 2)
        walk.skip(.driverExtension)
        walk.skip(.daemon)
        guard case .summary(_, let unmet) = walk.page(readiness) else { Issue.record("expected the summary"); return }
        #expect(unmet.contains { $0.row == .devices && $0.waitsOn == .daemon })
    }

    /// System Settings is offered only for a driver whose switch is there.
    @Test func onlyADriverWithASwitchOffersSystemSettings() {
        for state: DriverState in [.awaitingApproval, .disabled] {
            #expect(Requirement.driverExtension(state).settingsPane != nil, "\(state)")
        }
        for state: DriverState in [.absent, .installedInactive, .pendingReboot, .residue, .unknown] {
            #expect(Requirement.driverExtension(state).settingsPane == nil, "\(state)")
        }
    }

    /// Every row has words for why it is asked and what skipping it costs.
    @Test func everyRowIsExplained() {
        for row in Requirement.Row.allCases {
            #expect(!row.explanation.why.isEmpty && !row.explanation.ifSkipped.isEmpty, "\(row)")
        }
    }

    /// Every step that ends in macOS's activation dialog names the product that dialog
    /// names, which is not vhid.
    @Test func stepsThatActivateNameTheManager() {
        for state: DriverState in [.absent, .installedInactive, .residue] {
            #expect(state.step?.contains("\"Karabiner-VirtualHIDDevice-Manager\"") == true, "\(state)")
        }
    }
}
