# Releasing and maintaining EVA

**Goal:** understand the release inputs, execute a controlled rehearsal, verify
the exported products, and respond to a bad release. This runbook describes the
checked-in [release script](../../scripts/release.sh); it does not record a
successful notarization. Credential-dependent release acceptance remains an
explicit item in [guide validation](guide-validation.md).

## Local development and distribution are different builds

Use [setup](setup.md) for a local Debug run. A compile-only build with
`CODE_SIGNING_ALLOWED=NO` cannot verify distribution signing, entitlements,
notarization, or installation. The release script archives Release configuration,
exports with [`exportOptions-developerid.plist`](../../exportOptions-developerid.plist),
uploads a ZIP to Apple's notary service, staples the app, and checks Gatekeeper.
Do not run it as a shortcut for diagnosing a failed local build.

The script defaults to scheme `EVA`; it also accepts `EVAResolve`. It contains
team ID `7V8RRF84QH` and Keychain profile name `eva-notary`. A different team's
distribution needs consistent project/export/script settings and identifiers,
not just changing one command argument.

## 1. Prepare a release candidate

Record the exact commit, branch, version/build numbers, Xcode/macOS versions,
and planned artifact names. Review `git status --short` and do not accidentally
ship local tutorial patches or unrelated experiments. Rehearse from the intended
release checkout after the relevant tests and documentation checks pass.

Search version settings rather than assuming all targets share one constant:

```sh
rg -n 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' EVA.xcodeproj/project.pbxproj
git status --short
./run-all-tests.sh --list
python3 scripts/check-developer-docs.py
python3 scripts/sync-planning-docs.py --check
```

Choose the new version/build according to the release decision; update intended
app/embedded-target configurations consistently and inspect the built bundle's
Info.plist afterward. Review saved-file compatibility using
[the compatibility playbook](compatibility.md). Document scientific behavior
changes, migration requirements, known limitations, and the tests actually run.
Use `run-all-tests.sh` and relevant Resolve/UI/backend checks; `--fast` is not
evidence that app unit tests passed.

## 2. Check credentials and understand side effects

A valid **Developer ID Application certificate plus its private key** must be
available for the configured team. Notary-service credentials are separate.
The script checks signing identities and queries the `eva-notary` profile before
archiving. A certificate without its private key cannot sign an export.

```sh
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile eva-notary
```

The second command contacts Apple's service. Set up the profile through the
authorized release maintainer's credential workflow; keep passwords and private
keys out of scripts, Git, screenshots, and shared logs. Do not copy another
developer's identity to make a local tutorial build work.

**Outputs overwritten by the release script:** `build/<scheme>.xcarchive` and
the entire shared `build/export/` directory are removed before archiving. An
EVAResolve run therefore also replaces exports from a preceding EVA run. Move
artifacts you intend to retain to a separate release directory first. The script
uses `-allowProvisioningUpdates` and uploads the resulting ZIP for notarization;
those are real external operations, not a dry run.

## 3. Run the authorized release

From the checkout root, for the intended product:

```sh
scripts/release.sh EVA
# Or, as a separate release after preserving the first product's artifacts:
# scripts/release.sh EVAResolve
```

Expected checkpoints:

| Step | Expected evidence / artifact |
| --- | --- |
| Signing/profile preflight | Valid team signing identity and accessible notary profile. |
| Archive | Successful Release archive at `build/EVA.xcarchive` (or Resolve equivalent). |
| Export | Signed `build/export/EVA.app`. |
| ZIP and submit | `build/export/EVA.app.zip`; notary submission accepted. Retain submission ID/result. |
| Staple | Ticket attached to the exported app. |
| Gatekeeper | `spctl -a -vv` accepts that app; script reports completion. |

Read the first failed step. A notarization failure does not imply the Swift
compiler failed, and a successful archive does not imply notarization succeeded.
Use the submission ID with `notarytool info`/`log` when diagnosing a rejected
submission; keep sensitive log content within the release workflow.

The script creates its ZIP **before** stapling the app. If distributing a ZIP
with the stapled app inside, create a fresh ZIP after the script succeeds and
verify the extracted copy. Do not assume the pre-submission ZIP was updated.
For example, using a fresh release-output name:

```sh
ditto -c -k --keepParent build/export/EVA.app build/EVA-stapled.app.zip
shasum -a 256 build/EVA-stapled.app.zip
```

Record the checksum and avoid overwriting an already published artifact with a
different binary under the same version/name.

## 4. Verify the actual distribution product

Use the exported app, not an older installed copy or the Debug app in DerivedData.
Inspect and validate the product and embedded components:

```sh
plutil -p build/export/EVA.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 build/export/EVA.app
xcrun stapler validate build/export/EVA.app
spctl -a -vv build/export/EVA.app
ls build/export/EVA.app/Contents/PlugIns
build/export/EVA.app/Contents/MacOS/EVASimulate --help
```

Check the embedded `EVAQuickLook.appex`, `EVAThumbnail.appex`, and EVASimulate
product against the Xcode embed phases. Inspect signing/entitlements if an
extension or file-open operation fails. Resolve has different product contents;
do not require EVA's embedded simulator/extensions in the Resolve app.

Smoke-test opening the synthetic clean/noisy recordings, a filter, undo/history,
export and reopen, saved-script replay, a small batch, and closing during work.
Exercise a GPU path on supported hardware. Test Finder preview/thumbnail from
the installed candidate, since building an extension is not proof Finder is
using that version. Rehearse Resolve's head-model import/coregistration/export
when releasing Resolve. Record input files/settings and results, not just “looks OK.”

For a ZIP distribution, extract it into a fresh location and repeat signature,
stapler, Gatekeeper, and launch checks on the extracted app. Installation/download
behavior should also be checked on an appropriate separate account or machine.

## 5. Publish and retain evidence

The release script prepares an app; it does not create a GitHub release, upload
public assets there, update every announcement, or run the smoke tests above.
Publication is a separate maintainer action. Retain the commit/tag, versions,
archive, export options, toolchain versions, notarization result, checksums,
compatibility notes, test results and manual smoke-test record with the release.
Use [documentation maintenance](documentation-maintenance.md) to validate the
site; site deployment and application distribution are separate workflows.

## If a release is faulty

Reproduce against its exact commit/binary and record affected inputs/workflows.
Determine whether previously exported data or scientific results may be affected.
Stop recommending the affected artifact, communicate the scope and workaround,
and preserve its identity/checksum for diagnosis. Prepare a new version/build
with a regression test and compatibility assessment. Do not silently replace a
published ZIP or rewrite the meaning of an old saved script.

A previous app may not understand files produced by the newer one. Assess that
before advising a downgrade; preserve original data and export to new paths.
Document whether affected processing must be rerun and which metadata identifies
it. Follow the project's release channels for user-facing communication.

## Routine upkeep

When moving shared code, check Xcode membership and standalone CLI source lists.
When updating algorithms or dependencies, review
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md),
[provenance notes](../provenance/README.md), reference fixtures, and numerical
tolerances. Preserve the NIH source header. Keep generated/local research data
and dependency copies out of commits according to `.gitignore` and provenance
instructions. Update the feature map, subsystem explanations, inventory,
tutorial patches and validation dates when their source paths/contracts change.

**Rehearsal record:** fill the release section of
[newcomer/maintainer acceptance](acceptance-walkthrough.md). Until a maintainer
executes the signed archive/export/notarize/install sequence, label it unverified.
