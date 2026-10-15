# Waveform — `EVA/Waveform`

**Purpose.** The recording window — the app's main screen — and every panel and
plot inside it: the scrolling multichannel trace, butterfly/topomap panels, the
event and physio tracks, the history rail, and the status/progress UI. Most other
subsystems' UIs are `extension WaveformView` files that live in *their* folders
but render inside this window.

**Start here.** `WaveformView` is the top-level view (very large — the recording
window itself). `WaveformSupportingTypes` is the grab-bag of value types the
window and its panels share. `WaveformUIModels` holds the small observable models
(selection, events, physio, status). The history rail is `WaveformHistoryRail` +
`HistoryRailView`.

## Files

| File | Synopsis |
|---|---|
| `WaveformView.swift` | The recording window root view; MRI-gradient engine/method enums; the assembly point for every panel. |
| `WaveformSupportingTypes.swift` | Shared value types: viewport, hover info, signatures/caches, PSA build jobs, MFF export/split snapshots, right-click monitor, progress structs. |
| `WaveformUIModels.swift` | Small observable models: `WaveformSelectionModel`, `WaveformEventDisplayModel`, `PhysioDisplayModel`, `RecordingStatusModel`. |
| `WaveformPlotViews.swift` | The core plots: `WaveformPlot` (trace), butterfly/overlay plots, event/physio tracks, ICA time-course, topomap scale control. |
| `WaveformChannelRows.swift` | Per-channel trace rows and labels. |
| `WaveformAxisViews.swift` | Voltage and time axis overlays. |
| `WaveformOverlays.swift` | Cursor / selection / artifact-highlight overlays. |
| `WaveformScaleUnits.swift` | Amplitude/time scale units (µV/mm, mm/s) and their arithmetic. |
| `ButterflyPanelViews.swift` | The butterfly panel (a `WaveformView` extension). |
| `TopomapPanelView.swift` | The topomap panel. |
| `GFPPlot.swift` | Global Field Power strip (`GFPMath`, `GFPStripView`). |
| `EventsPanelView.swift` | The events list panel (`EventCodeChip`). |
| `PhysioPaneView.swift` | The physio pane inside the window. |
| `WaveformHistoryRail.swift` / `HistoryRailView.swift` | The history-tree rail (a `WaveformView` extension) and its row/menu views; `ProcessingChainSignature`. |
| `HistoryTransportCommands.swift` | Undo/redo/step transport actions + `FocusedValues` wiring. |
| `WaveformSheetHost.swift` | Hosts the active modal sheet (`ActiveRecordingSheet`) — the switchboard to every feature sheet. |
| `WaveformSourceFit.swift` | Right-click → "Fit Source Model" hand-off and the Resolve fit sidecar. |
| `ProcessingStatusPopover.swift` / `StatusLogView.swift` | The processing-status popover (queue/history tabs) and the status log. |

## How to extend this

Most features add a **sheet**: define it in your subsystem as an
`extension WaveformView`, add a case to `ActiveRecordingSheet` in
`WaveformSheetHost`, and present it. Add shared value types to
`WaveformSupportingTypes` and shared state to `WaveformUIModels` rather than
growing `WaveformView` itself (already very large). New plots belong in
`WaveformPlotViews`; keep them pure SwiftUI reading from the UI models, with any
math in the owning subsystem. Menu commands flow through `FocusedValues` keys
declared on `ChannelModel` ([channels.md](channels.md)) and transport commands
here.
