# Developer guide milestones

Updated: 2026-11-07. Audience: a programmer with undergraduate CS coursework who
has never seen EVA and may be new to Swift, SwiftUI, and EEG.

**Goal:** a reader can build EVA, find and explain a feature, make a tested
change, extend it through persistence and replay, and maintain a release without
depending on the original author for undocumented steps.

These milestones extend [ROADMAP §13](../../ROADMAP.md#13-developer-documentation).
DEV-1a and DEV-1b delivered reference pages; they did not establish that a new
developer could complete an end-to-end workflow. DEV-1c is covered by M2 below;
DEV-1d is covered by M6. This page tracks the onboarding work in one place.

## Delivery order

| Milestone | Reader outcome | Deliverables | Depends on | Status |
| --- | --- | --- | --- | --- |
| M1 — First successful change | Set up, open synthetic data, and add a regression test | Corrected architecture, setup, first-change tutorial, entry-point links, verification record | None | Chapters delivered; full-app/newcomer acceptance pending |
| M2 — Find code and understand ownership | Trace a feature from a user action to data, state, and tests | Feature-to-code/test index; complete source inventories; recording lifecycle and data-contract guide | M1 | Delivered; independent-reader acceptance pending |
| M3 — Extend a feature end to end | Add behavior without missing persistence, invalidation, or replay | Four worked extension recipes with tests and expected results | M2 | Recipes delivered and CPU-tested; GUI/integration acceptance pending |
| M4 — Diagnose and validate changes | Choose tests and investigate numerical, UI, and concurrency failures | Testing/debugging handbook; fixture and tolerance guidance; worked failure investigations | M1–M3 | Handbook delivered; focused examples tested |
| M5 — Maintain saved work and ship | Preserve compatibility and produce a verified release | Compatibility playbook; release and maintenance runbook | M3–M4 | Runbooks delivered; signed release rehearsal pending |
| M6 — Publish and keep the guide trustworthy | Find the guide online and notice when it drifts | Site integration, portable links, automated checks, newcomer acceptance walkthrough | M1–M5 | Site/checks implemented; deployment and independent-reader gates pending |

Work one chapter or recipe at a time. Check its links, commands, code examples,
and claims before moving on. Documentation work does not require refactoring
production code. Any behavior change discovered along the way should be a
separate, narrowly tested change with its own explanation.

## M1 — First successful change

Deliver:

- [Setup](setup.md): prerequisites, actual Xcode targets and schemes, local
  signing, Metal requirements, build commands, synthetic recording generation,
  launch/open checkpoints, and common setup failures.
- [First change](first-change.md): exact files, a small test addition, relevant
  Swift syntax, baseline → deliberate failure → passing test, debugger exercise,
  and diff review.
- Accurate [architecture](architecture.md): shared source groups versus targets;
  `MFFRecording` versus `RecordingStore`; existing view integration versus the
  preferred pattern for new UI; explicit history/replay integration checks.
- A navigable developer entry point linked from the root README, plus a
  [verification record](onboarding-validation.md) separating executed checks
  from manual acceptance that remains outstanding.

Delivered in this stage: the four chapters/guide updates above, an isolated
4-test baseline → 5-test pass → deliberate failure → restored pass experiment,
and a simulator build/generation/readback check. The normal app and focused test
commands remain blocked here by the missing Metal compiler component. See the
[verification record](onboarding-validation.md) for the exact scope.

Completion gates:

- [ ] From a clean checkout, follow only the guide to build and launch EVA using
  the normal project and scheme, then open the generated recording.
- [ ] Run the original focused test suite, add the tutorial test, observe its
  intentional assertion failure, and restore a passing result in the normal project.
- [ ] Explain why the test result is correct, locate the implementation, inspect
  it with a breakpoint, and review the final diff.
- [x] Record tool versions, commands, outcomes, and limitations. Do not label a
  temporary CPU-only build as a successful full-app build.

## M2 — Find code and understand ownership

Delivered: [27-feature map](features.md), [data/lifecycle chapter](data-and-lifecycle.md),
[complete checked source inventory](source-inventory.md), and 50 missing file
explanations across 11 subsystem pages. Paths and the selected source contracts
are checked automatically. Independent-reader comprehension remains an
[acceptance task](acceptance-walkthrough.md).

Create `features.md`, mapping user-visible features to the UI entry point,
state owner, computation engine, persistence/replay integration, and relevant
tests. Include import/export, channel decisions, filtering, gradient and cardiac
correction, ICA, wavelet/artifact workflows, epoching, trial analysis,
rhythmicity, history, batch/replay, Resolve, QuickLook, and figure export.

Reconcile subsystem inventories with the actual tree. Start with known gaps in
Artifacts, Pipeline, Channels, and App; audit the remaining groups rather than
assuming their lists are complete. Retain original readability scores and
distinguish corrected scores from files that have not been reassessed.

Write a data-and-lifecycle chapter using a small concrete recording: channels
versus samples, indices versus seconds, signal units, events, epochs, channel
roles, revisions, and derived caches. Trace open → process → cancel/replace →
publish → close → reopen. Show who owns each object, how long it lives, what is
copied into a worker request, and what is allowed to publish on the main actor.
Connect the explanation to the existing Swift, architecture, and history pages.

**Done when:** a newcomer can locate both a feature and its tests, draw its state
ownership, and explain why an old background result cannot update a new recording.
Every source file has an accurate inventory entry or an explicit documented
exclusion. Validate the feature map against actual call sites.

## M3 — Extend a feature end to end

Delivered: [four worked recipes](recipes/README.md), complete standalone patches,
and tests for the parameter, metric and reader. SwiftUI edits compile with the
isolated validation host; selected CPU behavior tests passed. Normal GUI,
history/replay/batch and layout acceptance remain explicit in each recipe.
See [validation](guide-validation.md) before interpreting the test results.

Add four progressive recipes, each with exact paths, small annotated changes,
expected output, tests, common mistakes, and an independent exercise:

1. Add a display-only option: view inputs/bindings, state lifetime, menu wiring,
   and the reason it does or does not persist.
2. Add a persisted processing parameter: control → configuration → immutable
   request → computation → publication → invalidation → history → serialization
   → replay → tests. Include a saved older configuration with the field absent.
3. Add an analysis metric: units, data shape, deterministic fixture, numerical
   expectations, presentation, and export.
4. Add a processing stage or recording reader: choose a concrete example and
   document target membership, validation/errors, metadata, and all applicable
   interactive, batch, history, and file-format integration points.

**Done when:** a reader can complete each example and run its checks without
guessing an omitted integration step. Demonstrate save/reopen and replay for
persisted behavior. A recipe must say which boundaries do not apply and why.
Keep example changes isolated from unrelated algorithm changes.

## M4 — Diagnose and validate changes

Delivered: expanded [testing handbook](testing.md) and [debugging investigations](debugging.md),
including assertion, stale-result, cancellation and numerical examples. The
existing selection/latest-only/replay suites used by these explanations were
run in the isolated CPU validation configuration.

Expand [testing](testing.md) into a handbook: running one test in Xcode and the
terminal; Swift Testing versus XCTest; app-hosted tests versus CLI checks;
fixture discovery and MFF packages; CPU/GPU parity; random seeds; floating-point
tolerances; and the difference between missing local fixtures and regressions.

Walk through a failed assertion, a stale asynchronous result, a cancellation,
and a numerical discrepancy. Explain breakpoints, useful model values, logs,
test result bundles, and how to reduce a failure to a small reproducible input.
Include a change-to-test matrix and the real semantics of `run-all-tests.sh`
options, especially that `--fast` skips the Xcode suite.

**Done when:** a newcomer can choose the relevant suite, reproduce a failure,
explain the evidence, and add a regression test without loosening scientific
tolerances or regenerating reference data merely to obtain a pass.

## M5 — Maintain saved work and ship

Delivered: [compatibility playbook](compatibility.md) and [release/maintenance runbook](releasing-and-maintenance.md).
Missing-key/XML/JSON/export contracts have executable recipe tests. Signing,
notarization and installation rehearsal require an authorized maintainer's
release environment and remain unexecuted; no release was published.

Write a compatibility playbook for schema fields, serialized enum values,
defaults, settings, learned payloads, sample/cache revisions, replay, and batch.
Show how to add an optional field or decode an explicit legacy default, and how
to test old files plus export/reimport. Document unsupported replay behavior and
migrations rather than silently accepting a changed interpretation.

Write a release runbook grounded in `scripts/release.sh`: local development
versus distribution signing, required credentials, versions/build numbers,
embedded simulator and Finder extensions, archive/export/notarization, smoke
tests, release artifacts, and a response to a faulty release. Describe commands
that remove or overwrite generated outputs before a reader executes them.
Document dependency/license/provenance upkeep and the relevant ownership paths.

**Done when:** a maintainer can assess a change's compatibility impact and follow
a release rehearsal with expected outputs. Validate credentials-dependent steps
with an authorized maintainer; document an unexecuted step as unverified, not passed.

## M6 — Publish and keep the guide trustworthy

Delivered: developer site navigation and generated mirror, PR/source-change CI
coverage, portable scorecard links, inventory/link/source-contract/patch checks,
tooling regression tests, and [documentation maintenance](documentation-maintenance.md).
The [acceptance walkthrough and results form](acceptance-walkthrough.md) are ready.
Local strict-build/check results are in [validation](guide-validation.md);
remote deployment and a real independent newcomer trial remain open.

Integrate `docs/developers` into the MkDocs build/navigation and documentation CI
path filters without creating a second hand-edited copy. Repair machine-specific
links in the readability scorecard. Add checks for relative links, source
inventory coverage, referenced symbols/paths where practical, and tutorial
snippets. A header change can prompt review; it cannot prove prose remains accurate.

Have a programmer unfamiliar with EVA follow the guide from a clean checkout:
build/open synthetic data, complete the first test, fix a small bug, add a
persisted setting, select the right tests, and explain history/replay and saved
file compatibility. Record every point requiring an author's explanation and
update the relevant chapter. Keep setup tool versions and validation dates
visible; rerun affected examples when code or project membership changes.

**Done when:** the site builds strictly, developer-page changes trigger CI,
portable links resolve, inventory checks pass, and the independent newcomer
walkthrough succeeds without undocumented assistance. This is the final
acceptance gate for calling the guide complete.

## Standard for every chapter

State the goal and prerequisites, teach only the concepts needed for that task,
link exact source and test files, provide numbered steps with observable
checkpoints, explain common failures, and finish with validation and a small
exercise. Use repository-relative links. Preserve the NIH header in source
examples that create whole files. Prefer explaining ownership, units, failure
behavior, and reasons over translating each line of Swift into English.
