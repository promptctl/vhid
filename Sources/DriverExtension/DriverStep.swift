// The step for each `DriverState`, in the words both `vhid doctor` and the daemon's
// refusal use.

/// Where a driver extension is approved. Named once because every step that asks for the
/// click ends up here, and a reader following one of them to a pane that does not exist
/// is a reader who stops.
private let loginItemsPane = "System Settings > General > Login Items & Extensions"

public extension DriverState {
    /// What installs the package, for both readers there are: someone with a clone of this
    /// repo, for whom the script does it, and someone who installed vhid's pkg, which
    /// carries the pinned package and asks for the activation as it finishes.
    private static let install = """
        From a clone of this repo:
            scripts/virtual-hid-driver install
        Without one, install vhid's pkg again, which carries the driver package
        and asks macOS to activate it.
        """

    /// What a person does to bring the driver from this state to on, or nil when it is on.
    ///
    /// Here rather than in doctor because the daemon names it too, when a bring-up fails
    /// with the driver not on: pqrs's own status reads "not activated" for most of these
    /// states alike, so only the state read here tells which step is the one.
    /// [LAW:one-source-of-truth]
    var step: String? {
        switch self {
        // macOS has the extension switched on. `running` additionally means some client
        // has opened it, which is not something a person does and not something to ask for.
        case .enabled, .running:
            nil
        case .absent:
            """
            The driver package (\(DriverPackage.version)) is not on this Mac.
            \(Self.install)
            """
        case .installedInactive:
            """
            The package is installed but macOS holds no registration for it,
            so the activation request never landed. Ask for it again, as you
            and not under sudo - macOS attributes the request to whoever asks:
                \(DriverProbe.managerExecutable) activate
            """
        case .awaitingApproval:
            """
            Open \(loginItemsPane),
            click the (i) beside Driver Extensions, and turn on
            \(DriverProbe.bundleID).
            """
        case .disabled:
            """
            The driver is registered and switched off. Open
            \(loginItemsPane),
            click the (i) beside Driver Extensions, and turn on
            \(DriverProbe.bundleID).
            """
        case .pendingReboot:
            """
            The driver was removed, and macOS keeps it registered until this
            Mac restarts. Restart the Mac.
            """
        case .residue:
            """
            Part of the driver package is here and part is not. From a clone
            of this repo, remove what is there and install it again:
                scripts/virtual-hid-driver remove
                scripts/virtual-hid-driver install
            Without one, install vhid's pkg again, which lays the whole package
            back down. If this row still reads residue after that, what is
            left is something macOS lets go of only at a restart: restart the
            Mac, then run vhid doctor again.
            """
        // A registration this build cannot name, or two at once. What was read is in the
        // fact table `vhid driver state` prints, and pointing there beats inventing a step
        // for a state nobody has identified. [LAW:no-silent-failure]
        case .unknown:
            """
            macOS holds a registration this build cannot name. The readings
            it came from:
                vhid driver state
            """
        }
    }
}
