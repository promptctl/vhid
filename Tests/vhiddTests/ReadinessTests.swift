import Foundation
import Testing
import VirtualHID
@testable import vhidd

/// Devices that are not up refuse every act with the reason, at once; devices that come
/// up are served from the next act on. [LAW:behavior-not-structure]
@Suite struct ReadinessTests {
    private final class Devices: NSObject, ServedDevices, @unchecked Sendable {
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
        func releaseEverything(because reason: String) { lock.lock(); acts.append(reason); lock.unlock() }
    }

    private func answer(_ call: (@escaping (Error?) -> Void) -> Void) -> String? {
        var answered: Error?
        call { answered = $0 }
        return (answered as NSError?)?.localizedDescription
    }

    @Test func beforeTheFirstAttemptEndsEveryActIsRefusedAsStarting() {
        let readiness = Readiness()
        #expect(answer { readiness.down(usage: 4, reply: $0) } == "devices not up: vhidd is still bringing them up")
    }

    /// The refusal names what the pqrs daemon said, and is answered on the calling thread,
    /// without waiting on anything. [LAW:no-silent-failure]
    @Test func aFailedBringUpIsTheRefusalOfEveryAct() {
        let readiness = Readiness()
        let failure = DaemonError.notReady(awaiting: .keyboardReady, said: [.driverActivated: false])
        readiness.become(.down(.failed(failure)))
        let expected = "devices not up: \(failure)"
        #expect(answer { readiness.down(usage: 4, reply: $0) } == expected)
        #expect(answer { readiness.releaseAll(reply: $0) } == expected)
        #expect(answer { readiness.buttonDown(1, reply: $0) } == expected)
        #expect(answer { readiness.releaseButtons(reply: $0) } == expected)
        #expect(answer { readiness.move(x: 1, y: 1, reply: $0) } == expected)
        #expect(answer { readiness.scroll(vertical: 1, horizontal: 0, reply: $0) } == expected)
    }

    @Test func devicesThatComeUpServeTheNextAct() {
        let readiness = Readiness()
        let devices = Devices()
        readiness.become(.down(.failed(DaemonError.silent)))
        readiness.become(.up(devices, daemon: .alreadyRunning))
        #expect(answer { readiness.down(usage: 4, reply: $0) } == nil)
        readiness.releaseEverything(because: "a client went away")
        #expect(devices.done == ["down 4", "a client went away"])
    }
}
