import Pointing
import TestClock
import Testing
@testable import Input

/// Modifiers held around a pointer act: the reports the keyboard and mouse make together,
/// and what a stop anywhere among them leaves held.
@Suite @MainActor struct HoldingTests {
    static let target = ScreenPoint(x: 5, y: 0)!
    static let shiftCommand = try! HeldModifiers([.leftCommand, .leftShift])

    /// Every key and button the log leaves down after its last report: a key down is held
    /// until `keys up`, a button until `up`.
    static func held(after log: [String]) -> [String] {
        log.reduce(into: [String]()) { held, report in
            switch report {
            case "keys up": held.removeAll { $0.hasPrefix("key down") }
            case "up": held.removeAll { $0.hasPrefix("down") }
            case let down where down.hasPrefix("key down") || down.hasPrefix("down"): held.append(down)
            default: break
            }
        }
    }

    /// The log with each run of motion reports as one `moves`: how many a move takes is
    /// the trajectory's business, and these tests are about what is held around it.
    static func collapsed(_ log: [String]) -> [String] {
        log.reduce(into: [String]()) { runs, report in
            let entry = report.hasPrefix("move ") ? "moves" : report
            if entry != "moves" || runs.last != "moves" { runs.append(entry) }
        }
    }

    /// Modifiers down in a fixed order, then the click with them held, then the mouse and
    /// then the keyboard let go.
    @Test func aModifiedClickIsModifiersDownThenTheClickThenEverythingUp() async throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let click = try await mouse.pointer.holding(Self.shiftCommand, on: mouse.keyboard) {
            try await $0.click(at: .point(Self.target), button: .left, times: .single)
        }
        #expect(click.at == Self.target)
        #expect(Self.collapsed(mouse.log) == ["key down e1", "key down e3", "moves", "down 1", "up", "keys up"])
    }

    /// No modifiers touches no key: the act's reports are the whole run.
    @Test func noModifiersIsTheSameRunWithNothingHeld() async throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        try await mouse.pointer.holding(.none, on: mouse.keyboard) {
            try await $0.scroll(at: .point(Self.target), vertical: 3, horizontal: 0)
        }
        #expect(Self.collapsed(mouse.log) == ["moves", "scroll 1 0", "scroll 1 0", "scroll 1 0"])
    }

    /// A drag carries the modifiers from the press to the release.
    @Test func aModifiedDragHoldsTheModifiersAcrossTheCarry() async throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let option = try HeldModifiers([.leftOption])
        _ = try await mouse.pointer.holding(option, on: mouse.keyboard) {
            try await $0.drag(from: .point(Self.target), to: .point(ScreenPoint(x: 8, y: 0)!), button: .left)
        }
        #expect(Self.collapsed(mouse.log) == ["key down e2", "moves", "down 1", "moves", "up", "keys up"])
    }

    /// Refuse any one report of the run and it stops as `HoldingStopped`, with the refusal
    /// as its cause, releases that answered, and nothing left held.
    @Test func aFailureAtEachStepLeavesNothingHeld() async throws {
        let whole = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        _ = try await whole.pointer.holding(Self.shiftCommand, on: whole.keyboard) {
            try await $0.click(at: .point(Self.target), button: .left, times: .single)
        }
        for step in whole.log.indices {
            let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
            mouse.refused = step ..< step + 1
            let stop = await #expect(throws: HoldingStopped.self) {
                try await mouse.pointer.holding(Self.shiftCommand, on: mouse.keyboard) {
                    try await $0.click(at: .point(Self.target), button: .left, times: .single)
                }
            }
            #expect(stop?.causes.last is Refused, "step \(step): \(whole.log[step])")
            #expect(stop?.unreleased == nil, "step \(step): \(whole.log[step])")
            #expect(stop?.stage == (step < 2 ? .pressing : step < whole.log.count - 1 ? .acting : .releasing), "step \(step)")
            #expect(Self.held(after: mouse.log).isEmpty, "step \(step): \(mouse.log)")
            #expect(Array(mouse.log.prefix(step + 1)) == Array(whole.log.prefix(step + 1)), "step \(step)")
        }
    }

    /// A release that fails too is reported beside the stop, and the report says what may
    /// still be down.
    @Test func aReleaseThatFailsIsReportedBesideTheStop() async throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        mouse.refused = 1 ..< .max
        let stop = await #expect(throws: HoldingStopped.self) {
            try await mouse.pointer.holding(Self.shiftCommand, on: mouse.keyboard) {
                try await $0.click(at: .point(Self.target), button: .left, times: .single)
            }
        }
        #expect(stop?.unreleased != nil)
        #expect(stop?.description.hasSuffix("leftShift+leftCommand may be left held") == true)
    }

    /// A run cancelled between two modifiers stops before the pointer moves, with the key
    /// that went down let go again.
    @Test func aCancelledRunReleasesTheKeysItHeld() async throws {
        let mouse = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let keyboard = CancellingKeyboard(afterReports: 1)
        let run = Task { @MainActor in
            _ = try await mouse.pointer.holding(Self.shiftCommand, on: keyboard) {
                try await $0.click(at: .point(Self.target), button: .left, times: .single)
            }
        }
        keyboard.aim(at: run)
        let stop = await #expect(throws: HoldingStopped.self) { try await run.value }
        #expect(stop?.stage == .pressing)
        #expect(stop?.cause is CancellationError)
        #expect(keyboard.log == ["down e1", "up"])
        #expect(mouse.log.isEmpty)
    }

    /// Fn is no key to the device, so a set naming it does not parse.
    @Test func fnCannotBeHeld() {
        #expect(throws: UnholdableModifiers(modifiers: [.function])) { try HeldModifiers([.leftShift, .function]) }
    }
}
