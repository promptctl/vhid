import Foundation
@testable import vhidd

extension Readiness {
    /// Readiness whose one attempt brought `devices` up, as a seat finds it once vhidd serves.
    static func serving(_ devices: any ServedDevices) -> Readiness {
        let readiness = Readiness()
        _ = readiness.begin()
        readiness.up(devices)
        return readiness
    }
}

/// Devices that record every act and answer each with nil.
final class RecordingDevices: NSObject, ServedDevices, @unchecked Sendable {
    private let lock = NSLock()
    private var acts: [String] = []
    var done: [String] { lock.lock(); defer { lock.unlock() }; return acts }
    private func note(_ act: String, _ reply: (Error?) -> Void) { lock.lock(); acts.append(act); lock.unlock(); reply(nil) }
    func down(usage: UInt16, reply: @escaping (Error?) -> Void) { note("down \(usage)", reply) }
    func releaseAll(reply: @escaping (Error?) -> Void) { note("release keys", reply) }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { note("button \(button)", reply) }
    func releaseButtons(reply: @escaping (Error?) -> Void) { note("release buttons", reply) }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { note("move", reply) }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { note("scroll", reply) }
    func releaseKeysHeldPastLimit() -> KeysLetGo? { nil }
    func releaseEverything(because reason: String) { lock.lock(); acts.append(reason); lock.unlock() }
}
