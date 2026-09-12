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
