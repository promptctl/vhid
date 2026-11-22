import Foundation
import Keystrokes
import Pointing
import ScreenSpace
import ScreenSpaceTesting
import Timeline
import Waiting
@testable import vhidd

extension Readiness {
    /// Readiness whose one attempt brought `devices` up, as a seat finds it once vhidd serves.
    static func serving(_ devices: any ServedDevices) -> Readiness {
        let readiness = Readiness(driver: { _ in .running })
        _ = readiness.begin()
        readiness.up(devices)
        return readiness
    }
}

/// Devices that record every act, and hold each on `turn` until it says go: a test that
/// needs an act still under way when the next arrives keeps it there. A release made on a
/// client's behalf fails while `unreleased` is set, and so does a claimant's release.
final class RecordingDevices: ServedDevices, @unchecked Sendable {
    private let acts = Latch<[String]>([])
    /// Whether acts may finish; true unless a test holds them.
    let turn: Latch<Bool>
    /// Set by a test for releases that fail; read and written on the test's thread.
    var unreleased: Unreleased?

    init(holdingActs: Bool = false) { turn = Latch(!holdingActs) }

    var done: [String] { acts.current }
    /// Waits until `act` has begun.
    func awaitBegun(_ act: String) throws { try acts.wait(for: act) { $0.contains(act) } }
    private func note(_ act: String) throws {
        acts.update { $0.append(act) }
        try turn.wait(for: "the test to let \(act) finish") { $0 }
    }
    func down(_ usage: Usage, by deadline: Deadline) throws { try note("down \(usage.rawValue)") }
    func releaseAll(by deadline: Deadline) throws { try note("release keys") }
    func hold(_ keys: HeldKeys, by deadline: Deadline) throws { try note("hold \(keys.usages.map(\.rawValue).sorted())") }
    func buttonDown(_ button: Button, by deadline: Deadline) throws { try note("button \(button.rawValue)") }
    func releaseButtons(by deadline: Deadline) throws { try note("release buttons") }
    func holdButtons(_ buttons: Set<Button>, by deadline: Deadline) throws { try note("hold buttons \(Button.field(buttons))") }
    func move(_ delta: Move, by deadline: Deadline) throws { try note("move") }
    func scroll(_ delta: Scroll, by deadline: Deadline) throws { try note("scroll") }
    func release(by deadline: Deadline) throws {
        acts.update { $0.append("release") }
        if let unreleased { throw unreleased }
    }
    func releaseKeysHeldPastLimit(heldBy holder: () -> pid_t?) -> KeysLetGo? { nil }
    func releaseEverything(because reason: String) -> Release {
        acts.update { $0.append(reason) }
        return unreleased.map { .failed($0) } ?? .released
    }
}

/// A screen whose cursor is always at one place over one display, for seats whose tests
/// never read it.
struct FixedScreen: ScreenSource {
    var at = (x: 12.5, y: 40.0)
    var displays = DisplayLayout.single
    func cursor(by deadline: Deadline) throws -> (x: Double, y: Double) { at }
    func layout(by deadline: Deadline) throws -> DisplayLayout { displays }
}
