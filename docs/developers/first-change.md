# Your first change: protect a selection rule with a test

**Goal:** add one regression test, see it detect an incorrect expectation, and
finish with a passing suite. You will change only a test file. The application
already implements the behavior being tested.

**Prerequisites:** complete [setup](setup.md), including a working normal app
build. Use a development branch according to your project's Git workflow and
inspect `git status --short` before starting. If you already have unrelated
changes, preserve them and review your tutorial diff separately.

## 1. Find the code and predict its behavior

Open these files with Xcode's Open Quickly (Command-Shift-O) or the navigator:

- [SignalSelection.swift](../../EVA/Core/SignalSelection.swift): small selection
  helpers, including `mergeNearbyStarts`.
- [SignalSelectionTests.swift](../../EVATests/Core/SignalSelectionTests.swift):
  the existing tests, inside `struct SignalSelectionTests`.

The function accepts candidate detections, each represented by a tuple
`(start: Int, score: Float)`. `start` is a sample index, not seconds. `score` is
the strength of that detection. The function sorts candidates by start and
greedily keeps the strongest nearby representative. Replacing a representative
changes both its score and its sample index, so the next comparison uses the
new index.

For a merge distance of ten samples, trace this input:

| Candidate | Comparison | Retained result |
| --- | --- | --- |
| `(100, 0.5)` | No previous representative | `(100, 0.5)` |
| `(105, 0.9)` | Five samples away and stronger | Replace with `(105, 0.9)` |
| `(114, 0.8)` | Nine samples from the current representative, but weaker | Keep `(105, 0.9)` |

Although 114 is fourteen samples from the *first* candidate, the representative
has moved. The result should contain one hit. This is a useful regression case:
an implementation that accidentally fixes the merge window at 100 would keep an
extra hit. We are documenting the existing contract, not deciding a new algorithm.

## 2. Establish the baseline

Choose the **EVA** scheme in Xcode, open the Test navigator (Command-6), find
`EVATests` → `SignalSelectionTests`, and run that suite using its run control.
You can also use a test's gutter control in the source editor. Run the suite
rather than Product → Test if you want to avoid running all selected suites,
including UI tests.

The equivalent terminal command, from the checkout root, is:

```sh
xcodebuild test -project EVA.xcodeproj -scheme EVA \
  -destination 'platform=macOS' -derivedDataPath build/onboarding \
  -only-testing:EVATests/SignalSelectionTests
```

At the time this tutorial was written, the suite contained four tests. They
should pass before you edit. If the suite has since grown, the exact count can
differ. A test filter selects what runs; Xcode can still build the host app,
embedded products, and other targets required by the scheme. A build failure
before tests start is not an assertion failure in your test.

These tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not
XCTest's `XCTestCase` syntax. `@testable import EVA` lets the test bundle access
internal app declarations compiled for testing. You do not need to make the
helper public or add a new target.

## 3. Add the missing regression case

Add the following method **inside** `struct SignalSelectionTests`, before its
closing brace. Keep the existing imports, tests, and NIH file header.

```swift
    /// A stronger replacement moves the window used for the next candidate.
    @Test func mergeWindowFollowsStrongerRepresentative() {
        // The third hit is near 105, but is outside a window anchored at 100.
        let hits: [(start: Int, score: Float)] = [
            (start: 100, score: 0.5),
            (start: 105, score: 0.9),
            (start: 114, score: 0.8)
        ]

        let merged = SignalSelection.mergeNearbyStarts(hits, mergeSamples: 10)

        #expect(merged.count == 1)
        #expect(merged.first?.start == 105)
        #expect(merged.first?.score == 0.9)
    }
```

`let` declares a value that this method does not reassign. `[(start: Int,
score: Float)]` is an array of named tuples, not a new class. `.first` returns an
optional because an array could be empty; `?.start` safely reads the tuple's
start if it exists. This avoids an out-of-bounds crash that could obscure the
assertion failure. Here the score is copied unchanged from a candidate; an exact
comparison is appropriate. Computed scientific results often need a justified
tolerance instead.

Run the suite again. Expect five passing tests, including the new method.

## 4. Prove that the assertion is actually running

Temporarily change only this expectation in the new test:

```swift
        #expect(merged.first?.start == 114)
```

Run the suite. The new test should fail because the actual retained start is
105. Inspect the failure in the source editor or Test/Report navigator. This
deliberate failure proves that your new test is discovered and that the
assertion checks the result you intended.

Restore the expected value to **105**, and rerun. Finish with all five tests
passing. Do not change the production helper to satisfy the deliberately wrong
expectation. If nothing failed, check that you saved the file, ran this suite,
and placed the method inside the test type compiled into `EVATests`.

## 5. Follow one iteration in the debugger

Set a breakpoint in `SignalSelection.mergeNearbyStarts` on
`merged[merged.count - 1] = hit`. Run the new test from Xcode. At the replacement,
inspect `hit` and `last` in the variables view: their starts should be 105 and
100. Step over the assignment, then inspect `merged` to see its representative
move to 105. Continue and inspect the next comparison if you want to see why
114 is not appended. Disable the breakpoint and finish the run.

The debugger may also stop for another test if you run the whole suite. Run the
individual new test for this exercise, and check the call stack if the input
does not match the table. Use a Debug build so stepping and local variables are
useful.

## 6. Review and explain the change

```sh
git diff -- EVATests/Core/SignalSelectionTests.swift
git diff --check
git status --short
```

The tutorial's final change should be one new test method, with the expectation
restored to 105. Preserve any pre-existing work. A suitable change description is:
“Add a regression test showing that the merge window follows the stronger
retained detection; focused SignalSelectionTests pass.”

No UI, history, serialization, or algorithm change is needed for this test-only
addition. A future production change would need its own integration and test
assessment; see [testing](testing.md) and [history and replay](history-and-replay.md).

**Independent exercise:** add a case where the second hit is exactly ten samples
away and has an equal score. Predict the retained hit from the implementation's
`<=` distance comparison and `>` score comparison, then write and run the test.

**Completion check:** explain what the regression catches, show the deliberate
failure and final passing run, and locate the replacement in the debugger.
The [validation record](onboarding-validation.md) distinguishes the checks run
while writing this tutorial from the normal-project newcomer walkthrough still
to be completed.
