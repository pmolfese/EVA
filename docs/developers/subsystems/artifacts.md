# Artifacts — `EVA/Artifacts` (+ `EVACore/Artifacts`)

**Purpose.** User-defined, spatial-temporal **artifact templates** and the
cleaning that removes them — the general path for artifacts that aren't the
gradient, cardiac, or ICA special cases. You draw/define an artifact's shape,
EVA detects matching occurrences, and subtracts them (OBS or local-template).

**Start here.** `ArtifactTemplateDetector` builds and matches templates;
`ArtifactCleaner` (with `ArtifactCleaningCore`) removes them; `ArtifactViewModel`
/ `ArtifactTemplateViewModel` drive the UI; `ArtifactReplayPayload` makes it
reproducible.

## Files

| File | Synopsis |
|---|---|
| `ArtifactTemplateDetector.swift` | Defines and matches templates: config (`ArtifactTemplateConfiguration`), topography/polarity/scan options, detection results, and the on-disk `SavedArtifactTemplate` schema. |
| `ArtifactCleaner.swift` | The cleaning engine: `DefinedArtifactType`, `ArtifactCleaningMethod`, `ArtifactOBSStrategy`; OBS correction with per-channel basis and variance report. |
| `ArtifactCleaningCore.swift` | The small UI-free core the cleaner builds on. |
| `ArtifactReplayPayload.swift` | Serializable payload so a template cleaning replays deterministically. |
| `ArtifactViewModel.swift` / `ArtifactTemplateViewModel.swift` | Observable state for cleaning and for template definition. |
| `ArtifactPreviewViews.swift` | Live before/after preview UI, OBS/local-template option sheets, wavelet-cleaning preview, scalogram popover. |
| `ArtifactTemplateDefinitionViews.swift` | The template *authoring* UI (a `WaveformView` extension). |
| `ArtifactDetectionSummaryViews.swift` | Detection-summary UI (a `WaveformView` extension). |
| `SourceInformed/SurrogateBrainBasis.swift` | Surrogate regional-source basis (`SurrogateBrainModel`) for source-informed separation; pairs with `EVACore/Artifacts/SourceInformed`. |

## How to extend this

A new **cleaning strategy** is a case in `ArtifactCleaningMethod` /
`ArtifactOBSStrategy` implemented in `ArtifactCleaner`. A new **matching feature**
extends `ArtifactTemplateDetector` (and the `SavedArtifactTemplate*` schema — bump
it carefully so old saved templates still decode). Keep the numerical core in
`ArtifactCleaningCore`/`ArtifactCleaner` and only parameters in the view models.
Anything reproducible must round-trip through `ArtifactReplayPayload`.

## Threshold ocular cleaning

Completed threshold detection also updates `DefinedArtifact` entries for eye
blinks and eye movements through `ThresholdOcularArtifactBridge`. Both are ocular
artifacts; `thresholdOcularKind` identifies detector ownership independently of
the display name. New entries default to Do Nothing and offer SSP/PCA or Standard
OBS in Clean Artifacts, with a 0.50-second editable fixed core window. The existing
edge options add tapered padding; threshold-run duration is not the cleaning
window. Correction uses all usable EEG channels except excluded channels.

Cleaning anchors are detected on the signal entering artifact cleaning, while
waveform markers continue to describe the current working signal. This keeps a
successful correction from replacing its own anchors with residual detections.
Re-detection updates entries in place, preserves treatment/window choices, and
invalidates correction when a participating definition changes. Existing entries
retain settings with zero events when a detector is disabled or finds nothing.
These entries do not automatically opt into defined-artifact epoch rejection;
the existing blink/movement rejection controls retain their separate behavior.

The existing Apply, post-apply preview/comparison, and Restore Original flow is
reused. Review events now opens the shared Define/Review workspace described
below. Exact asymmetric threshold spans remain available in the event plot,
separate from the fixed core window and padded taper. `ThresholdOcularReview`
retains the integer-window coverage helpers; its earlier standalone sheet has
been replaced by the shared workspace.

