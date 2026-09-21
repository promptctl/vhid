# The dev loop. `make` builds and signs; `make test` builds, tests and leaves the tree
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

# Everything a caller or the daemon runs as. One list, because the rule they have to
# satisfy is about the pair: the daemon admits the CLI exactly when both carry this
# certificate, so a product left off this line is a product that gets the afternoon of
# 4097. The CLI joins it in vhid-cli-yhu.
BUILT := .build/debug
PRODUCTS := $(BUILT)/vhidd

.PHONY: all build test sign signing-identity clean

all: build

# Signing is a step of the build and not a thing to remember afterwards, and the
# identity is a prerequisite of both, so a fresh clone on a Mac that has never built
# vhid needs no step this file does not already take. [LAW:dataflow-not-control-flow]
build: signing-identity
	swift build
	$(MAKE) sign

# Signing last is what makes a test run safe to leave behind: `swift test` relinks, and
# every relink drops the identity again, so without this a green run leaves the next
# invocation refused - a failure that reported success. [LAW:no-silent-failure]
test: signing-identity
	swift build
	swift test
	$(MAKE) sign

# [LAW:single-enforcer] The one place products are signed. `make sign` on its own is
# also the fix for a tree someone has built with bare `swift build`.
sign:
	scripts/sign "$(DEV_IDENTITY)" $(PRODUCTS)

# Idempotent, which is why the targets above can simply depend on it. Once per Mac in
# practice; a no-op every time after that.
signing-identity:
	scripts/make-signing-identity "$(DEV_IDENTITY)"

# The build tree only. The identity is per-Mac rather than per-checkout and survives on
# purpose - a permission macOS granted this certificate is granted to the certificate,
# and deleting it would throw those away. README.md says how to remove it deliberately.
clean:
	/bin/rm -rf .build
