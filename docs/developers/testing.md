# Testing EVA: choose, run, and interpret checks

Comments must describe the code that exists. A comment-only change needs a contract review, not a new test that repeats the implementation. Moving declarations or extracting functions needs compilation and relevant existing behavioral tests.

New to running tests in Xcode? Start with the
[first-change tutorial](first-change.md), which runs one suite and walks through
an intentional failure. Use [debugging](debugging.md) for assertion, concurrency,
cancellation, and numerical investigations. Find suites with the
[feature map](features.md), then inspect their inputs and availability guards.

## Commands and target coverage

```sh
# Inventory the repository runner's stages without executing them.
./run-all-tests.sh --list

# App unit suite; this also builds the embedded simulator and Finder extensions.
xcodebuild test -project EVA.xcodeproj -scheme EVA \
  -destination 'platform=macOS' -only-testing:EVATests

# Companion application tests.
xcodebuild test -project EVA.xcodeproj -scheme EVAResolve \
  -destination 'platform=macOS' -only-testing:EVAResolveTests

# Full CLI builds, model checks, determinism checks and app unit suite.
./run-all-tests.sh
```

`--fast` skips the Xcode unit suite **and generation of the regression corpus**; it is not a fast version of that suite. The repository runner excludes UI automation. Run `EVAUITests` separately for UI changes and inspect the affected screen when needed. Xcode signing and test-host permissions must be valid on the machine running the tests.

The standalone `Tools/EVABIDS`, `Tools/EVAHelper`, `Tools/EVAGradient` and `Tools/mffTimingTool` build scripts have their own source lists. A successful app build does not prove those lists are complete.

## Match the check to the change

| Change | Existing evidence to preserve |
| --- | --- |
| Channel/statistics contracts | `SignalSelectionTests`, `SignalStatisticsTests`, `HealthScoringTests` |
| Pipeline sequencing/state ownership | ProcessingCore, invalidation, snapshot, replay and paired-validation tests |
| Numerical organization | Subsystem tests plus reference/parity tests; preserve arithmetic and random draw order |
| Reader/model separation | Format reader and round-trip tests, preview/Resolve builds and standalone CLI builds |
| Simulator organization | Embedded `EVASimulate selftest`, scenario generation and `scripts/check-determinism.sh` |
| View decomposition | Relevant layout/render tests and UI workflows: bindings, focus, open/close, cancellation and scrolling |

## Reading scientific fixtures

A useful fixture comment states what is planted in the input, the expected physical/statistical property, the reference implementation or generator, the seed, and why its tolerance is appropriate. A byte-for-byte expectation and a floating-point tolerance protect different contracts. Do not relax tolerances or regenerate reference values merely to make a refactor pass.

`EVATests/Fixtures.swift` resolves data from the checkout using `#filePath`; its helper deliberately does not require copying the data into a test bundle. MFF fixtures are directories containing identically named internal files. They must not be flattened into bundle resources. Swift fixture helpers still compile into the test target.

Start with `SignalSelectionTests` as a small executable example. Read `LatestOnlyRunnerTests` next for deterministic task interleavings. The gate in that suite makes scheduling explicit; timing sleeps would make the expected ordering probabilistic.

## Run one suite and keep the evidence

A **suite** groups related tests. In Xcode, choose the EVA scheme and My Mac,
open the Test navigator (Command-6), and run the selected suite or individual
method. Product → Test can run all enabled test bundles, including UI tests.
The test filter below selects one suite but does not eliminate host-app build
requirements.

```sh
EVA_TEST_RUN="$(mktemp -d "${TMPDIR:-/tmp}/eva-test-run.XXXXXX")"
xcodebuild test -project EVA.xcodeproj -scheme EVA \
  -destination 'platform=macOS' -derivedDataPath build/onboarding \
  -resultBundlePath "$EVA_TEST_RUN/Selection.xcresult" \
  -only-testing:EVATests/SignalSelectionTests
open "$EVA_TEST_RUN/Selection.xcresult"
```

The result-bundle path must not already contain a previous bundle. Read the test
count, failures, and skipped tests, not only the process exit code. Swift Testing
output can appear after an XCTest host reports zero XCTest tests; find the
actual Swift Testing summary. An expected empty selection is not evidence that
your intended tests passed.

For Resolve use the shared `EVAResolve` scheme and `EVAResolveTests` bundle.
For UI automation select `-only-testing:EVAUITests` on the EVA scheme. UI tests
need permission to control the test app and an appropriate interactive desktop;
a headless CPU test run does not replace that check.

## Swift Testing and XCTest

Most newer unit suites use `import Testing`, a struct, `@Test`, and `#expect`.
Use `try #require` for a prerequisite whose absence should stop that test before
unsafe indexing. A throwing test uses `throws`; an asynchronous test uses
`async`. `@MainActor` means model/UI access is actor-isolated, not that every
function it awaits runs on a worker thread. Parameterized tests use
`@Test(arguments:)`; distinguish the method count from argument-case count.

XCTest suites derive from `XCTestCase`, use `test...` methods and `XCTAssert...`,
and provide the UI automation APIs used by `EVAUITests`. Follow the surrounding
suite's framework. Do not mechanically translate assertions or introduce a
second framework to test one helper. Use the [first-change example](first-change.md)
for Swift Testing syntax and the [debugging exercises](debugging.md) for failure
interpretation.

## Fixture availability and numerical meaning

Inspect each fixture helper. Some tests resolve repository paths using
`#filePath`; copying the test source to another directory changes that lookup.
MFF is a package containing several files with common names, not a single flat
resource. Maintain its directory structure. Tests using ignored local reference
material can skip when that material is absent; record that coverage gap.
`PipelineRegressionTests` uses the generated `.regression-corpus`; the full
runner regenerates that ignored directory and removes its prior contents.

When constructing synthetic data, record channel/sample dimensions, units,
sampling rate, timeline, seed, and why the expected answer is known. Prefer a
small analytic case for a helper and a realistic reference fixture for a whole
pipeline. Use exact equality for identity/copy/serialization rules when justified;
use documented tolerances for numerical algorithms. CPU/GPU parity and agreement
with an external reference answer different questions and both may be needed.
Do not mark a device-dependent suite verified when its availability guard skipped it.

## How much to run

Start with the changed behavior's focused suite, then the affected integration
boundary. A reader change warrants malformed-input and export/reimport tests;
a persisted setting warrants non-default and absent-key round trips, restored
computation, history and batch checks where applicable. Shared source changes
also require consuming products/CLI source lists to compile. The full repository
runner does not run Resolve tests or UI automation for you.

For documentation-only work, run the developer-doc checker, patch applicability
checks, script tests, synchronization and strict site build described in
[documentation maintenance](documentation-maintenance.md). Compile/run a tutorial
example when its code changes. Existing app tests need not be rerun for every
prose edit. Keep environment blockers separate from assertion failures and state
which checks were actually executed in [guide validation](guide-validation.md).
