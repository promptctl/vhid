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

## The CLI

```sh
vhid type "hello"
vhid keys leftCommand+s
vhid click 800 500 --button left --times 2
vhid pointer play < script.jsonl
```

It types where the keyboard is pointed and clicks where it is told. There is no
click-by-element and no target app, because nothing in vhid reads the screen — what is
under a point is the caller's to know.

Which keys make which characters is the console user's keyboard layout, read in the CLI
rather than in the daemon: macOS answers that question per process, and a root daemon
asking it is told the US layout whatever the user is typing on.

`--service` says which installation to talk to, defaulting to the copy built from this
tree. Coordinates are screen points from the top left of the main display; a display
left of or above it has negative ones, which follow `--`.

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

## Status

Under construction. Nothing here is released yet.
