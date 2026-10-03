# Releasing

A release is published by pushing its tag, once `CHANGELOG.md` has its section:

```sh
git tag v$(scripts/version --base) && git push origin v$(scripts/version --base)
```

`.github/workflows/release.yml` checks that the tag is `VERSION`'s, that the tagged
commit is on master (a `-tag` pre-release may come from any branch), and that
`CHANGELOG.md` has a `## [<version>]` section. It then runs `scripts/release` in a
keychain `scripts/release-keychain` makes for the job and deletes at its end. Once the
pkg is notarized it requires the tagged commit's `vhid`, `eyes` and `pkg` checks to be
green, waiting for any still running, so a tag pushed right after its merge builds while
CI tests it. Then it attaches the pkg to a GitHub Release whose notes are that section,
marked a pre-release when the version has a `-tag`, and for a release moves the tap's
cask (below). The job reads secrets of the `release` environment, which admits only
`v*` tags and waits for a maintainer to approve it in the Actions tab before handing
them over:

| Secret | What it holds |
| --- | --- |
| `DEVELOPER_ID_APPLICATION_P12` | the Developer ID Application certificate and private key, as a base64 .p12 |
| `DEVELOPER_ID_INSTALLER_P12` | the Developer ID Installer certificate and private key, as a base64 .p12 |
| `DEVELOPER_ID_P12_PASSWORD` | the password both .p12 files were exported with |
| `NOTARY_APPLE_ID` | the Apple ID notarytool submits as |
| `NOTARY_PASSWORD` | an app-specific password for that Apple ID, made at account.apple.com |
| `TAP_APP_PRIVATE_KEY` | a private key of the promptctl tap App, as the .pem GitHub gives |

and the environment's variable `TAP_APP_CLIENT_ID` holds that App's client ID.

Export each identity from Keychain Access (the certificate with its private key, as
.p12, both with one password) on the Mac that holds it, then set the secrets from the
files. The files are redirected in because Homebrew's `base64` has no `-i`:

```sh
base64 <application.p12 | gh secret set DEVELOPER_ID_APPLICATION_P12 --env release
base64 <installer.p12 | gh secret set DEVELOPER_ID_INSTALLER_P12 --env release
```

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

## The cask

The cask in [promptctl/homebrew-tap](https://github.com/promptctl/homebrew-tap) names
one version and its pkg's sha256, so each release moves it. The tap's `vhid` workflow
moves it, running `.github/workflows/cask.yml` from this repository: it finds vhid's
newest release (the highest version that is not a draft or a pre-release, which a version
with a `-tag` is), fetches its pkg through the cask's own URL, and runs
`scripts/update-cask` on the tap and pushes, once `scripts/assess-pkg` has found the pkg
notarized and signed by the team. The write is the tap's own token. A run that finds the
cask current changes nothing.

Once a release is published, `release.yml` starts that workflow and waits until the cask
is at the release, failing when the run ends with the cask short of it or ten minutes
pass. The cask is the verdict, not the run: a run the tap's concurrency group cancels
leaves the cask to the run that replaced it. A workflow GitHub disabled after 60 days of
a quiet tap is enabled again; one disabled by hand fails the step. The Release is public
by then, so re-running the job would only fail at publishing; `gh workflow run vhid.yml
--repo promptctl/homebrew-tap` moves the cask instead, and the tap's own half-hourly
schedule runs the same workflow. `release.yml` starts it with a token of the promptctl
tap App, a GitHub App owned by the org and installed on the tap alone with Actions:
write, so the token can start the tap's workflows and nothing else. The token is minted
before the build, so a missing App fails the release before anything is published.
The App is made once, at github.com/organizations/promptctl/settings/apps, with no
webhook, then installed on promptctl/homebrew-tap; its client ID and a private key go to
the `release` environment:

```sh
gh variable set TAP_APP_CLIENT_ID --env release --body <client ID>
gh secret set TAP_APP_PRIVATE_KEY --env release <promptctl-tap.private-key.pem
```

A release made on a Mac reaches the cask once it is published on GitHub, with
`--prerelease` added for a `-tag` version as the workflow adds it, and the tap's
workflow is run:

```sh
gh release create v<version> dist/vhid-<version>.pkg --verify-tag --notes-file <its CHANGELOG section>
gh workflow run vhid.yml --repo promptctl/homebrew-tap
```

`scripts/update-cask` moves the cask only forward, and only to a release: an older
version, or one with a `-tag`, is refused and the tap left as it was. A pkg whose sha256
no longer matches the cask on its own version is refused too, and fails every run until
someone looks.

A release that also changes the cask's body has to move the cask by hand, in one commit.
The workflow moves only `version` and `sha256`. Brew keeps the caskfile an install or
upgrade was made with, and uninstalls and zaps by it, so anyone who upgrades between the
workflow's bump and the body change keeps the old body until the next version. Disable
the workflow before pushing the tag:

```sh
gh workflow disable vhid.yml --repo promptctl/homebrew-tap
```

Once the release is published, fetch its pkg, hold it to `scripts/assess-pkg`, and run
`scripts/update-cask <tap checkout> <version> <pkg>` on the tap branch that carries the
body change. The release fails at its cask step, since the workflow it starts is
disabled. Merge the tap branch, then enable the workflow again; its next run finds the
cask current:

```sh
gh workflow enable vhid.yml --repo promptctl/homebrew-tap
```
