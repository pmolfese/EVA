# Channels — `EVA/Channels`

**Purpose.** Everything about *channels*: where electrodes sit (geometry &
montages), how bad ones get interpolated, how scalp fields are drawn (topomaps),
and the standalone Channels window. It also defines `ChannelModel`, the per-recording
observable model the whole app hangs off.

**Start here.** `ChannelModel` (per-recording state + the menu-command
environment keys); `ChannelInterpolationSolver` / `InterpolatedSignalResolver`
for bad-channel repair; `TopomapView` for scalp fields; `ChannelSet` /
`ChannelSetStore` for saved montages. Geometry types themselves live in
`EVACore/Channels` ([evacore.md](evacore.md)).

## Files

| File | Synopsis |
|---|---|
| `ChannelModel.swift` | The per-recording observable model (channel/interpolation state) **and** the `FocusedValues` command keys (`MFFExportRequestKey`, `PSAViewControlsKey`, …) wiring menus to the frontmost recording. |
| `ChannelInterpolationSolver.swift` | Solves spherical-spline interpolation for bad channels (`Solution`, `Failure`). |
| `InterpolatedSignalResolver.swift` | Lazily materializes interpolated channels on demand (cache keyed by `Key`). |
| `ElectrodeGeometry+Forward.swift` | Bridges a montage to the forward model (`ElectrodeGeometry` → forward types). |
| `TopomapView.swift` | Scalp-field rasterization and rendering (`FieldRaster`, `TopomapZScaling`, colour-bar placement, raster cache). |
| `ScalpTopography3DView.swift` | 3-D scalp topography (SceneKit) view + coordinator. |
| `ChannelSet.swift` | The saved-montage model (`ChannelSet`, `KnownNetGeometry`, export). |
| `ChannelSetStore.swift` | Persists/loads channel sets and net geometries. |
| `ChannelSetEditorView.swift` | Editor for channel sets and managed net geometries. |
| `ChannelSetMapView.swift` / `ChannelSetPickerView.swift` | Map/preview and picker for channel sets. |
| `ChannelGoodnessSettings.swift` | Persisted channel-goodness thresholds + settings UI + metric help. |
| `ChannelInspectorViews.swift` | Per-channel inspector plot (traces, hover, standard-error band). |
| `ChannelsWindowModel.swift` | State for the standalone Channels window (`ChannelsWindowTab`, relationship-analysis state). |
| `ChannelsWindowView.swift` | The Channels window (diagnostics view, scalp map). |
| `ChannelsPanelViews.swift` | The in-recording channels panel (a `WaveformView` extension). |

## How to extend this

Bad-channel repair is spherical-spline based: interpolation *weights* come from
`EVA/Core/SphericalSpline`, the *solve* from `ChannelInterpolationSolver`, and the
lazy materialization from `InterpolatedSignalResolver` — extend the solver, not
the callers. A new **topomap rendering** option lives in `TopomapView`
(watch the raster cache keys). Because `ChannelModel`'s command keys wire menus
app-wide, adding a menu action means adding a `FocusedValues` key here and reading
it in `EVAApp`/`ContentView` ([app.md](app.md)).

## Recording-local location overrides

`ChannelLocationImportViews` previews a `.bvef` file and explicit name/number
matching. `EVACore/Channels/BVEFMontage` parses BrainVision signed polar angles
and azimuths into EVA's right/anterior/superior unit-sphere axes. Zero radii have
no spatial position. Duplicate names/numbers, non-finite coordinates, malformed
XML, and ambiguous name mappings fail explicitly.

`ChannelsWindowModel` routes application to the captured recording ID; a preview
cannot silently affect a newly focused recording. `MFFRecording` owns the
replacement layout/geometry without changing its signal revision. Existing
interpolation recipes are re-solved through `ChannelInterpolationSolver` and
health is refreshed. Role edits remap the active override, and fork payloads
carry it into the new document.

`MFFExportSnapshot` carries an optional `EEGLocationOverride`. The core MFF writer
uses it after normal metadata copying, so stale source XML cannot overwrite it.
The override writes matching 2D/3D metadata in signal order; zero-vector entries
retain non-spatial channel names in `coordinates.xml`, while missing 2D positions
stay off the scalp map. The export log records the source and matching method.
Split exports and Resolve handoffs use the same metadata path.

`BVEFMontageTests` covers orientation, mapping, reference handling, non-spatial
channels, stale source XML, MFF round-trips, unchanged samples/source files,
channel-role edits, and recording focus routing. An optional ignored local
corpus checks the study's complete BC-MR-64-X52 file against MNE; the repository
contains only synthetic electrode definitions, not the study's supplied file.
