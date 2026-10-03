# Releasing

A release is published by pushing its tag, once `CHANGELOG.md` has its section:

```sh
git tag v$(scripts/version --base) && git push origin v$(scripts/version --base)
```

`.github/workflows/release.yml` checks that the tag is `VERSION`'s, that the tagged
commit is on master (a `-tag` pre-release may come from any branch) with its `vhid`,
`eyes` and `pkg` checks green, and that `CHANGELOG.md` has a `## [<version>]` section.
It then runs `scripts/release` in a keychain `scripts/release-keychain` makes for the
job and deletes at its end, and attaches the notarized pkg to a GitHub Release whose
notes are that section, marked a pre-release when the version has a `-tag`. A release
that is not a pre-release then moves the cask in
[promptctl/homebrew-tap](https://github.com/promptctl/homebrew-tap) to it:
`scripts/update-cask` sets the cask's version, and its sha256 to that of the pkg
fetched from the cask's own URL, and the job commits that to the tap and pushes it.
Both jobs read secrets of the `release` environment, which admits only `v*` tags and
waits for a maintainer to approve each job in the Actions tab before handing them over,
so a release asks for two approvals:

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12` | the Developer ID Application certificate and private key, as a base64 .p12 |
| `DEVELOPER_ID_INSTALLER_P12` | the Developer ID Installer certificate and private key, as a base64 .p12 |
| `DEVELOPER_ID_P12_PASSWORD` | the password both .p12 files were exported with |
| `NOTARY_APPLE_ID` | the Apple ID notarytool submits as |
| `NOTARY_PASSWORD` | an app-specific password for that Apple ID, made at account.apple.com |
| `HOMEBREW_TAP_DEPLOY_KEY` | the private half of an SSH deploy key with write access to promptctl/homebrew-tap |

Export each identity from Keychain Access (the certificate with its private key, as
.p12, both with one password) on the Mac that holds it, then set the secrets from the
files. The files are redirected in because Homebrew's `base64` has no `-i`:

```sh
base64 <application.p12 | gh secret set DEVELOPER_ID_APPLICATION_P12 --env release
base64 <installer.p12 | gh secret set DEVELOPER_ID_INSTALLER_P12 --env release
```

The deploy key is made once, its public half given to the tap and its private half to
the environment:

```sh
ssh-keygen -t ed25519 -N '' -f tap-key
gh repo deploy-key add tap-key.pub --repo promptctl/homebrew-tap --allow-write --title release.yml
gh secret set HOMEBREW_TAP_DEPLOY_KEY --env release <tap-key && rm tap-key tap-key.pub
```

If the cask job fails after the Release is published, re-running that job alone moves
the cask without publishing again. When the job never ran (the release job failed
after publishing, or the release was made on a Mac as below), the cask is moved by
hand, from a clone of the tap, with the pkg as published:

```sh
gh release download v<version> --repo promptctl/vhid --pattern 'vhid-<version>.pkg' --dir /tmp
scripts/update-cask <tap clone> <version> /tmp/vhid-<version>.pkg && git -C <tap clone> push
```

`scripts/update-cask` moves the cask only forward, and only to a release: an older
version, or one with a `-tag`, is refused and the tap left as it was.

The same release can be made on that Mac directly:

```sh
NOTARY_PROFILE=<profile> scripts/release dist    # dist/vhid-<version>.pkg
```

The version is the one in `VERSION`, and a release is built from the commit tagged
`v<version>` with `git status` clean: any other build reports `<version>-dev+<commit>`
from `vhid --version`, and `scripts/make-pkg` refuses to package it.

That runs two scripts, and each can also be run on its own:

```sh
scripts/make-pkg dist                                   # built and signed
NOTARY_PROFILE=<profile> scripts/notarize dist/vhid-<version>.pkg   # notarized and stapled
```

`scripts/make-pkg --unsigned dist` does all of it but the signing, from any tree, and
names the result `vhid-<version>-unsigned.pkg`; `scripts/check-pkg` then holds what it
installs to what make-pkg states. CI's `pkg` job runs both on every PR.

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
