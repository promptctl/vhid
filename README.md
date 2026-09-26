# vhid

A virtual keyboard and a virtual mouse for macOS, driven from a CLI or over MCP.

It creates two HID devices through the
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
driver extension and posts reports to them. To macOS the input is indistinguishable
from hardware: no event taps, no Accessibility grant, no window-server synthesis.

**It is a driver, not a nanny.** It types what it is told to type and clicks where it
is told to click. Which app is in front, whether a dialog is covering it, and whether
you meant to do this are not its questions to ask.

Extracted from [low-talker](https://github.com/promptctl/low-talker), whose dictation
typed through this stack first.

## Two packages

The repository holds two SwiftPM packages, and the root manifest deliberately does not
mention the second one.

| | what it is | build and test |
|---|---|---|
| `.` | the devices: the keyboard, the mouse, and the root daemon that owns them | `make test` |
| `eyes/` | reading the screen: where the windows are, and the vocabulary an accessibility reader and an OCR reader both speak | `cd eyes && swift build && swift test` |

`eyes` finds a coordinate; `vhid click` presses it. Nothing joins them in code — only that
workflow. A target in the root manifest would be one `dependencies:` line away from
linking the two, and nothing in review catches that line, so the separation is a package
boundary rather than a rule someone has to remember.

The cost of that isolation is this paragraph: `make test` at the root does not run
`eyes`' tests, and nothing but this table says so.

## Scope

vhid's core is input that macOS sees as hardware, from a virtual keyboard and mouse;
its sibling package `eyes` reads the screen so that input can be aimed. A feature that
works through the devices fits naturally. A feature that reaches around them — the
clipboard, posting synthetic events, app-specific APIs — belongs here only when the case
for it is overwhelmingly compelling, close to a requirement, *and* it would make no sense
as a separate project.

## The CLI

```sh
vhid type "hello"
vhid keys leftCommand+s
vhid click 800 500 --button left --times 2
vhid move 800 500
vhid scroll 800 500 --vertical 3
vhid drag 100 100 400 300
vhid cursor
vhid pointer play < script.jsonl
vhid doctor
```

It types where the keyboard is pointed and clicks where it is told. There is no
click-by-element and no target app, because nothing in vhid reads the screen — what is
under a point is the caller's to know.

Which keys make which characters is the console user's keyboard layout, read in the CLI
rather than in the daemon: macOS answers that question per process, and a root daemon
asking it is told the US layout whatever the user is typing on. `type` refuses text the
layout has no keys for.

`--service` says which installation to talk to. It defaults to the one the binary was
built for: the installed copy for the installed CLI, and the development copy for a
build from this tree. `vhid service` prints which. Coordinates are screen points from the top left of the main display; a display
left of or above it has negative ones, which follow `--`.

## Over MCP

`vhid mcp` serves the same verbs as MCP tools over stdio: `type`, `press`, `click`,
`move`, `scroll`, `drag`, `cursor` and `doctor`. Point a client at the binary with the one argument:

```json
{ "command": "/path/to/vhid", "args": ["mcp"] }
```

Each tool call connects to the daemon and leaves when it returns, so a session holds
nothing between calls and a `vhid click` from a shell still gets through. Stdout carries
only JSON-RPC; diagnostics go to stderr. An argument a tool will not act on comes back as
a tool error naming it, before anything is connected.

## Installing

vhid ships as one signed, notarized pkg. It installs:

| path | what it is |
|---|---|
| `/usr/local/bin/vhid` | the CLI |
| `/usr/local/libexec/vhidd` | the root daemon that owns the devices |
| `/Library/LaunchDaemons/ai.promptctl.vhid.vhidd.plist` | the daemon's launchd job, loaded as the install finishes |

It also installs the pinned
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
package, pqrs's own component carried inside this one, and asks macOS to activate its
driver extension for whoever is logged in. Karabiner-Elements is not needed; on a Mac
that has it, the installer warns that the driver's Manager app and support files it
shares are replaced.

One step is left to you, because macOS attributes a driver extension to the person at
the Mac and no installer can approve it: open **System Settings > General > Login Items &
Extensions**, click the (i) beside **Driver Extensions**, and turn on
`org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`. The installer's last page says the
same. `vhid driver state` prints `running` once it is on. Until then the daemon is
loaded but cannot bring the devices up, and launchd keeps restarting it.

The installed CLI talks to the installed daemon by default. A build from this tree talks
to the development copy, `ai.promptctl.vhid.vhidd.dev`, so the two can run side by side.

When a verb fails, run `vhid doctor`. It prints `ready` or `not ready`, then one row per
requirement — the driver extension, the daemon's launchd job, the daemon, whether it
admits this vhid, who holds the devices, and the Keyboard Setup Assistant answer — each
with what it read on this Mac and the step left for you, and exits 1 while any row has a
step. It fixes nothing and takes the devices from no client that holds them; a daemon
launchd has a job for but has not started is started by its question, as by any verb.

## Building

`make` builds and signs. `make test` runs the suite and leaves the tree signed behind
it.

Use those rather than `swift build` and `swift test` directly, because of one rule in
the daemon: it admits a caller carrying the certificate it carries itself, and refuses
everything else. SwiftPM ad hoc signs every product it links, and an ad hoc signature
names a hash that changes with the binary, so it can neither be required of a caller nor
satisfied by one. A tree built with bare `swift build` therefore gets
`NSCocoaErrorDomain 4097` on the first call — which reads like a connection that failed
rather than an identity that was refused, and costs an afternoon in the XPC plumbing
before anyone suspects the signature. `make sign` repairs a tree that has been built
that way.

The first `make` on a Mac makes a self-signed certificate called `vhid Dev` and signs
with it from then on. Nothing has to be run by hand first: a certificate that has to be
asked for is a certificate a first build does without, and a first build that does
without it is the 4097 above.

It lives in a keychain of its own, `~/Library/Keychains/vhid-dev.keychain-db`, rather
than in the login keychain, and that is what keeps builds silent. A key imported into
the login keychain has an empty partition list, so the first `codesign` reaching for it
raises *codesign wants to sign using key ... in your keychain* and waits; clearing that
permanently needs the login keychain's password, which nothing can supply from inside a
build. vhid's own keychain has a password vhid knows. The password is in
`scripts/signing-keychain` and is not a secret — it protects one certificate that no Mac
trusts, whose only power is to make this machine's daemon admit this machine's CLI, both
already running as you.

To undo all of it, one command — which takes the keychain out of the search list as
well as deleting it:

```sh
security delete-keychain vhid-dev.keychain
```

This certificate is for development and cannot ship: no other Mac trusts it. What signs
a release is a Developer ID certificate, which is a separate thing kept deliberately
apart — the day the dev certificate quietly signs something that ships is the day vhid
ships something nobody can run, and the build stays green while it happens.

## Releasing

```sh
NOTARY_PROFILE=<profile> scripts/release <version> dist    # dist/vhid-<version>.pkg
```

That runs two scripts, and each can also be run on its own:

```sh
scripts/make-pkg <version> dist                         # built and signed
NOTARY_PROFILE=<profile> scripts/notarize dist/vhid-<version>.pkg   # notarized and stapled
```

`scripts/make-pkg` builds for arm64 and x86_64 in a scratch directory of its own. It signs
both binaries with the team's **Developer ID Application** certificate, with Hardened
Runtime and a secure timestamp, and signs the pkg with its **Developer ID Installer**
certificate. It finds both by team ID and refuses to guess when there are none or
several. The daemon admits a caller signed with its own certificate, so the installed
CLI is let in and a dev-signed build is refused. The launchd job is named after the
service the packed CLI dials (`vhid service`), so the job and the CLI cannot disagree.
The driver package is fetched and checked against its pinned checksum and pqrs's
signature by `scripts/virtual-hid-driver fetch`. That is the one check of pqrs's
signature: productbuild carries the component's contents without it, so on an installing
Mac the pkg's own Developer ID Installer signature is what covers the driver too.

`scripts/notarize` submits the pkg, prints the notary log if the answer is anything
but Accepted, staples the ticket, and requires Gatekeeper to assess the pkg as
`source=Notarized Developer ID`. The notary profile is made once per Mac with
`xcrun notarytool store-credentials <profile>`.

## Status

Under construction. Nothing here is released yet.
