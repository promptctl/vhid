import Foundation
import Pointing
import TestClock
import Testing
import Time
import ScreenSpace
import ScreenSpaceTesting
@testable import vhidd

extension Readiness {
    /// Readiness whose one attempt brought `devices` up, as a seat finds it once vhidd serves.
    static func serving(_ devices: any ServedDevices) -> Readiness {
        let readiness = Readiness(driver: { .running })
        _ = readiness.begin()
        readiness.up(devices)
        return readiness
    }
}

/// Devices that record every command they perform and every release they owe, in one log a test
/// can wait on. Every release ends as `releasing` says: done, or left held.
final class RecordingDevices: ServedDevices, @unchecked Sendable {
    private let log = Watched<[String]>([])
    private let releasing: Released
    private let owed = Watched(false)

    init(releasing: Released = Released(keyboard: nil, mouse: nil)) {
        self.releasing = releasing
    }

    var done: [String] { log.current }
    var leftHeld: Bool { owed.current }

    /// Waits until the log reads `expected`, which a release on a connection's own queue
    /// reaches only once what it frees is free.
    @discardableResult
    func await(_ expected: [String], sourceLocation: SourceLocation = #_sourceLocation) -> Bool {
        log.wait("the devices to have done \(expected)", until: { $0 == expected }, sourceLocation: sourceLocation)
    }

    func perform(_ command: DeviceCommand, by deadline: Deadline, acquiring acquire: () throws -> Void) throws {
        try log.withLock { log in
            try acquire()
            log.append(Self.said(command))
        }
    }

    func release(because reason: String, when owed: () -> Bool, then after: () -> Void) -> Released? {
        log.withLock { log in
            guard owed() else { return nil }
            self.owed.withLock { $0 = releasing.failed }
            after()
            log.append(reason)
            return releasing
        }
    }

    func sweep(holding: () -> pid_t?) -> Swept? { nil }

    private static func said(_ command: DeviceCommand) -> String {
        switch command {
        case .down(let usage): "down \(usage.rawValue)"
        case .releaseKeys: "release keys"
        case .hold(let keys): "hold \(keys.usages.map(\.rawValue).sorted())"
        case .buttonDown(let button): "button \(button.rawValue)"
        case .releaseButtons: "release buttons"
        case .holdButtons(let buttons): "hold buttons \(Button.field(buttons))"
        case .move: "move"
        case .scroll: "scroll"
        }
    }
}

/// A screen whose cursor is always at one place over one display, for seats whose tests
/// never read it.
struct FixedScreen: ScreenSource {
    var at = (x: 12.5, y: 40.0)
    var displays = DisplayLayout.single
    func cursor() throws -> (x: Double, y: Double) { at }
    func layout() throws -> DisplayLayout { displays }
}
