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
        #expect(requirement.row.settingsPane?.absoluteString == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
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
        guard case .step(let second, 2) = walk.page(readiness) else { Issue.record("expected the devices step"); return }
        #expect(second.row == .devices)
        walk.skip(.devices)
        guard case .summary(_, let skipped) = walk.page(readiness) else { Issue.record("expected the summary"); return }
        #expect(skipped.map(\.row) == [.driverExtension, .devices])
        walk.revisit(.devices)
        guard case .step(let back, _) = walk.page(readiness) else { Issue.record("expected a step"); return }
        #expect(back.row == .devices)
    }

    /// Only an inactive registration can be asked for from a button; once asked, the page
    /// offers System Settings and says macOS asks only once.
    @Test func theDriverIsAskedForOnceAndOnlyWhenInactive() {
        let inactive = Requirement.driverExtension(.installedInactive)
        var walk = Walk()
        #expect(walk.ask(inactive) == .activateDriver)
        #expect(!walk.askedAlready(inactive))
        walk.asked(.driverExtension)
        #expect(walk.ask(inactive) == nil)
        #expect(walk.askedAlready(inactive))
        for state: DriverState in [.absent, .awaitingApproval, .disabled, .pendingReboot, .residue, .unknown, .running] {
            #expect(Requirement.driverExtension(state).ask == nil, "\(state)")
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
        for state: DriverState in [.absent, .installedInactive] {
            #expect(state.step?.contains("\"Karabiner-VirtualHIDDevice-Manager\"") == true, "\(state)")
        }
    }
}
