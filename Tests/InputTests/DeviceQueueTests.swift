import Dispatch
import Keystrokes
import OwnThread
import Pointing
import Synchronization
import Testing
import Input

/// What reached the devices, in the order it arrived.
private final class Journal: Sendable {
    private let entries = Mutex<[String]>([])

    var log: [String] { entries.withLock { $0 } }

    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
}

/// A device that holds the thread a key-down is made on until the test acknowledges it,
/// as vhidd's round trip holds it until the report is posted.
private final class BlockingKeyPress: KeyPress {
    private let journal: Journal
    private let acknowledged = Gate()
    /// Opened once a key-down is holding its thread.
    let blocking = Gate()

    init(journal: Journal) { self.journal = journal }

    func acknowledge() { acknowledged.open() }

    /// Bounded by the hang guard, so a key-down made where it should not be fails the test
    /// rather than holding the suite.
    func down(_ usage: Usage) throws {
        blocking.open()
        try acknowledged.wait(for: "the test to acknowledge the key-down")
        journal.record("down \(usage.rawValue)")
    }

    func releaseAll() throws { journal.record("up") }
    func hold(_ keys: HeldKeys) throws { journal.record("hold") }
}

/// A pointing device that answers at once, into the journal a keyboard writes.
private struct JournalPointing: PointingDevice {
    let journal: Journal

    func down(_ button: Button) throws { journal.record("down button \(button.rawValue)") }
    func releaseAll() throws { journal.record("release") }
    func hold(_ buttons: Set<Button>) throws { journal.record("hold buttons") }
    func move(by delta: Move) throws { journal.record("move \(delta.x.value) \(delta.y.value)") }
    func scroll(by delta: Scroll) throws { journal.record("scroll \(delta.vertical.value) \(delta.horizontal.value)") }
}

/// Where a queued device waits for its answer.
@Suite @MainActor struct DeviceQueueTests {
    /// A key-down must not hold the actor it was asked on while the device answers: a
    /// report blocks the thread it is made on until the far side replies, and that wait
    /// belongs nowhere anything else runs. The device is read from the main actor while it
    /// is still holding the key-down's thread; a key-down made on the main actor would
    /// leave nothing to read it until the hold was over, and the hold only ends at the
    /// deadline.
    @Test func aKeyDownWaitsForTheDeviceOffTheCallersActor() async throws {
        let journal = Journal()
        let device = BlockingKeyPress(journal: journal)
        let keyboard = QueuedKeyboard(keyboard: device, queue: DeviceQueue())
        let pressed = Task { try await keyboard.down(Usage(rawValue: 0x04)) }
        try await device.blocking.until(for: "the key-down to hold its thread")
        device.acknowledge()
        try await pressed.value
        #expect(journal.log == ["down 4"])
    }

    /// A key and then a move, asked for on one queue, arrive in that order however long the
    /// key's answer takes. On a queue of its own the move would land while the key waits.
    ///
    /// The move is asked for once the key is on the device, and the key is acknowledged
    /// once the move is in line. A call is in line the moment it is asked for: the move's
    /// task marks that it has asked and calls the mouse in one stretch on this actor, with
    /// nothing between them that could suspend - and the test sees the mark only back on
    /// this actor, so after that stretch has run: a mark seen is a move queued.
    @Test func aKeyAndAMoveOnOneQueueArriveInTheOrderAsked() async throws {
        let journal = Journal()
        let device = BlockingKeyPress(journal: journal)
        let queue = DeviceQueue()
        let keyboard = QueuedKeyboard(keyboard: device, queue: queue)
        let mouse = QueuedMouse(pointing: JournalPointing(journal: journal), queue: queue)
        let pressed = Task { try await keyboard.down(Usage(rawValue: 0x04)) }
        try await device.blocking.until(for: "the key-down to hold its thread")
        let asked = Gate()
        let moved = Task {
            asked.open()
            try await mouse.move(by: Move(x: Count(clamping: 3), y: Count(clamping: 4)))
        }
        try await asked.until(for: "the move to be asked for")
        device.acknowledge()
        try await pressed.value
        try await moved.value
        #expect(journal.log == ["down 4", "move 3 4"])
    }
}
