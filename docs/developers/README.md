# EVA Developer Documentation

Start here if you know programming but are new to EVA, Swift, or SwiftUI. The
guide covers setup, code ownership, extensions, debugging, compatibility, and
releases. The [milestones](onboarding-milestones.md) distinguish delivered chapters
from open acceptance gates; [M1 validation](onboarding-validation.md) and
[M2–M6 validation](guide-validation.md) state what has actually been checked.

## Your first day

1. [Set up EVA and open a synthetic recording](setup.md).
2. [Make your first change: add and debug a regression test](first-change.md).
3. [Read the code through a filtering workflow](getting-started.md).
4. Keep [Swift in EVA](swift-in-eva.md) and the [glossary](glossary.md) nearby
   when the language or EEG terminology is unfamiliar.

## Find a feature and follow its data

- [Feature → code → tests](features.md): find the UI, state owner, engine,
  persistence/replay boundary and test starting points for 27 workflows.
- [Data and recording lifecycle](data-and-lifecycle.md): arrays, units, events,
  epochs, revisions, ownership, worker publication and close/reopen.
- [Complete source inventory](source-inventory.md): a checked catalog of product,
  shared, test, tool and script files, with links and entry declarations.

## Understand and change the application

- [Architecture map](architecture.md): build targets, shared source groups,
  central types, data flow, and subsystem entry points.
- [State ownership and boundaries](architecture-layers.md): lifetimes,
  computation/publication, and guidance for new views.
- [History and replay](history-and-replay.md): snapshots, scripts, invalidation,
  compatibility, and task identity.
- [Subsystem reference](subsystems/README.md): where features live, file
  synopses, and integration notes, including the M2 inventory reconciliation.
- [Commenting](commenting.md) and [testing](testing.md): explain contracts and
  choose checks appropriate to a change.

## Extend, debug and maintain

1. Work through the [four extension recipes](recipes/README.md): a display option,
   persisted parameter, analysis metric, and recording reader. Complete patches
   and tests accompany the explanations; practice in a separate checkout.
2. Use [testing](testing.md) to select/run checks and [debugging](debugging.md)
   to investigate assertions, stale results, cancellation and numerical errors.
3. Read [compatibility](compatibility.md) before changing saved settings, schemas,
   enum values, learned payloads, replay or batch behavior.
4. Follow [releases and maintenance](releasing-and-maintenance.md) for release
   preparation, signing, notarization, smoke checks and faulty-release response.
5. Use [documentation maintenance](documentation-maintenance.md) for link,
   inventory, patch and site checks. Complete the
   [acceptance walkthrough](acceptance-walkthrough.md) to evaluate the guide
   with a programmer who has not seen EVA before.

## Readability review — November 2026

- [Assessment and plan](readability-audit-2026-11-06.md).
- [Complete file scorecard, including corrected scores](readability-file-ratings-2026-11-06.md).
- [Comment pass, verification, and deferred structural changes](readability-comment-pass-2026-11-06.md).

This tree is developer-facing. The [user manual](../manual/index.md) explains
how to use EVA; [provenance notes](../provenance/README.md) and
[design references](../design/README.md) explain methods and contracts.
The developer pages are included in the MkDocs Developer Guide navigation via
the generated publishing mirror. Local build validation does not imply a remote
deployment has run. The broader project plan is
[ROADMAP §13](../../ROADMAP.md#13-developer-documentation).
