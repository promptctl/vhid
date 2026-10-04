import AppKit
import Doctor
import DriverExtension
import Foundation
import Helper
import Installations
import MenuBar

/// vhid's menu bar item: whether this copy of vhid is ready, doctor's rows, and the
/// daemon's last failure.
///
/// A view of vhid and never a second way to drive it: it reads, copies a row's text, and
/// opens the set-up walk, whose one request - the driver's activation - makes macOS ask. [LAW:decomposition] What the menu says is `Glance`, a value;
/// this file is the edge that reads the Mac, draws the value and answers a click.
///
/// It serves the installation it was built for, as the CLI beside it does, so the copy
/// `make` builds reads the development daemon and the installed one reads the installed
/// daemon. [LAW:one-source-of-truth]
let installation = Installation.thisBuild

/// How often the menu is read again. Often enough that stopping the daemon shows within a
/// breath; each reading is doctor's - two short subprocesses and a status call - and the
/// last-failure call.
let interval = DispatchTimeInterval.seconds(5)

@MainActor
final class Item: NSObject {
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// One menu for the item's life, its items replaced on each reading, so a reading that
    /// lands while it is open updates it rather than swapping it out from under a click.
    private let menu = NSMenu()
    private let setUp = SetUpWindow(installation: installation, readNow: readNow)

    /// Shown from launch until the first reading lands, which a silent daemon delays by
    /// doctor's whole deadline: an item with no image has no width and is not there at all.
    override init() {
        super.init()
        menu.autoenablesItems = false
        status.menu = menu
        status.button!.image = symbol("hourglass", described: "vhid is being read")
        status.button!.image?.isTemplate = true
    }

    func show(_ glance: Glance, _ readiness: Readiness) {
        setUp.update(readiness)
        let button = status.button!
        button.image = symbol(glance.ready ? "keyboard" : "exclamationmark.triangle", described: glance.ready ? "vhid is ready" : "vhid is not ready")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = glance.badge.map { " \($0)" } ?? ""
        button.toolTip = installation.service

        menu.removeAllItems()
        for row in glance.rows {
            let item = NSMenuItem(title: row.title, action: #selector(copyRow(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = row.text
            item.toolTip = row.text
            item.image = image(for: row.mark)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let walk = NSMenuItem(title: Walk.title, action: #selector(openSetUp), keyEquivalent: "")
        walk.target = self
        menu.addItem(walk)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openSetUp() { setUp.show() }

    /// The row's whole text, which the menu may have cut short. The person asked for it,
    /// so replacing what they had copied is the point.
    @objc private func copyRow(_ sender: NSMenuItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sender.representedObject as! String, forType: .string)
    }

    /// [LAW:dataflow-not-control-flow] Every mark has its look, exhaustively, so a mark
    /// added later has to be given one.
    private func image(for mark: Glance.Row.Mark) -> NSImage? {
        switch mark {
        case .met: tinted("checkmark.circle", .systemGreen, described: "met")
        case .unmet: tinted("exclamationmark.circle", .systemOrange, described: "not met")
        case .error: tinted("exclamationmark.triangle.fill", .systemRed, described: "error")
        case .about: nil
        }
    }

    private func tinted(_ name: String, _ color: NSColor, described: String) -> NSImage {
        symbol(name, described: described).withSymbolConfiguration(.init(paletteColors: [color]))!
    }

    /// A system symbol by a name written in this file. A nil is this file naming a symbol
    /// macOS does not have, which no reader of the menu could do anything about, so it
    /// stops here rather than drawing a blank. [LAW:no-silent-failure]
    private func symbol(_ name: String, described: String) -> NSImage {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: described) else {
            fatalError("macOS has no system symbol named \(name)")
        }
        return image
    }
}

/// One reading of this Mac, taken off the main thread: doctor's, then the daemon's last
/// failure. In that order, because doctor's status call may be what starts the daemon.
/// The failure's deadline is short: a daemon that just answered doctor answers at once,
/// and one that did not has already cost doctor's full deadline. [LAW:effects-at-boundaries]
func read(_ installation: Installation) -> (Glance, Readiness) {
    // Nobody stops a menu's reading: it is read to its end, and the next one waits for it.
    let readiness = Readiness.read(for: installation, stoppedBy: Command.Stop())
    let lastFailure = Result { try HelperConnection(installation: installation, replyTimeout: .seconds(1)).lastFailure() }
    return (Glance(installation: installation, readiness: readiness, lastFailure: lastFailure, readAt: Date()), readiness)
}

// [LAW:no-ambient-temporal-coupling] One serial queue owns the readings - the menu's and
// the set-up window's - so a slow one (a silent daemon takes the status call's full
// deadline) delays the next rather than overlapping it, and each surface is only ever
// drawn from its newest.
let readings = DispatchQueue(label: "\(installation.service).menubar.readings")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = Item()

/// One reading, drawn by the menu and the set-up window when it lands. Run on the readings
/// queue only: the timer runs it there directly, so a reading slower than the interval
/// delays the next rather than stacking one behind another.
/// `@Sendable`: written here, in top-level code, it would otherwise be the main actor's,
/// and run on this queue it traps.
let readAndShow: @Sendable () -> Void = { [installation, item] in
    let (glance, readiness) = read(installation)
    DispatchQueue.main.async { MainActor.assumeIsolated { item.show(glance, readiness) } }
}

/// A reading at once, for the set-up window, queued behind any the timer is taking.
func readNow() { readings.async(execute: readAndShow) }

let timer = DispatchSource.makeTimerSource(queue: readings)
timer.schedule(deadline: .now(), repeating: interval)
timer.setEventHandler(handler: readAndShow)
timer.resume()

withExtendedLifetime(timer) { app.run() }
