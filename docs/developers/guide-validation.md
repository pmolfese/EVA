# Developer guide validation: M2–M6

Date: 2026-11-07. This record covers the feature/lifecycle guide, four extension
recipes, testing/debugging, compatibility/release runbooks, and documentation
tooling. See [M1 validation](onboarding-validation.md) for the setup and initial
test exercise. Implementation and acceptance are tracked separately in the
[milestone plan](onboarding-milestones.md).

## Scope

Application code and project settings in the working checkout are preserved.
The four tutorial patches live under `docs/developers/examples/`; they were
applied only to a temporary copy of the current source. Documentation tooling,
site navigation and the documentation workflow are actual repository changes.
The source inventory includes current source additions and does not revise the
historical readability assessment population or scores.

## Evidence from this pass

| Check | Outcome | Limits |
| --- | --- | --- |
| Feature-to-code/test map | Paths resolved against current source and tests | Curated starting points, not a guarantee of complete test coverage. |
| Subsystem reconciliation | Added 50 missing file descriptions across 11 subsystem pages | Generated repository inventory also covers shared/test/tool groups. |
| Source inventory and entry-point contracts | Checked by the developer-doc tool | Header fingerprints and literal names detect drift, not semantic correctness. |
| Display-option patch | Compiled with the temporary app source | Visual layout, two-window behavior and normal-build GUI acceptance not executed. |
| Persisted-parameter patch | **3 tests passed**, including XML/default/restored EEG output, unchanged PNS and recorded-run gap behavior | Normal GUI history/replay/batch and cross-version release behavior remain acceptance checks. |
| Metric patch | **2 tests passed** across helper and real engine/export/legacy JSON suites | Report layout/GUI export interaction not inspected. |
| Reader patch | **2 test methods passed**, including six malformed-input cases, dispatcher and MFF export/reimport | Real-vendor support, Finder registration and GUI import not established. |
| Link portability | Converted 1,548 machine-specific scorecard links to repository-relative links | Scores and rationales unchanged. External URL availability is not checked. |
| Tooling unit tests | **6 passed**: link, inventory and site relocation regressions | Linux site CI does not run macOS app/tutorial tests. |
| Source preservation | Source/project hashes compared with the start of this pass | Earlier comment changes remain present and untouched. |
| Documentation/site build | See final validation results below | Local build does not claim GitHub Pages deployment. |

## Temporary Xcode validation configuration

The compiler/toolchain matches the M1 record (Xcode 27.2, Apple Swift 6.4.2,
arm64 macOS). The selected Xcode still lacks the Metal compiler needed by the
normal app build. To validate CPU-focused tutorial behavior, the experiment
copied the app/test sources and used the prior temporary project that excludes
non-Swift fixture resources and `.metal` compilation. Other shared groups used
the real current source. Signing was disabled; existing temporary DerivedData
was reused. Test methods with synthetic data do not depend on moved fixture paths.

The real SwiftUI edits compiled as part of that host build. The actual new tests
ran against the patched production functions, not mocked replacements. This
establishes the selected source/example contracts, not a successful normal
signed app build or GPU/Finder/UI acceptance. The repository's `EVA.xcodeproj`
and application/test source were not changed by this experiment.

Local logs and temporary sources are under `/tmp/eva-guide-m2-m6`; these are
ephemeral development artifacts, not inputs required by the published guide.
Durable results belong in this record and the patch/test source.

## Final validation results

- **21 Swift tests across seven suites passed** in the isolated configuration:
  `GuideFilterParameterTests` (3), `FilterReplayTests` (4),
  `LatestOnlyRunnerTests` (6), `SignalSelectionTests` (4),
  `GuideRetentionMetricTests` (1), `EEGAnalysisEngineTests` (1), and
  `GuideDemoReaderTests` (2, one parameterized over six rejection cases).
  The final filter/PNS change was retested; no failing example was left in the
  retained patches. These counts are methods, not a claim that every app test ran.
- **53 developer Markdown pages**, **775 current source inventory entries**,
  **four tutorial patches**, and **12 literal source contracts** passed the
  developer-doc check. All relative developer links and section anchors resolve.
- **Six Python tooling regression tests passed.** All four patches pass
  `git apply --check`; the site copies preserve the patch bytes.
- **68 planning/developer documents/assets synchronized**, sync `--check` passed,
  and **MkDocs `build --strict` passed** with the repository's documentation
  dependencies in a temporary Python environment. A separate generated-HTML
  pass verified **7,342 local link/fragment targets** across the developer site;
  **22 shell-example blocks** passed `zsh -n` syntax checking.
- **Desktop browser inspection completed:** developer navigation, entry page,
  rendered ownership diagram, feature table, inventory, and recipe patch/source
  links. The wide feature table was changed to two columns after inspection so
  tests and integration notes are visible without horizontal scrolling at the
  checked desktop width. Mobile/narrow-viewport acceptance remains unexecuted.
- **740 pre-existing source/project/configuration file hashes unchanged** from
  the start of this pass. Earlier user/comment work remains intact.
  `git diff --check` passed; generated bytecode/site/mirror output stays ignored.

No notarization, application release, GitHub Pages deployment, external
notification, or independent-newcomer trial was performed.

## Acceptance still requiring a suitable environment or another person

- Normal Metal-enabled app build, GUI tutorial checks and debugger walkthrough.
- Interactive history/undo, export/reopen/replay/batch acceptance for the parameter
  exercise; report layout and Finder/type registration for the other exercises.
- Signed archive/export/notarization/install rehearsal with an authorized maintainer;
  no release, external upload or publication was performed for this docs task.
- Remote CI and public-site verification after the changes are merged/deployed.
- An actual programmer unfamiliar with EVA completing the
  [acceptance walkthrough](acceptance-walkthrough.md) without undocumented help.

These are open acceptance gates, not omitted chapters. The guide includes the
procedure, expected evidence and results form for completing them. It must not
be described as independently beginner-validated or release-rehearsed until
those checks are recorded.
