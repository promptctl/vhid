import Keystrokes
import Pointing
import Testing
@testable import Input

/// Recordings made from tap events a test wrote, read back by the parser `vhid play`
/// uses: what the recorder writes is judged by what a replay would do with it.
/// [LAW:behavior-not-structure]
@Suite struct RecorderTests {
    static let start = ScreenPoint(x: 100, y: 100)!
    static let vhid: UInt64 = 4_297_410_007
    static let stopKeys: Set<Usage> = [.leftControl, .rightControl, Usage(rawValue: 0x06)]

    private func event(_ ms: Int, _ kind: TapEvent.Kind, at location: ScreenPoint = start, from sender: UInt64 = 0) -> TapEvent {
        TapEvent(at: .milliseconds(ms), sender: sender, location: location, kind: kind)
    }

    private func point(_ x: Double, _ y: Double) -> ScreenPoint { ScreenPoint(x: x, y: y)! }

    private func keys(_ usages: UInt16...) -> Play.Report { .keys(try! HeldKeys(Set(usages.map(Usage.init(rawValue:))))) }

    /// What the script says, line by line: when, and what.
    private func replayed(_ recorder: Recorder, stoppedAt stop: Int) throws -> [(Int, Play.Report)] {
        let play = try Play.parse(recorder.script(stoppedAt: .milliseconds(stop), stopKeys: Self.stopKeys))
        #expect(play.start == recorder.start)
        return play.events.map { (Int($0.at.components.seconds * 1000 + $0.at.components.attoseconds / 1_000_000_000_000_000), $0.report) }
    }

    private func expect(_ got: [(Int, Play.Report)], _ want: [(Int, Play.Report)], sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(got.map(\.0) == want.map(\.0), sourceLocation: sourceLocation)
        #expect(got.map(\.1) == want.map(\.1), sourceLocation: sourceLocation)
    }

    /// Shift held through h, an autorepeat that is dropped, then i; a drag. Every held set
    /// is its own line, the drag is points, and the script ends with nothing held.
    @Test func typingAndADragRoundTrip() throws {
        var recorder = Recorder(start: Self.start, flags: 0, vhid: [Self.vhid]) { _ in false }
        for event in [
            event(10, .flagsChanged(keyCode: 56, flags: 0x20002)),
            event(20, .keyDown(keyCode: 4, autorepeat: false)),
            event(25, .keyDown(keyCode: 4, autorepeat: true)),
            event(30, .keyUp(keyCode: 4)),
            event(35, .flagsChanged(keyCode: 56, flags: 0)),
            event(40, .keyDown(keyCode: 34, autorepeat: false)),
            event(45, .keyUp(keyCode: 34)),
            event(50, .buttonDown(.left)),
            event(58, .motion, at: point(110, 105.5)),
            event(66, .motion, at: point(120, 110)),
            event(70, .buttonUp(.left), at: point(120, 110)),
        ] { recorder.take(event) }
        expect(try replayed(recorder, stoppedAt: 80), [
            (0, keys()), (10, keys(0xE1)), (20, keys(0x0B, 0xE1)), (30, keys(0xE1)), (35, keys()),
            (40, keys(0x0C)), (45, keys()), (50, .buttons([.left])), (58, .at(point(110, 105.5))),
            (66, .at(point(120, 110))), (70, .buttons([])), (80, keys()), (80, .buttons([])),
        ])
    }

    /// The Control-C that stopped the recording is not in it; Control-X, which was not the
    /// stop, is. The script still ends with nothing held, at the stop.
    @Test func theStopChordIsTrimmedAndNothingElse() throws {
        var stopped = Recorder(start: Self.start, flags: 0, vhid: []) { _ in false }
        stopped.take(event(10, .keyDown(keyCode: 0, autorepeat: false)))
        stopped.take(event(20, .keyUp(keyCode: 0)))
        stopped.take(event(100, .flagsChanged(keyCode: 59, flags: 0x40001)))
        stopped.take(event(101, .keyDown(keyCode: 8, autorepeat: false)))
        expect(try replayed(stopped, stoppedAt: 150), [
            (0, keys()), (10, keys(0x04)), (20, keys()), (100, keys()), (101, keys()), (150, keys()), (150, .buttons([])),
        ])

        // Let go before the stop took effect: the releases are the chord's too.
        stopped.take(event(110, .keyUp(keyCode: 8)))
        stopped.take(event(112, .flagsChanged(keyCode: 59, flags: 0)))
        expect(try replayed(stopped, stoppedAt: 150), [
            (0, keys()), (10, keys(0x04)), (20, keys()), (100, keys()), (101, keys()), (110, keys()), (112, keys()), (150, keys()), (150, .buttons([])),
        ])

        var cut = Recorder(start: Self.start, flags: 0, vhid: []) { _ in false }
        cut.take(event(100, .flagsChanged(keyCode: 59, flags: 0x40001)))
        cut.take(event(101, .keyDown(keyCode: 7, autorepeat: false)))
        expect(try replayed(cut, stoppedAt: 90), [
            (0, keys()), (100, keys(0xE0)), (101, keys(0x1B, 0xE0)), (101, keys()), (101, .buttons([])),
        ])
    }

