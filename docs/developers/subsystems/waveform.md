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

For a new sheet, prefer a standalone `View` in the owning subsystem with
explicit input values, bindings, and action closures. Existing features often
use `extension WaveformView`; a small adapter there can connect a new child view
to current state without making the entire sheet depend on the window's internals.
Add the appropriate `ActiveRecordingSheet` case and presentation wiring in
`WaveformSheetHost`. See [state ownership](../architecture-layers.md) before
choosing where a new setting lives.

Keep feature-specific values and computation with their subsystem. Put genuinely
shared value types in an appropriate shared file; shared per-window state should
have an explicit owner in `RecordingStore` or its child models. Existing shared
UI models live in `WaveformUIModels`. Keep plot math in the owning engine and pass
results into the view. Menu commands use `FocusedValues` keys declared in the
`ChannelModel` file ([channels.md](channels.md)) and transport commands here.
Verify presentation, bindings, menu focus, close/reopen, and cancellation where
applicable; adding a sheet case alone does not establish those behaviors.

## Additional source files

These entries complete the source-group inventory at this review. The
[checked repository inventory](../source-inventory.md) lists nested/shared groups
and test/tool sources as well.

| File | Responsibility |
| --- | --- |
| [WaveformDensityLayout.swift](../../../EVA/Waveform/WaveformDensityLayout.swift) | Calculates waveform layout density and spacing. |
