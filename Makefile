# The dev loop. `make` builds and signs; `make test` runs the suite and leaves the tree
# signed behind it.
#
# Everything here exists because of one rule in the daemon: a caller is admitted if it
# carries the certificate the daemon itself carries, and refused otherwise as
# NSCocoaErrorDomain 4097. SwiftPM ad hoc signs every product it links, and an ad hoc
# signature names a hash that changes with the binary, so a plain `swift build` leaves
# two programs that cannot recognise each other and an error that reads like broken XPC.

# [LAW:one-source-of-truth] The name of the dev identity, and the only place it is
# written. The scripts take it as an argument rather than knowing it, so nothing can
# come to be signed with one certificate and checked against another.
DEV_IDENTITY := vhid Dev

# Every recipe runs under pipefail, so a pipeline reports the failure of any stage and
# not merely of its last one. The signing line below is a pipeline, and its first stage
# is the one that knows whether there is anything to sign at all.
SHELL := /bin/sh
.SHELLFLAGS := -o pipefail -c

# [LAW:single-enforcer] The one definition of what signing is, used by the three targets
# below. Written out rather than reached through a recursive `$(MAKE) sign`, because GNU
# make runs any recipe line mentioning $(MAKE) even under -n: `make -n test` would build,
# test and re-sign while claiming to be a dry run.
#
# What to sign is asked of the package rather than listed here, so an executable added
# to Package.swift is signed by the next build and not by the next person to remember.
#
# Handed over NUL-separated rather than as one string the shell splits on whitespace: a
# checkout under a path with a space in it - `~/code/my repo/vhid` - would otherwise be
# torn into fragments and every build would die on a binary that was never named. The
# emptiness case is covered by `scripts/products` itself failing, which pipefail then
# reports: macOS xargs runs nothing at all on empty input and exits 0, so without that
# this line would sign nothing and call it success. [LAW:no-silent-failure]
SIGN := scripts/products | tr '\n' '\0' | xargs -0 scripts/sign "$(DEV_IDENTITY)"

.PHONY: all build test sign signing-identity clean

all: build

# Signing is a step of the build and not a thing to remember afterwards, and the
# identity is a prerequisite of both, so a fresh clone on a Mac that has never built
# vhid needs no step this file does not already take. [LAW:dataflow-not-control-flow]
build: signing-identity
	swift build
	$(SIGN)

# `swift build` first and on its own line, for two reasons. It builds executables no
# test depends on, which `swift test` would leave unbuilt for `sign` to fail on; and a
# build that fails is a failure the operator has to deal with before anything here
# matters, so stopping on it reports the thing that actually went wrong.
#
# Signing last is what makes a test run safe to leave behind: every link SwiftPM
# performs ad hoc signs its product - measured, a relink turns `Authority=vhid Dev` back
# into `Signature=adhoc` - so without this a run leaves the next invocation refused, a
# failure that reported success. [LAW:no-silent-failure]
#
# It signs whether or not the tests passed, and hands the suite's own status back
# afterwards. A failing run is the run whose binaries someone is about to go and try by
# hand, so leaving those ad hoc would answer a test failure with a 4097 that has nothing
# to do with it. Signing's own failure is passed on first and not folded into the
# suite's: `$(SIGN)` followed by a bare `exit $$status` would discard a failed signing
# whenever the tests passed, reporting success over exactly the unsigned tree this
# target exists to prevent.
test: signing-identity
	swift build
	swift test; status=$$?; $(SIGN) || exit $$?; exit $$status

# Also the fix for a tree someone has built with bare `swift build`.
sign:
	$(SIGN)

# Idempotent, which is why the targets above can simply depend on it. Once per Mac in
# practice; a no-op every time after that.
signing-identity:
	scripts/make-signing-identity "$(DEV_IDENTITY)"

# The build tree only. The identity is per-Mac rather than per-checkout and survives on
# purpose - a permission macOS granted this certificate is granted to the certificate,
# and deleting it would throw those away. README.md says how to remove it deliberately.
clean:
	/bin/rm -rf .build
