import Foundation
import ScreenSpace
import ScreenSpaceTesting
import Timeline
import Waiting
@testable import vhidd

/// A deadline for an act that will be answered: the guard, so only a hang fails it.
func guarded() -> Deadline { Timeline.suspending.deadline(within: hangGuard) }

extension Readiness {
    /// Readiness whose one attempt brought `devices` up, as a seat finds it once vhidd serves.
    static func serving(_ devices: any ServedDevices) -> Readiness {
        let readiness = Readiness(driver: { .running })
        _ = readiness.begin()
        readiness.up(devices)
        return readiness
    }
}

/// Devices that record every act, and hold each on `turn` until it says go: a test that
/// needs an act still under way when the next arrives keeps it there.
final class RecordingDevices: ServedDevices, @unchecked Sendable {
    private let acts = Latch<[String]>([])
    /// Whether acts may finish; true unless a test holds them.
    let turn: Latch<Bool>

    init(holdingActs: Bool = false) { turn = Latch(!holdingActs) }

    var done: [String] { acts.current }
    /// Waits until `act` has begun.
    func awaitBegun(_ act: String) throws { try acts.wait(for: act) { $0.contains(act) } }
    private func note(_ act: String) throws {
        acts.update { $0.append(act) }
        try turn.wait(for: "the test to let \(act) finish") { $0 }
    }
    func down(usage: UInt16, by deadline: Deadline) throws { try note("down \(usage)") }
    func releaseAll(by deadline: Deadline) throws { try note("release keys") }
    func hold(usages: [UInt16], by deadline: Deadline) throws { try note("hold \(usages)") }
    func buttonDown(_ button: UInt8, by deadline: Deadline) throws { try note("button \(button)") }
    func releaseButtons(by deadline: Deadline) throws { try note("release buttons") }
    func holdButtons(_ buttons: UInt32, by deadline: Deadline) throws { try note("hold buttons \(buttons)") }
    func move(x: Int8, y: Int8, by deadline: Deadline) throws { try note("move") }
    func scroll(vertical: Int8, horizontal: Int8, by deadline: Deadline) throws { try note("scroll") }
    func releaseKeysHeldPastLimit(heldBy holder: () -> pid_t?) -> KeysLetGo? { nil }
    func releaseEverything(because reason: String) { acts.update { $0.append(reason) } }
}

/// A screen whose cursor is always at one place over one display, for seats whose tests
/// never read it.
struct FixedScreen: ScreenSource {
    var at = (x: 12.5, y: 40.0)
    var displays = DisplayLayout.single
    func cursor() throws -> (x: Double, y: Double) { at }
    func layout() throws -> DisplayLayout { displays }
}
