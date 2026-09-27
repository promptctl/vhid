import Foundation
import Input
import Installations
import Keystrokes
import Pointing
import Testing
@testable import Helper
@testable import vhid

/// What a verb says when the daemon could not be reached or would not serve it: the service
/// it dialled, which link failed, and a held key or button only when one could be.
///
/// Driven over a real XPC connection to a far end of the test's own, through the same
/// `Devices.using` every verb and every MCP tool reaches the devices by, so the sentence
/// checked is the sentence printed. [LAW:behavior-not-structure]
@Suite struct UnreachableTests {
    static let far = "ai.promptctl.vhid.tests.far"

    /// How the far end answers: every act acknowledged until `refusing` of them have been,
    /// then every act refused with `refusal`; or the connection refused before it opens,
    /// which is how a daemon refuses a signature.
    enum FarEnd: Sendable {
        case refusing(after: Int, refusal: NSError)
        case unadmitting
    }

    private final class Service: NSObject, HelperService, NSXPCListenerDelegate, @unchecked Sendable {
        let answer: FarEnd
        private let lock = NSLock()
        private var acknowledged = 0

        init(_ answer: FarEnd) { self.answer = answer }

        private func respond(_ reply: (Error?) -> Void) {
            guard case .refusing(let after, let refusal) = answer else { return reply(nil) }
            lock.lock()
            let refuse = acknowledged >= after
            if !refuse { acknowledged += 1 }
            lock.unlock()
            reply(refuse ? refusal : nil)
        }

        func down(usage: UInt16, reply: @escaping (Error?) -> Void) { respond(reply) }
        func releaseAll(reply: @escaping (Error?) -> Void) { respond(reply) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { respond(reply) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { respond(reply) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { respond(reply) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { respond(reply) }
        func leave(reply: @escaping (Error?) -> Void) { respond(reply) }
        func status(reply: @escaping (NSNumber?, Error?) -> Void) { respond { reply(nil, $0) } }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            guard case .refusing = answer else { return false }
            connection.exportedInterface = NSXPCInterface(with: HelperService.self)
            connection.exportedObject = self
            connection.resume()
            return true
        }
    }

    static let devicesDown = NSError(domain: Installation.refusalDomain, code: Installation.devicesDownCode,
                                     userInfo: [NSLocalizedDescriptionKey: "devices not up: the driver extension is awaiting approval"])

    /// What `vhid type ab` against `far` says, and what `vhid click` at the cursor says,
    /// each against a far end of its own so neither counts the other's acts.
    private static func said(_ far: FarEnd) async -> (typed: String, clicked: String) {
        let at = ScreenPoint(x: 5, y: 5)!
        let typed = await failure(against: far) { try await TypeCommand.type("ab", on: VerbTests.us, with: $0.typist) }
        let clicked = await failure(against: far) {
            try await ClickCommand.click(at: at, button: .left, times: .single, with: Pointer(mouse: $0.mouse, cursor: { at }))
        }
        return (typed, clicked)
    }

    /// The listener is held until the verb has said what it says: a far end gone early
    /// fails for another reason. [LAW:no-ambient-temporal-coupling]
    private static func failure(against far: FarEnd, _ verb: (Devices) async throws -> String) async -> String {
        let service = Service(far)
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let helper = HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), service: Self.far, replyTimeout: .seconds(20))
        return await failure { try await Devices.using(helper, verb) }
    }

    /// The words an operator and an MCP client are given for what was thrown.
    private static func failure(_ body: () async throws -> String) async -> String {
        do {
            return "succeeded: \(try await body())"
        } catch {
            return error.reported
        }
    }

    @Test func aServiceNobodyHoldsIsNamedAndNoKeyIsClaimedHeld() async throws {
        let unreachable = "no launchd job answers \(Installation.nobody.service) (NSCocoaErrorDomain 4099): the daemon is not installed or not loaded"
        let typed = await Self.failure { try await Tools.type.call(["text": "ab"], on: Installation.nobody) }
        #expect(typed == "\(unreachable). 0 of 2 characters had been posted and acknowledged before this, and the rest were not sent")
        let clicked = await Self.failure { try await Tools.click.call(["x": 5, "y": 5], on: Installation.nobody) }
        #expect(clicked.hasPrefix(unreachable), "\(clicked)")
        #expect(!clicked.contains("held"), "\(clicked)")
    }

    @Test func aRefusedSignatureIsNamedAndNoKeyIsClaimedHeld() async {
        let said = await Self.said(.unadmitting)
        let refused = "\(Self.far) ended the connection (NSCocoaErrorDomain 4097): the daemon refused this binary's signature, or exited while the call was in flight"
        #expect(said.typed == "\(refused). 0 of 2 characters had been posted and acknowledged before this, and the rest were not sent")
        #expect(said.clicked == refused)
    }

    @Test func devicesNotUpAreSaidInTheDaemonsWordsAndNoKeyIsClaimedHeld() async {
        let said = await Self.said(.refusing(after: 0, refusal: Self.devicesDown))
        let refused = "\(Self.far) refused: devices not up: the driver extension is awaiting approval"
        #expect(said.typed == "\(refused). 0 of 2 characters had been posted and acknowledged before this, and the rest were not sent")
        #expect(said.clicked == refused)
    }

    /// Once the daemon has acknowledged an act, a failure after it may leave that key or
    /// button down, and the release that failed with it says so.
    @Test func aFailureAfterTheDaemonActedKeepsTheHeldWarning() async {
        let said = await Self.said(.refusing(after: 1, refusal: Self.devicesDown))
        let refused = "\(Self.far) refused: devices not up: the driver extension is awaiting approval"
        #expect(said.typed.hasSuffix("The keyboard was not released afterwards: \(refused). A key may be left held"), "\(said.typed)")
        #expect(said.clicked == "\(refused). The mouse was not released afterwards: \(refused). A button may be left held")
    }
}