    /// vhid's own motion moves the cursor under the person, and is taken back out of their
    /// points; its modifiers are in the session's flags, and are taken out of their keys.
    @Test func vhidsOwnEventsAreNotThePersons() throws {
        var recorder = Recorder(start: Self.start, flags: 0, vhid: [Self.vhid]) { $0.x >= 150 }
        recorder.take(event(10, .motion, at: point(150, 100), from: Self.vhid))
        recorder.take(event(20, .motion, at: point(160, 102)))
        recorder.take(event(30, .flagsChanged(keyCode: 56, flags: 0x20002), at: point(160, 102), from: Self.vhid))
        recorder.take(event(40, .keyDown(keyCode: 0, autorepeat: false), at: point(160, 102)))
        recorder.take(event(50, .flagsChanged(keyCode: 56, flags: 0), at: point(160, 102), from: Self.vhid))
        recorder.take(event(60, .keyDown(keyCode: 4, autorepeat: false), at: point(160, 102), from: Self.vhid))
        recorder.take(event(70, .keyUp(keyCode: 0), at: point(160, 102)))
        expect(try replayed(recorder, stoppedAt: 80), [
            (0, keys()), (20, .at(point(110, 102))), (40, keys(0x04)), (70, keys()), (80, keys()), (80, .buttons([])),
        ])
        #expect(recorder.vhidAtEdge == 1)
    }

    /// An earlier Control-C, and a Control-A whose A came up inside the stop chord, are the
    /// person's: only the stop's own presses come out.
    @Test func onlyTheStopsOwnPressesComeOut() throws {
        var earlier = Recorder(start: Self.start, flags: 0, vhid: []) { _ in false }
        earlier.take(event(10, .flagsChanged(keyCode: 59, flags: 0x40001)))
        earlier.take(event(11, .keyDown(keyCode: 8, autorepeat: false)))
        earlier.take(event(12, .keyUp(keyCode: 8)))
        earlier.take(event(13, .flagsChanged(keyCode: 59, flags: 0)))
        earlier.take(event(20, .motion, at: point(101, 100)))
        earlier.take(event(30, .flagsChanged(keyCode: 59, flags: 0x40001)))
        earlier.take(event(31, .keyDown(keyCode: 8, autorepeat: false)))
        expect(try replayed(earlier, stoppedAt: 40), [
            (0, keys()), (10, keys(0xE0)), (11, keys(0x06, 0xE0)), (12, keys(0xE0)), (13, keys()),
            (20, .at(point(101, 100))), (30, keys()), (31, keys()), (40, keys()), (40, .buttons([])),
        ])

        var controlA = Recorder(start: Self.start, flags: 0, vhid: []) { _ in false }
        controlA.take(event(5, .flagsChanged(keyCode: 59, flags: 0x40001)))
        controlA.take(event(10, .keyDown(keyCode: 0, autorepeat: false)))
        controlA.take(event(20, .keyUp(keyCode: 0)))
        controlA.take(event(30, .keyDown(keyCode: 8, autorepeat: false)))
        expect(try replayed(controlA, stoppedAt: 40), [
            (0, keys()), (5, keys(0xE0)), (10, keys(0x04, 0xE0)), (20, keys()), (30, keys()), (40, keys()), (40, .buttons([])),
        ])
    }

    /// vhid letting go of a modifier the person also holds leaves it the person's: once it
    /// comes up, their next press of it is recorded. Times that arrive out of order are
    /// held to the line before.
    @Test func aSharedModifierIsThePersonsOnceVhidLetsGo() throws {
        var recorder = Recorder(start: Self.start, flags: 0, vhid: [Self.vhid]) { _ in false }
        recorder.take(event(10, .flagsChanged(keyCode: 56, flags: 0x20002), from: Self.vhid))
        recorder.take(event(20, .flagsChanged(keyCode: 56, flags: 0x20002)))
        recorder.take(event(30, .flagsChanged(keyCode: 56, flags: 0x20002), from: Self.vhid))
        recorder.take(event(40, .flagsChanged(keyCode: 56, flags: 0)))
        recorder.take(event(50, .flagsChanged(keyCode: 56, flags: 0x20002)))
        recorder.take(event(45, .flagsChanged(keyCode: 56, flags: 0)))
        expect(try replayed(recorder, stoppedAt: 60), [
            (0, keys()), (50, keys(0xE1)), (50, keys()), (60, keys()), (60, .buttons([])),
        ])
    }

    /// Caps Lock never comes up, so it is a press: with it, then without. A key with no
    /// usage is left out and counted. A modifier down when recording started is the first
    /// line, and comes up when it does.
    @Test func capsLockFnAndAModifierAlreadyDown() throws {
        var recorder = Recorder(start: Self.start, flags: 0x100008, vhid: []) { _ in false }
        recorder.take(event(10, .flagsChanged(keyCode: 55, flags: 0)))
        recorder.take(event(20, .flagsChanged(keyCode: 0x39, flags: 0x10000)))
        recorder.take(event(30, .flagsChanged(keyCode: 63, flags: 0x800100)))
        recorder.take(event(35, .flagsChanged(keyCode: 63, flags: 0)))
        expect(try replayed(recorder, stoppedAt: 40), [
            (0, keys(0xE3)), (10, keys()), (20, keys(0x39)), (20, keys()), (40, keys()), (40, .buttons([])),
        ])
        #expect(recorder.unmapped == 1)
    }

    /// A recording is a script `vhid play` schedules whole: at lines and all.
    @Test func aRecordingSchedules() throws {
        var recorder = Recorder(start: Self.start, flags: 0, vhid: []) { _ in false }
        recorder.take(event(8, .motion, at: point(104, 100)))
        recorder.take(event(16, .buttonDown(.left), at: point(104, 100)))
        recorder.take(event(24, .buttonUp(.left), at: point(104, 100)))
        let schedule = try Schedule(Play.parse(recorder.script(stoppedAt: .milliseconds(30), stopKeys: Self.stopKeys)))
        #expect(schedule.calibration != nil)
        #expect(schedule.reports == 3)
    }
}
