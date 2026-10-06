# Developing vhid

How the repository is laid out, what belongs in it, and how to build and test it. For how the pieces fit together, see [architecture.md](architecture.md); for publishing a release, see [releasing.md](releasing.md).

## From a fresh clone

You need Xcode 26. CI builds with the version [test.yaml](../.github/workflows/test.yaml)
names, so that one is known to work.

```sh
git clone https://github.com/promptctl/vhid.git
cd vhid
make test                              # build, sign, and test vhid
(cd eyes && swift build && swift test) # eyes is a separate package with its own tests
make dev-daemon                        # optional: run the daemon this tree builds (asks for sudo)
```

Pull requests go to `master` and must pass the `vhid`, `eyes` and `pkg` checks.

## Two packages

The repository holds two SwiftPM packages, and the root manifest deliberately does not
mention the second one.

| | what it is | build and test |
|---|---|---|
| `.` | the devices: the keyboard, the mouse, and the root daemon that owns them | `make test` |
| `eyes/` | reading the screen: where the windows are, and where text is, as the points `vhid click` takes | `cd eyes && swift build && swift test` |

`eyes` finds a coordinate; `vhid click` presses it. Nothing joins them in code — only that
workflow. A target in the root manifest would be one `dependencies:` line away from
linking the two, and nothing in review catches that line, so the separation is a package
boundary rather than a rule someone has to remember.

The cost of that isolation is this paragraph: `make test` at the root does not run
`eyes`' tests.

## Scope

vhid's core is input that macOS sees as hardware, from a virtual keyboard and mouse;
its sibling package `eyes` reads the screen so that input can be aimed. A feature that
works through the devices fits naturally. A feature that reaches around them — the
clipboard, posting synthetic events, app-specific APIs — belongs here only when the case
for it is overwhelmingly compelling, close to a requirement, *and* it would make no sense
as a separate project.

## Building

`make` builds and signs. `make test` runs the suite and leaves the tree signed behind
it.

Use those rather than `swift build` and `swift test` directly, because of one rule in
the daemon: it admits a caller carrying the certificate it carries itself, and refuses
everything else. SwiftPM ad hoc signs every product it links, and an ad hoc signature
names a hash that changes with the binary, so it can neither be required of a caller nor
satisfied by one. A tree built with bare `swift build` therefore gets
`NSCocoaErrorDomain 4097` on the first call. vhid says the daemon ended the connection
and names the signature as the likely cause, because XPC itself reports only a
connection that failed. `make sign` repairs a tree that has been built
that way.

A build talks to the development daemon, `ai.promptctl.vhid.vhidd.dev`, and nothing
answers it until launchd has a job for it. `make dev-daemon` builds, then registers
`.build/debug/vhidd` under that name, replacing the job an earlier run registered; it
asks for sudo. `make remove-dev-daemon` takes it out. Neither touches a job it did not
register, the installed pkg's included. Launchd runs that binary as root, from a tree
your own account can write to, until it is removed. A rebuild does not restart it. It
reads the cursor and the displays in a child of its own executable, and once the file
there is another build it starts no new child: the next time it needs one, when another
session comes to the front or a reader fails, the read is refused, saying the file was
replaced. `make dev-daemon` again restarts it on the new build.

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

## Tests that wait

A test that blocks its thread — on a timeout, a child process, a semaphore, a reply over
XPC — belongs to a suite marked `@Suite(.ownThread)`, from the `OwnThread` target:

```swift
import OwnThread

@Suite(.ownThread) struct ConnectionTests {
```

Swift runs test bodies on a pool with one thread for each core, and a blocked test keeps
the thread it was given. On CI's three cores, three such tests are the whole pool: the
rest of the suite stands still until they end, and a test waiting for something the pool
itself must run never ends. The trait gives each test of the suite a thread that is not
one of the pool's.

`make test` runs the suite with the pool one thread wide, so a test that needs the trait
and lacks it is slow or hung on any Mac, and not only on CI. `thePoolIsOneThreadWide`
fails on a wider pool, so a run that has lost the narrow one says so.

## Checking the reach matrix

The user guide's table of where input reaches over SSH ([guide.md](guide.md#where-the-input-reaches)) is measured, and [design/remote-hands.md](design/remote-hands.md) has the evidence for each cell. `scripts/reach <host> <place>` checks one row again on a real Mac; with no place, it lists what to put on screen for each.

## The site

[promptctl.github.io/vhid](https://promptctl.github.io/vhid/) is `site/` as committed, published by [pages.yaml](../.github/workflows/pages.yaml) on every push to `master`. The page repeats the README's install commands, and `scripts/check-site`, run by `make test`, fails when a block the page copies, a `<pre>` or an `<ol>`, is not a run of README.md's lines, whole and in order; change the README first and copy from it.

## Filming the demo

The clips in `site/demo/` are filmed by `scripts/film-demo site/demo/<name>.sh` on the Mac being filmed. The `.sh` beside each clip lists the commands it shows, and `film-demo` writes the clip and its `.steps.tsv`. Whatever runs `film-demo` needs Screen Recording for the capture, and Automation of System Events to hide every app but the one filmed; `record-play.sh` also needs Post Event for its stand-in person and Input Monitoring for `vhid-record.app`. Over SSH, all but the last are charged to `/usr/libexec/sshd-keygen-wrapper`. `vhid record` leaves vhid's own input out, so vhid cannot play the person in `record-play.sh`; events posted through CoreGraphics do instead.
