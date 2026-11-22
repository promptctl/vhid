import Foundation
import TestClock
import Testing
import Timeline
import Waiting
@testable import VirtualHID

/// A deadline that had passed before anything was asked by it.
func spent() -> Deadline {
    let clock = ManualClock()
    let deadline = Timeline(clock).deadline(within: .seconds(1))
    clock.advance(by: .seconds(1))
    return deadline
}

/// What `act` threw when its deadline was missed once the fake had `sent`, and not before.
///
/// The deadline is on a clock this test moves, moved past its limit only once what the
/// client has sent holds `sent`: the miss is then read from a request the fake has, at any
/// pace the runner keeps, and is the daemon's silence and never this side's slowness.
/// [LAW:no-ambient-temporal-coupling]
func missed(once fake: FakeDaemon, has sent: @escaping ([Frame]) -> Bool, _ act: @escaping @Sendable (Deadline) throws -> Void) throws -> any Error {
    let clock = ManualClock()
    let deadline = Timeline(clock).deadline(within: .milliseconds(100))
    let ended = Latch<Result<Void, any Error>?>(nil)
    Thread.detachNewThread {
        let result = Result { try act(deadline) }
        ended.update { $0 = result }
    }
    try fake.awaitSent("what the missed request waits on", until: sent)
    clock.advance(by: .milliseconds(100))
    return try #require(try ended.wait(for: "the missed request to end") { $0 }.failure)
}

private extension Result {
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
