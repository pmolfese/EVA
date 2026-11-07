# Debugging a failure without guessing

**Goal:** turn a reported problem into a small reproducible case, identify the
boundary that failed, and add a test that would have caught it. Complete
[the first-change tutorial](first-change.md) first. Keep [testing](testing.md)
open for commands and [data/lifecycle](data-and-lifecycle.md) for ownership rules.

## Collect a reproducible report

Write down the checkout commit and local changes, macOS/Xcode versions, scheme,
input source, exact settings, operation order, expected result, actual result,
and the first useful error. For synthetic inputs, keep the simulator seed and
resolved configuration. For real inputs, use an approved local fixture or a
de-identified minimal reproducer; do not add participant data to the repository.
Do not change several variables while trying to reproduce a failure.

Distinguish these layers before editing source:

| Where it stops | Evidence | First investigation |
| --- | --- | --- |
| Build planning / resource copy | `Multiple commands produce`, missing file/target | Target membership and fixture package structure. |
| Compiler / macro expansion | File/line compiler error, plugin launch diagnostic | Same toolchain in Xcode versus restricted runner; inspect the first compiler error. |
| Test host launch | No test discovery; signing, launch, or Metal-library error | App host and environment. A test filter can still build/launch the host. |
| Assertion | Test name plus expected/actual values | Reproduce that individual test with stable input. |
| UI behavior | Wrong window, stale values, stuck spinner | State owner, request/session identities, task outcome and focus. |
| Scientific output | Shape/order/unit or tolerance mismatch | Establish deterministic input and backend, then compare intermediate values. |

The missing Metal component recorded in [validation](onboarding-validation.md)
is an environment limitation. A temporary CPU-only experiment is useful evidence
about its selected code; it does not establish that the normal app launches.

## Investigation 1: an assertion fails

Use the deliberate `105` → `114` expectation change in the
[first-change exercise](first-change.md#4-prove-that-the-assertion-is-actually-running).
Run only `SignalSelectionTests`; find the failing method in Xcode's Test or Report
navigator. Read actual values before changing the expectation. Put a breakpoint
on the production replacement assignment, inspect `hit`, `last`, and `merged`,
and step through the comparison. Restore 105 only after explaining the rule.

A useful regression test distinguishes a correct implementation from a plausible
incorrect one. Here, keeping a window anchored at the first hit would produce
two detections. A test that merely repeats the production loop would be weaker.
For optional values, use `try #require(...)` in a throwing test before indexing,
or compare optional properties directly when that expresses the assertion.

## Investigation 2: an old result overwrites a new one

Open [`LatestOnlyRunnerTests`](../../EVATests/Pipeline/LatestOnlyRunnerTests.swift),
especially `supersededRunStandsDownAndNewestRunPublishes`. Follow this sequence:

1. A claims the runner and waits at `RunGate`.
2. The test waits until A's label is visible, then starts B.
3. B publishes `fresh`.
4. The gate releases A. A returns `stale`, but its outcome is `.superseded`.
5. The assertion accepts only `["fresh"]`.

Set breakpoints at the generation comparison in
[`LatestOnlyRunner.run`](../../EVA/Pipeline/LatestOnlyRunner.swift) and the
test's publication append. Inspect `thisGeneration`, `activeGeneration`, and
`activeLabel`. Do not infer identity from the label: identical repeated labels
are tested as distinct runs.

For a real feature, find its request identity and recording/session identity.
Log or inspect those along with the input `dataRevision`, configuration, and
outcome. Compare the IDs at launch and publication. Capturing `self` captures a
class reference; it does not freeze that class's settings. If results depend on
controls being moved mid-run, inspect request construction before the math.

**Regression approach:** gate the worker at the boundary you need to control,
start a successor, release the first worker, and assert both the published result
and ownership of status/progress. Avoid new timing sleeps as synchronization.

## Investigation 3: cancellation leaves a spinner running

Read `cancelledRunWithNoSuccessorReportsCancelled` and
`invalidateStopsAnInFlightRunFromPublishing` in the same suite. Then inspect the
feature's result switch or cancellation handler. The three outcomes mean:

- Completed and current: publish, then finish this run's status.
- Cancelled without a successor: finish this run's status without publishing.
- Superseded: leave successor-owned state alone.

Check every early return and error branch. A cancelled task may resume after an
`await`; clearing its handle does not prove its computation stopped. Closing a
recording should cancel work **and** revoke its right to publish into reused
state. Trace `WaveformView.tearDownRecordingSessionForClose` and model
`resetForClose` methods for that distinction.

Reproduce in the UI with a synthetic recording: start work, change inputs, then
close/reopen. Record which status indicator remains active and which window it
belongs to. Treat that as a manual acceptance check until an automated regression
captures the same ownership boundary; do not count a helper test as GUI coverage.

## Investigation 4: CPU and GPU disagree

Start with a fixed seed, short signal, explicit channel order, sample rate, and
fixed backend. Use the corresponding subsystem's parity tests, such as
[`GradientBackendParityTests`](../../EVATests/Gradient/GradientBackendParityTests.swift)
or [`LocalTemplateBackendParityTests`](../../EVATests/Gradient/LocalTemplateBackendParityTests.swift).
Read their device-availability guards: a skipped GPU comparison is not a pass.

Check shapes and units first, then intermediates: input selection, centering,
padding, transform normalization, accumulation precision, and output alignment.
For FFT-derived power, normalization and one-sided/two-sided conventions can
produce systematic factors even when every floating-point operation is correct.
For matrices, inspect whether storage is row-major or column-major and which
axis represents channels/components/samples before changing a multiplication.

Record maximum absolute error, a justified relative error for nonzero signals,
and a task-relevant quantity such as retained amplitude or timing. An expression
like `abs(actual - expected) <= absolute + relative * abs(expected)` needs
scientifically justified constants; it is not permission to widen them until a
test passes. Near zero, a relative error alone is unstable.

**Regression approach:** shrink to a deterministic input that still fails,
retain its expected convention/units, and test the intermediate contract as
well as the final result when useful. Do not regenerate an independent oracle
from the implementation under test or relax tolerances to conceal a changed
algorithm. Reference provenance belongs with the fixture.

## Logs and result bundles

[`DebugLog`](../../EVA/App/DebugLog.swift),
[`EVAProcessLog`](../../EVA/Pipeline/EVAProcessLog.swift),
[`ProcessingAuditLog`](../../EVA/Pipeline/ProcessingAuditLog.swift), and
[`StatusLogView`](../../EVA/Waveform/StatusLogView.swift) serve different audiences.
Inspect their call sites and enabled conditions before assuming every event is
logged. A status message is not necessarily a durable processing record.

In Xcode, use the Report navigator to see the full build/test log and the debug
console/variables view for a paused run. Preserve an `.xcresult` bundle with the
terminal command in [testing](testing.md#run-one-suite-and-keep-the-evidence).
Record the first relevant error plus context; the final `TEST FAILED` line
alone rarely identifies the cause. Avoid dumping entire sample arrays or file
paths containing sensitive identifiers into a shared report.

## Finish the investigation

Explain the trigger, failed invariant, smallest fix, regression test, relevant
integration checks, and remaining limits. Review the diff for unrelated changes.
If only comments/docs changed, verify their contracts and examples; adding tests
that just restate those comments is unnecessary. As an independent exercise,
trace an export cancellation through `RecordingStore.exportRunner` and identify
which run may clear the exporting flag.
