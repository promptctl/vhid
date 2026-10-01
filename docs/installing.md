# Installing and uninstalling

What the pkg puts on a Mac, the one step it leaves to you, how to tell whether vhid is ready, and how to take it all out again.

vhid ships as one signed, notarized pkg. It installs:

| path | what it is |
|---|---|
| `/usr/local/bin/vhid` | the CLI |
| `/usr/local/bin/eyes` | the screen reader: `windows` and `displays` need no grant; `find` and `read` need Accessibility for the tree and Screen Recording for pixels, merged either ([mcp.md](mcp.md) says whose) |
| `/usr/local/libexec/vhidd` | the root daemon that owns the devices |
| `/Library/LaunchDaemons/ai.promptctl.vhid.vhidd.plist` | the daemon's launchd job, loaded as the install finishes |
| `/usr/local/libexec/vhid-menubar` | the menu bar item |
| `/usr/local/libexec/vhid-record.app` | the tap `vhid record` runs, granted Input Monitoring once |
| `/Library/LaunchAgents/ai.promptctl.vhid.vhidd.menubar.plist` | its launchd job, started at every login |
| `/usr/local/libexec/vhid-uninstall` | removes everything in this table |
| `/usr/local/libexec/vhid-virtual-hid-driver` | the driver removal `vhid-uninstall --driver` runs |

It also installs the pinned
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
package, pqrs's own component carried inside this one, and asks macOS to activate its
driver extension for whoever is logged in. Karabiner-Elements is not needed; on a Mac
that has it, the installer warns that the driver's Manager app and support files it
shares are replaced.

One step is left to you, because macOS attributes a driver extension to the person at
the Mac and no installer can approve it: turn on
`org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` under **System Settings > General > Login
Items & Extensions > Driver Extensions (i)**. An install made while you are logged in
ends with that sheet open. `vhid driver state` prints `enabled` or `running` once it is
on, and `vhid doctor` prints `ready` once everything vhid needs is met. Until then the
daemon is loaded but cannot bring the devices up: it keeps trying, backing off to once a
minute, and refuses every verb with `devices not up:` and the reason, which names the
driver's step while the driver is off. Once the driver is on, the
next attempt brings the devices up with no restart.

The installed CLI talks to the installed daemon by default. A build from this tree talks
to the development copy, `ai.promptctl.vhid.vhidd.dev`, so the two can run side by side.

When a verb fails, run `vhid doctor`. It prints `ready` or `not ready`, then one row per
requirement — the driver extension, the daemon's launchd job, the daemon, whether it
admits this vhid, who holds the devices, and the Keyboard Setup Assistant answer — each
with what it read on this Mac and the step left for you, and exits 1 while any row has a
step. It fixes nothing and takes the devices from no client that holds them; a daemon
launchd has a job for but has not started is started by its question, as by any verb.

The menu bar item shows the same reading at a glance, every five seconds: a keyboard when
doctor would print `ready`, a warning triangle when it would not. Its menu lists doctor's
rows and the daemon's most recent failure, and clicking a row copies its full text.
**Set Up vhid…** walks the unmet rows one page at a time, each with why vhid needs it and
what skipping it costs. It reads the Mac again every time you come back to the window, so
turning the driver on in System Settings moves the walk on by itself. Apart from the
driver's activation, which it asks macOS for as you, it only reads. Quit stops it until
the next login. The item from a build of this tree,
`.build/debug/vhid-menubar`, shows the development copy and says `dev` beside its icon.

## Uninstalling

```sh
sudo /usr/local/libexec/vhid-uninstall            # vhid, leaving the pqrs driver
sudo /usr/local/libexec/vhid-uninstall --driver   # vhid and the pqrs driver package
```

Either stops the daemon and the menu bar item, removes every file in the table
above (both uninstall scripts among them) and forgets the pkg's receipt; run again,
it says there is nothing to remove. Neither touches the development job a build of this
tree registers.

The first leaves the pqrs driver installed, since Karabiner-Elements may use it. To
remove the driver with vhid, choose `--driver` on that first run: afterwards the script
that removes it is gone, and pqrs's own scripts in
`/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall`
are what is left.

`--driver` withdraws the driver extension as whoever is logged in, then deletes the
driver package's files and receipt. Before stopping anything it refuses, saying why,
when the driver cannot safely be removed: Karabiner-Elements is installed, the
development job is loaded, nobody is logged in to withdraw the extension, the extension
is registered but the Manager app that withdraws it is gone (reinstalling the pkg brings
it back), or a reading it needs cannot be taken. If the removal fails partway, vhid is left stopped with its
files in place, and the message says so; run the same command again once the cause is
fixed, or drop `--driver` to remove vhid alone. A withdrawn extension can stay
registered until the next restart.
