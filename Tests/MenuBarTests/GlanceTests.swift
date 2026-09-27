import Doctor
import DriverExtension
import Foundation
import Helper
import Installations
import Testing
@testable import MenuBar

/// The menu as a value, from readings a test chooses: every Mac a menu can describe,
/// with no daemon, no driver and no menu bar. [LAW:behavior-not-structure]
@Suite struct GlanceTests {
    struct Failed: Error, CustomStringConvertible { var description: String { "nobody answered" } }

    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func readiness(daemon: DaemonReading, job: JobStanding = .holdingTheService) -> Readiness {
        Readiness(installation: .development, driver: .success(.running), job: .success(job), daemon: daemon,
                  keyboardSetupAssistantAnswered: .success(true))
    }

    /// Ready is doctor's ready, and every row is doctor's row in doctor's words between
    /// which copy this is and the daemon's last failure.
    @Test func aWorkingMacIsReadyAndShowsDoctorsRows() {
        let readiness = Self.readiness(daemon: .answered(holder: nil))
        let glance = Glance(installation: .development, readiness: readiness, lastFailure: .success(nil), readAt: Self.at)
        #expect(glance.ready)
        #expect(glance.rows.map(\.mark) == [.about] + Array(repeating: .met, count: readiness.requirements.count) + [.met])
        #expect(glance.rows.dropFirst().dropLast().map(\.text) == readiness.requirements.map(\.description))
        #expect(glance.rows.first?.text.hasPrefix(Installation.development.service) == true)
    }

    /// A stopped daemon is not ready, its rows are unmet, and the failure that could not be
    /// asked is an error row saying why rather than a missing one. [LAW:no-silent-failure]
    @Test func aStoppedDaemonIsNotReadyAndItsUnaskedFailureIsAnError() {
        let glance = Glance(installation: .development, readiness: Self.readiness(daemon: .silent(reason: "no answer in 5 seconds")),
                            lastFailure: .failure(Failed()), readAt: Self.at)
        #expect(!glance.ready)
        #expect(glance.rows.contains { $0.mark == .unmet })
        #expect(glance.rows.last == Glance.Row(mark: .error, text: "The last failure could not be read: nobody answered"))
    }

    /// Who holds the devices is doctor's Devices row.
    @Test func theHolderIsNamed() {
        let glance = Glance(installation: .development, readiness: Self.readiness(daemon: .answered(holder: 4242)),
                            lastFailure: .success(nil), readAt: Self.at)
        #expect(glance.rows.contains { $0.title == "Devices: held by pid 4242" })
    }

    /// The daemon's failure is an error row whose text is the whole failure, however much
    /// of it the title has room for.
    @Test func aFailureRowCarriesItsWholeText() {
        let words = String(repeating: "the keyboard would not release ", count: 8) + "\nsecond line"
        let glance = Glance(installation: .development, readiness: Self.readiness(daemon: .answered(holder: nil)),
                            lastFailure: .success(DaemonFailure(text: words, at: Self.at)), readAt: Self.at)
        let row = glance.rows.last!
        #expect(row.mark == .error)
        #expect(row.text.hasSuffix(words))
        #expect(row.title.count == Glance.Row.widest)
        #expect(row.title.hasSuffix("…"))
        #expect(!row.title.contains("second line"))
    }

    /// The installed copy has no badge; any other names itself by its last word.
    @Test func onlyTheInstalledCopyGoesUnbadged() {
        let readiness = Self.readiness(daemon: .answered(holder: nil))
        func badge(_ installation: Installation) -> String? {
            Glance(installation: installation, readiness: readiness, lastFailure: .success(nil), readAt: Self.at).badge
        }
        #expect(badge(.release) == nil)
        #expect(badge(.development) == "dev")
    }
}