`thresholdOcularCandidates` retains all candidates; `events` contains only the
selected subset consumed by both basis fitting and correction. Exclusions are
preserved for identical candidates/configuration/input revision, and reset when
any of those changes. Window/treatment edits preserve exclusions and invalidate
applied cleaning. Review fields are optional for old sidecar compatibility and
round-trip in `ArtifactReplayPayload`. Input revisions are session identities;
a newly loaded/replaced input is treated as a new review input. Exact accepted
events remain available to saved-payload replay.

SSP/PCA now has an optional explicit component limit; absent values retain the
historical two-component limit. Explicit limits participate in processing
parameters and replay identity. Cross-recording detector replay and broader
ocular validation remain stage 3 work.

## Shared Define / Review / Clean workspace

`ArtifactTemplateViewModel.workspaceTab` selects Define, Review, or Clean inside a
shared 1060 × 820-point window. All entry points, including detector and replay
cleaning requests, use this shell; changing tabs keeps its size and position.
Define uses a 320-point settings inspector beside a larger preview/results area
for both waveform and topography modes. The columns scroll independently; run
comparison stays visible below the preview and footer actions remain at the bottom.
Identity fields occupy one compact row. All existing definition options and help
remain, including continuous durations, Top N/channel sets, and trajectory settings.
The shared shell uses the dynamic text/content background for a bright light-mode
surface with a softly shaded inspector and chrome, adapting to Dark Mode. Waveform
channel chips wrap and single scalp maps expand within the preview column.
Clean fills the workspace with its growing artifact list. The Artifacts menu
orders Define Artifact, Review Artifacts, then Clean Artifacts. Direct Review
requires detected events, not an active waveform selection. Review operates on
the signal entering cleaning, independently of the signal shown in Define.

`ArtifactReview.swift` owns the UI-free review model and engine;
`ArtifactReviewWorkspace.swift` renders the class list, similarity bands,
individual examples, event/average overlay, manual decisions, and rule preview.
`ArtifactReviewNavigation` shares page destinations between both arrow controls
and keyboard handlers. Multiple sets advance by eighteen to the first example of the
destination set; a single set advances individual examples. Page bounds support
partial final sets without wrapping. Review’s contextual question-mark buttons
use persistent click popovers and explain fixed browsing bands versus editable
auto-selection thresholds, manual decisions, and correction-window semantics.
`ArtifactReviewMatchConfidence` derives a presentation-only, uncalibrated 0–100
score from positive signed correlation, withholding scores for invalid windows,
unusable data, missing comparison donors, and nonfinite/undefined correlation.
Each example records the actual donor count used in its leave-one-out comparison;
one or two donors are flagged as a limited reference. These derived values do not
change review rules, choices, treatment, or replay payloads.
Event analysis also derives display-only top-five channel rankings by finite core
peak-to-peak amplitude across nonexcluded recording channels. This scope is
independent of the definition channels used for similarity. The detail view offers
Single/Top 3/Top 5 with shared time and amplitude scales and adjustable context
outside the padded window. Display context never changes correction bounds or
scores; definition-channel references overlay only where available. Wide traces
use a min/max envelope that preserves short peaks and nonfinite gaps.
The exemplar grid displays 18 events in three columns and offers Waveforms/Topomaps.
`ArtifactReviewTopography` is derived during cancellable analysis from the peak-GFP
sample within a complete core, after per-channel core centering and spatial mean
removal. At least three mapped finite good sensors are required; omitted sensors
are explicitly masked during interpolation. Tile maps use the current page's
shared signed µV scale and a low-resolution cached raster; selection shows a larger
map with its timestamp and color scale. These are display data only; existing
waveform similarity, confidence, choices, and replay definitions are unchanged.
Analysis runs in a cancellable detached task keyed by input revision, candidates,
reference membership, channels, and window geometry. Excluded/bad/interpolated
channels do not enter the statistics. Per-channel mean centering preserves
opponent ocular topographies; similarity is signed correlation of concatenated
channel profiles, not a channel average that could cancel HEOG activity.
Reference members use a leave-one-out average for scoring. Single, flat,
nonfinite, or otherwise unscorable examples stay unscored, rather than receiving
a perfect self-match. Group cards show their own average shape.

