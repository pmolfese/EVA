# App & UI shell — `EVA/App` (+ `EVA/Simulation`, `EVA/Markers`, `EVA/Help`)

**Purpose.** The application shell: the `@main` entry point, window and document
lifecycle, menu commands, preferences, update checking — plus the Simulator
Studio windows, user markers, and the in-app help/release-notes viewer. This is
the SwiftUI scaffolding that hosts everything else.

**Start here.** `EVAApp` is the `@main` `App` (scenes, menu commands, window
buttons). `ContentView` is a recording window's content root. `RecordingStore` /
`OpenRecordingRegistry` track open recordings. `PreferencesView` is settings.

## `EVA/App`

| File | Synopsis |
|---|---|
| `EVAApp.swift` | The `@main` app: scenes, menu bar, and the "open X window" buttons (release notes, debug log, figure export, batch, simulator, new/open recording). |
| `ContentView.swift` | A recording window's content root; window accessor, combine request, recording-window actions (`FocusedValues`). |
| `WindowCloseBehavior.swift` | `EVAAppDelegate` — app/window close semantics. |
| `RecordingStore.swift` | Holds the set of open recordings. |
| `OpenRecordingRegistry.swift` | Weak registry of open recordings (`WeakRecording`) for cross-window lookup. |
| `PendingWindowOpens.swift` / `PendingWindowForks.swift` | Deferred window opens and history-fork-into-new-window plumbing. |
| `PreferencesView.swift` | The Preferences window: general, QuickLook, processing defaults, TF band editor. |
| `EventAnchorSettings.swift` / `EventAnchorCatalog.swift` / `EventAnchorPreferencesView.swift` | Event-anchor rules (how event codes map to timing anchors): model, catalog, and settings UI. |
| `UpdateChecker.swift` | GitHub-release update check (`AppVersion`, `UpdateCheckResult`). |
| `DebugLog.swift` | In-app debug log model + view. |
| `BatchWindowView.swift` | The batch-processing window (see [pipeline.md](pipeline.md) for the engine). |
| `SimulatorWindowView.swift` | The Simulator Studio window shell. |
| `SimulatorGenerateView.swift` | Generate tab: per-band amplitudes, sources, gradient/cardiac/ocular/muscle/ERP/defects/output config. |
| `SimulatorScoreView.swift` / `SimulatorSweepView.swift` / `SimulatorGroupView.swift` | Score, parameter-sweep, and group-simulation tabs. |
| `SimulatorHelp.swift` | Simulator help topics. |

## `EVA/Simulation` (Studio controllers)

| File | Synopsis |
|---|---|
| `SimulatorController.swift` | Drives the Simulator Studio (`Mode`, `Phase`). |
| `SimulatorRunner.swift` | Runs generate/score/sweep/group jobs (`Options`, `Output`, `Score`, `SweepOutcome`, `GroupOutcome`). |
| `SimulatorScenarioLibrary.swift` | Built-in scenario presets. |

*(The simulation **math** — generators, artifact models, source fitting — lives
in `EVACore/Simulation`; see [evacore-simulation.md](evacore-simulation.md).)*

## `EVA/Markers` & `EVA/Help`

| File | Synopsis |
|---|---|
| `Markers/UserMarker.swift` | A user-placed marker on the timeline. |
| `Help/MarkdownDocument.swift` / `Help/MarkdownView.swift` | A tiny Markdown parser + renderer for in-app docs. |
| `Help/ReleaseNotesCatalog.swift` / `Help/ReleaseNotesView.swift` | Release-notes content and viewer. |

## How to extend this

A new **window** is a `Scene` + an "open" button in `EVAApp` and (usually) a
model in a registry. A new **menu command** is a `FocusedValues` key on
`ChannelModel` ([channels.md](channels.md)) read here. A new **preference** is a
field in `EVAGeneralPreferences`/`ProcessingDefaults` and a control in
`PreferencesView`. Keep feature logic in the feature subsystems — `App` should
stay scaffolding: lifecycle, windows, commands, settings.
