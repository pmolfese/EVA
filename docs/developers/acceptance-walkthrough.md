# Newcomer and maintainer acceptance walkthrough

**Purpose:** establish that the guide works for someone who has not seen EVA.
This is an executable review procedure and results form, not a completed test
report. No independent reader or signed-release rehearsal has been claimed.
Record actual outcomes in [guide validation](guide-validation.md).

## Roles and preparation

The reader should know undergraduate programming concepts but need not know
Swift/SwiftUI or EEG. A maintainer observes and records gaps without supplying
undocumented steps. Use a clean practice checkout containing the guide, a
configured Mac, and synthetic data. Identify any prerequisite knowledge the
reader needed that the guide did not explain.

Record:

| Field | Value to fill during the session |
| --- | --- |
| Reader and observer | Names/roles appropriate to the review record |
| Date / checkout commit | Exact date and revision; note local changes |
| macOS / Xcode / Swift | Outputs of the setup commands |
| Signing / Metal setup | Local configuration and any extra setup required |
| Starting familiarity | Programming, Swift, EEG and EVA experience |
| Input | Synthetic seed/configuration and generated filenames |

## First-day tasks

1. Starting at the root README, find the developer guide. Follow setup to build
   and launch the normal EVA scheme, generate a recording, and open both clean
   and noisy files. Explain channels, sample rate, duration and why MFF is a package.
2. Complete the first-change regression test: baseline pass, added passing test,
   intentional failure, corrected pass, breakpoint inspection, and diff review.
   Explain what plausible bug the new case would detect.
3. Use the feature map to locate filtering's control, owner, worker, history and
   tests. Draw the ownership of a recording window and explain which state is
   app-wide, per-window, per-sheet and per-request.
4. Explain what happens when an old request finishes after a successor or after
   the recording is closed. Find the identity/publication guard in real code.

**Pass evidence:** successful normal build/test output, GUI checkpoints, the
reader's explanation, and no required undocumented instruction. A missing
toolchain component is a setup blocker to record, not a pass or a source regression.

## Development and extension tasks

1. Apply the display-option recipe and verify both states, two windows, and
   close/reopen lifetime. Explain why no history/replay field belongs here.
2. Apply the persisted-parameter recipe. Run its tests, then use the normal app
   to apply, undo/redo, export/reopen, and replay on the original synthetic input.
   Check a batch run and compare samples. Explain absent-key behavior and the
   risk of an older app ignoring the newly required parameter.
3. Apply the metric recipe. Run tests, inspect the report, and export with detail
   options disabled. Confirm UI percent, JSON fraction and CSV fraction agree.
   Explain why an old report's absent value differs from zero.
4. Apply the reader recipe. Test valid/malformed input and MFF export/reimport.
   Explain channel-major shape, units, timing, type registration and unsupported
   metadata. Identify the additional work before claiming CLI/Finder/batch support.
5. Independently make a small correction in a practice checkout. One controlled
   exercise is to introduce a wrong boundary comparison in the selection helper,
   reproduce the failing case, fix it, and add a focused regression. The observer
   must label the introduced bug so it cannot be mistaken for a production defect.

**Pass evidence:** diffs, selected test rationale and results, manual integration
results, and an explanation of which boundaries do or do not apply. “Patch
applies” or “it compiles” alone does not complete these tasks.

## Maintenance and release tasks

Use a saved old-format fixture to demonstrate a missing-field compatibility
check. Locate a serialized enum raw value and explain how to rename the Swift
case without silently changing that stored value. Trace an incompatible payload
or unsupported replay step to its reported refusal/remainder.

With an authorized release maintainer and distribution credentials, rehearse the
[release runbook](releasing-and-maintenance.md). Record archive/export/notary
results, submission ID, app/extension signatures, versions, checksums, installation,
Finder behavior, a GPU path and the smoke tests. Verify the final distributed ZIP
contains the stapled app. This rehearsal is not an instruction to publish an
application merely to evaluate documentation. Mark unavailable credentials or
unexecuted external operations explicitly.

Run documentation checks and the strict site build. Preview the Developer Guide
navigation, diagrams, source links, scorecard and patch downloads. After an actual
merge/deploy, check the public site and remote workflow separately.

## Record friction and decide acceptance

| Task / page | Expected checkpoint | Observed result | Outside help needed | Follow-up / retest |
| --- | --- | --- | --- | --- |
| Fill one row per task | State an observable result | Pass / fail / blocked / not run, with evidence | Quote the missing instruction | File/section to fix and new result |

Do not record a skipped or blocked check as passed. Close a milestone only when
its content and applicable acceptance gates are satisfied. M6's independent
reader gate remains open until an actual reader completes these tasks without
undocumented assistance. Preserve failed attempts too: they identify where the
guide needs a better explanation or prerequisite.
