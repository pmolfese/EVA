# Onboarding validation record

Date: 2026-11-07. Applies to [M1](onboarding-milestones.md#m1--first-successful-change),
[setup](setup.md), and [the first-change tutorial](first-change.md).

**Status:** M1's chapters are written and the tutorial example has been exercised.
Full first-day acceptance remains open: this environment cannot currently
compile the app's Metal shader, and no clean-checkout GUI/debugger walkthrough
has been completed. The existing working checkout contains earlier comment
changes; it is not a clean-checkout acceptance environment.

## Environment observed

| Item | Value |
| --- | --- |
| Hardware architecture | `arm64` |
| Host macOS | 26.7.2 |
| Selected developer directory | `/Applications/Xcode.app/Contents/Developer` |
| Xcode | 27.2, build 27B52 |
| Swift compiler | Apple Swift 6.4.2 (`swiftlang-6.4.2.1.9`) |
| Project deployment target / language mode | macOS 15.0 / Swift 5.0 |
| Metal compiler component | Unavailable to the selected Xcode during validation |

These are observed versions, not a certified minimum supported development
environment. The deployment target describes where a built app may run, not
which compiler can build its source.

## Checks performed

| Check | Result | Scope / limitation |
| --- | --- | --- |
| Project targets, schemes, shared groups, model ownership | Reviewed against `project.pbxproj`, shared scheme XML, `MFFRecording`, `RecordingStore`, and `EVAApp` | Corrected the architecture and setup descriptions; not a full source-inventory audit. |
| Normal `EVA` Debug app build, fresh temporary derived-data directory, signing disabled | **Blocked:** `cannot execute tool 'metal' due to missing Metal Toolchain` at `WaveletKernels.metal` | Build retried with compiler plugins allowed outside the execution sandbox. This is not a demonstrated Swift source regression or a successful full-app build. |
| Normal project, focused `SignalSelectionTests`, signing disabled | **Blocked before tests:** same missing Metal component | The normal-project tutorial command has not passed here. |
| Standalone `EVASimulate` Release target build | **Passed** | Fresh temporary product/object directories, signing disabled; independent of the app's Metal shader. |
| Generate eight channels, 1,000 Hz, ten seconds, seed 42 | **Passed** | Produced `sim_clean.mff`, `sim_noisy.mff`, and `sim_truth.json`; generation reported eight channels and ten seconds. |
| Read generated clean MFF through simulator scoring against itself | **Passed** | Reported zero RMSE and correlation 1.0. This checks generation/readback, not GUI opening or algorithm accuracy. |
| Existing selection suite in isolated validation project | **Passed: 4 tests** | Real production code, temporary project/test sources; scope explained below. |
| Exact new Swift method extracted from the tutorial | **Passed: 5 tests** | Added to a temporary copy of the test file; repository test file unchanged. |
| Temporarily expect retained start 114 instead of 105 | **Failed as intended: 1 issue in 5 tests** | Failure identified `mergeWindowFollowsStrongerRepresentative` and its start assertion. |
| Restore retained start expectation to 105 | **Passed: 5 tests** | Final temporary test copy matches the documented correct method. |
| Relative documentation links and new in-repository section anchors | **Passed** | Existing machine-specific scorecard links remain scheduled for M6; external URLs were not checked. |
| Source/project preservation and whitespace | **Passed** | Source/project hashes match the start of M1; `git diff --check` passes. No new production or test-source edits. |

## What the isolated test validation means

The test experiment used a temporary copy of the Xcode project already prepared
for CPU-focused checks during the comment review. It compiles the current real
EVA source, uses a copy of the Swift test sources, excludes non-Swift fixture
resources from the test target, and excludes `.metal` files for this narrowly
CPU-only suite. It uses `CODE_SIGNING_ALLOWED=NO` and an existing temporary
derived-data directory. The suite does not exercise a Metal backend or depend
on those fixture resources. The tutorial's method was extracted from its Swift
code block rather than independently retyped.

This validates the example and its failure/pass cycle. It does **not** validate
the normal target/resource configuration, signed app launch, GPU behavior,
Finder extensions, the whole test suite, or a clean checkout. Do not transfer
these project exclusions into the normal onboarding instructions as a build fix.

The terminal validation substituted temporary output directories for the
guide's ignored `build/` directory. Logs from this run are local, temporary
artifacts under `/tmp/eva-onboarding-validation`, with app and simulator build
logs at `/tmp/eva-onboarding-app-build.log` and
`/tmp/eva-onboarding-simulator-build.log`. They are not required inputs to the
guide and are not durable repository artifacts; the results above are the
retained record.

## Remaining M1 acceptance

1. On a normally configured development machine with Metal available, use a
   clean checkout and follow setup exactly. Record Xcode/macOS versions,
   signing configuration, command outputs, and any extra steps needed.
2. Build and run the normal EVA scheme, open both generated MFF packages, and
   verify the channel/traces/duration checkpoints. Confirm no special project
   exclusions were required.
3. Complete the original → added passing test → intentional failure → restored
   passing test sequence with the normal project. Exercise the breakpoint and
   variable inspection in Xcode.
4. Have a developer unfamiliar with EVA explain the test's behavior and review
   the diff using only the guide. Update any step that required outside help.
5. Add the outcomes to this record and close M1's remaining gates only after
   those checks pass. The broader extension/maintenance acceptance comes in M6.

## Structural changes in M1

- Added this validation record, the milestone plan, the setup chapter, and the
  first-change tutorial under `docs/developers/`.
- Reorganized the developer index into a learning path and reference links;
  linked it from the root README and the project roadmap.
- Corrected existing architecture and subsystem guidance and added cross-links.
- **No application structure, source declarations, algorithms, project settings,
  or repository test files changed in this stage.**
