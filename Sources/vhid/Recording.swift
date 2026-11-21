import Foundation
import Input
import ScreenSpace
import Signals
import Synchronization
import Telemetry

extension Telemetry.Attribute {
    static func name(ofSignal number: Int32) -> String {
        switch number {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        default: "signal \(number)"
        }
    }
}

extension FirstSignal {
    /// Notes the signal taken, if one was, on the unit underway.
    func noted() {
        if let number = taken { Telemetry.note(.signal, .string(Telemetry.Attribute.name(ofSignal: number))) }
    }
}

/// The pauses and moves the devices made over one verb, built up as they go and noted on
/// its record once, when the verb ends. [LAW:single-enforcer] `Devices.using` owns the one
/// trail of the devices it opens, so the record is written by what holds the devices'
/// lifetime, and no record is read back to be added to.
final class Trail: Sendable {
    private struct Kept {
        /// By kind: how many, and how long in all.
        var pauses: [String: (count: Int, length: Duration)] = [:]
        var moves: [JSON] = []
    }

    private let kept = Mutex(Kept())

    /// What a pointer traced: a move to `paths`, a pause to its kind's total in `pauses`.
    @Sendable func traced(_ traced: Pointer.Traced) {
        switch traced {
        case .moved(let move): moved(move)
        case .paused(let pause): paused(pause)
        }
    }

    /// What a typist traced: a pause to its kind's total in `pauses`; how late its run went,
    /// its rollovers and its hesitations to the unit underway.
    @Sendable func typed(_ traced: Typist.Traced) {
        switch traced {
        case .paused(let pause): paused(pause)
        case .ran(let late, let rollovers, let hesitations):
            Telemetry.note(.keysLateMilliseconds, .double(late / .milliseconds(1)))
            Telemetry.tally(.keyRollovers, by: rollovers)
            Telemetry.tally(.keyHesitations, by: hesitations.count)
            Telemetry.note(.keyHesitationMilliseconds, .double(hesitations.reduce(.zero, +) / .milliseconds(1)))
        }
    }

    /// Notes the pauses and the moves on the unit underway, each absent when there were none.
    func noted() {
        let kept = kept.withLock { $0 }
        Telemetry.note(.pauses, kept.pauses.isEmpty ? nil : .object(kept.pauses.mapValues {
            .object(["count": .int($0.count), "ms": .double($0.length / .milliseconds(1))])
        }))
        Telemetry.note(.paths, kept.moves.isEmpty ? nil : .array(kept.moves))
    }

    private func paused(_ pause: Pause) {
        kept.withLock {
            let total = $0.pauses[pause.kind.name, default: (0, .zero)]
            $0.pauses[pause.kind.name] = (total.count + 1, total.length + pause.length)
        }
    }

    private func moved(_ move: Pointer.Moved) {
        var path: [String: JSON] = ["from": point(move.from),
                                    "aimed": point(move.aimed),
                                    "fitts_width": .double(move.width),
                                    "planned_ms": .double(move.planned / .milliseconds(1)),
                                    "structure": .string(move.structure.rawValue),
                                    "bow": .double(move.bow),
                                    "halfway": .double(move.halfway),
                                    "displays": .array(move.displays.frames.map { frame in .array([frame.x, frame.y, frame.width, frame.height].map(JSON.double)) }),
                                    "ends_kept": .double(move.kept.ends),
                                    "bow_kept": .double(move.kept.bow),
                                    "steered_reports": .int(move.steered),
                                    "closing_reports": .int(move.closing),
                                    "lost_reports": .int(move.lost)]
        path["landed"] = move.landed.map(point)
        // The box asked for and the part of it the aim was drawn inside, which with the seed
        // and `from` draws the path again; a point target is `aimed` itself.
        if case .box(let placed) = move.toward {
            path["box"] = .array([placed.value.box.x, placed.value.box.y, placed.value.box.width, placed.value.box.height].map(JSON.double))
            path["shown"] = .array([placed.value.part.x, placed.value.part.y, placed.value.part.width, placed.value.part.height].map(JSON.double))
        }
        kept.withLock { $0.moves.append(.object(path)) }
    }

    private func point(_ point: ScreenPoint) -> JSON {
        .array([.double(point.x), .double(point.y)])
    }
}
