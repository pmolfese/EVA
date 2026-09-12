# IO — `EVA/IO`

**Purpose.** The app-side layer over file formats: opening/importing recordings
(every supported format funnels through here), the recording *document* type,
MFF export & split, physio-trace import, and publication **figure export**. The
UI-free format readers themselves live in `EVACore/IO`
([evacore-io.md](evacore-io.md)).

**Start here.** `SignalImportReader` is the front door for opening any file;
`MFFRecording` is the document the recording window wraps; `FigureExport` +
`FigureExportBasket` are the shared figure pipeline.

## Files

| File | Synopsis |
|---|---|
| `SignalImportReader.swift` | The universal importer: dispatches to FIF/BrainVision/EDF/Persyst/BESA/EEGLAB readers and the MNE-Python bridge, reads electrode locations, and normalizes to an `ImportedRecording`. |
| `MFFRecording.swift` | The app document type wrapping a loaded recording: channel roles, edits, `LoadResult`, geometry/reference bridges. |
| `MFFExportWriter.swift` | App-side entry to write an `.mff` (delegates to `EVACore` `MFFWriter`). |
| `MFFExportFlowViews.swift` | The export flow UI (a `WaveformView` extension). |
| `MFFSignalSplitter.swift` | Splits a recording into two by a time/marker boundary (`MFFSignalSplitPair`). |
| `PhysioTextImporter.swift` | Parses external physio traces from text (`ImportedPhysioChannel`, `PhysioTextImportResult`). |
| `PhysioImportViews.swift` / `PhysioPaneViews.swift` | Physio import sheet (alignment, sparkline) and the physio pane UI. |
| `ChannelExportViews.swift` | Exports selected channels/events as a payload (`ChannelExportPayload`). |
| `DatasetInfoSheet.swift` | The "dataset info" sheet (recording metadata). |
| `FigureExport.swift` | The figure exporter: `FigureFormat`, `FigureExporter`, `FigureScale`, `FigureCard` — the shared render-to-file path. |
| `FigureExportBasket.swift` / `FigureExportBasketView.swift` | Collects figures across the session (`FigureBasketItem`) for a single multi-page export. |

## How to extend this

A new **import format** is a reader case wired into `SignalImportReader`'s
dispatch (mirror `EDFSignalReader` etc.) that returns an `ImportedRecording`; put
byte-level parsing in `EVACore/IO` if QuickLook should also read it. A new
**export** exposes a `FigureCard` from the relevant view and lets
`FigureExportBasket` collect it — don't build a bespoke exporter per view. The
MFF write path must stay in sync with the core reader/writer so round-trips and
Finder previews agree.