`ArtifactSpatialGrouping` derives session-only signed unit spatial vectors from
those cached peak-GFP maps. The shared ordered channel set occurs in at least
90% of available maps and must cover at least 80% of the largest map (minimum
three sensors). Every assigned event must have all shared channels, finite
nonflat values, and a complete window. Others remain unassigned. Normalization
removes spatial mean and amplitude without taking absolute correlation, retaining
polarity. Up to four task-group batches normalize vectors concurrently inside a
cancellable detached worker. A deterministic divisive spherical clustering tree
uses farthest seeds and up to twelve two-centroid refinements per split; no
quadratic pairwise matrix is allocated. Recursion is capped at 32. This is a
spatial browsing heuristic, not a validated artifact classifier or agglomerative
linkage algorithm.

The Broader/Finer slider cuts this tree at minimum centroid correlation
0.65–0.98 (default 0.85); terminal groups retain their actual reported cohesion.
Representative events are closest to the centroid. Cards are lazy-rendered, and
filtering a preview preserves the existing eighteen-example grid and waveform
scores. A three-entry actor cache retains vectors and trees keyed by the review
analysis key. Revision, candidates, definition channels/window/taper/reference,
excluded channels, and mapped sensor IDs invalidate that key. Cancellation and
key checks prevent stale publication; no partial tree is cached. Cached cuts
only traverse nodes and do not touch signal samples. Spatial previews cannot yet
split classes or modify choices/replay/cleaning; existing waveform-band splitting
remains available.

`ArtifactWaveformGrouping` adds a second, strictly nested hierarchy for a selected
spatial node. It reuses finite complete-core resampled profiles from review,
selects up to five definition channels by summed per-event energy fractions,
and resamples to at most 64 points per channel. The chosen channel set is fixed
for the family. Each candidate aligns to the spatial representative's usable
waveform (deterministic fallback if needed) using a common lag across channels:
at most 20 ms, four profile points, and 10% of the window. All shifts share a
fixed cropped interior support; per-channel centering and pooled unit norm
preserve relative channel amplitude and polarity without time warping. Invalid,
flat, or incomplete profiles remain unassigned within the parent family.

Normalization/alignment runs in up to four task-group batches, then the shared
signed-vector divisive builder produces the waveform hierarchy. Waveform nodes
retain normalized centroids for cheap mean/representative preview rendering;
spatial nodes do not allocate these optional vectors. A separate six-entry actor
cache is keyed by review analysis key plus spatial node ID. Spatial granularity
chooses the parent node, while waveform granularity only cuts its cached tree.
Detached tasks use cancellation and key guards before cache/UI publication.
Subgroup filters intersect spatial membership and cannot cross families.
Cohesion includes members themselves and is not a replacement for leave-one-out
waveform confidence. This stage does not persist subgroup choices, create split
classes, change review decisions, or affect cleaners/replay.

`DefinedArtifact.reviewState` stores candidate membership, explicit decisions,
reference event IDs, and rule settings. `events` remains the included subset
consumed by fitting/cleaning/replay. Existing inclusion is retained for candidates
without a review decision and the UI counts them as unreviewed. Rules preview
include/exclude/hold counts before applying, preserve manual choices by default,
and expose optional amplitude/duration/window gates. Undo restores the previous
automatic selection without overwriting later manual choices. Changes to input,
reference, window, or selected class discard the UI's stale undo snapshot.

Splitting moves a similarity group's candidates into a new `DefinedArtifact`.
It retains independent window/treatment/reference settings and an original-source
ID, including the ocular channel topology for threshold descendants. Split
members are removed from the parent rather than cleaned twice. A threshold
refresh with identical inputs preserves the partition; changed detection inputs
reset the root and remove its derived classes. Define/BCG rescans likewise retire
their derived classes. Continuous MAAC definitions use their specialized review
workflows instead of this event-based workspace.

Review choices and classes round-trip through the existing optional sidecar
fields. Reviewed regression averages are re-derived at execution time; reviewed
PCA-S classes use included artifact events, so R-wave fallback cannot bypass
held/excluded candidates. Threshold descendants retain the original separation
from automatic epoch-rejection selection. Source-revision/replay limitations
noted above still apply; cross-recording detector re-execution remains separate.
