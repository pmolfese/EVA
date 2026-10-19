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

`ArtifactSpatialGrouping` derives session-only unit spatial vectors from those
cached peak-GFP maps. The shared ordered channel set occurs in at least
90% of available maps and must cover at least 80% of the largest map (minimum
three sensors). Every assigned event must have all shared channels, finite
nonflat values, and a complete window. Others remain unassigned. Normalization
removes spatial mean and amplitude. Signed mode uses ordinary correlation and
retains polarity as a family boundary. Projective mode uses global Pearson sign
alignment, iteratively sign-aligns members before centroid averaging, and records
each event's orientation relative to the canonical centroid. It therefore treats
`v` and `-v` as one spatial axis without taking per-sensor absolute values or
losing the original orientation. Ocular, saccadic-spike, and corneo-retinal
classes default to projective mode; other classes default to signed mode. Up to
four task-group batches normalize vectors concurrently inside a
cancellable detached worker. The root split is computed once, then its two
independent subtrees are built as bounded concurrent tasks and deterministically
reindexed before publication. This uses parallel cores without creating a task
per node. A deterministic divisive spherical clustering tree uses farthest seeds
and up to twelve two-centroid refinements per split; no
quadratic pairwise matrix is allocated. Recursion is capped at 32. This is a
spatial browsing heuristic, not a validated artifact classifier or agglomerative
linkage algorithm.

Spatial grouping exposes eight comparison scores. Projective mode evaluates the
two whole-map orientations and keeps the better score; no neighborhood may flip
independently. `Global Pearson` uses `|r|`. `Local Pearson`
averages correlations from one overlapping nearest-neighbor neighborhood per
sensor, using the layout's 2D coordinates and a montage-scaled neighborhood size
bounded to 3–12 sensors. If geometry is unavailable it falls back to the global
score. `LPA+` and `LPC+` adapt AFNI's local-Pearson-plus costs to a fixed EEG
sensor set. Their nonlinear local term uses Fisher-transformed neighborhood
correlations with strong relationships weighted more heavily. LPA+ rewards
same contrast; LPC+ rewards opposite contrast. Hellinger affinity, symmetric
correlation ratio, and normalized information agreement stabilize both scores;
the volume-overlap term is omitted because every compared map already uses the
same sensors. `crM` is the product of the two directional binned correlation
ratios. `Spearman` applies average ranks for ties. `Robust composite` weights
global Pearson 0.30, local Pearson 0.30, Spearman 0.25, and an 85%-residual-
trimmed correlation 0.15. `Information composite` weights electrode-wise Pearson
0.55 and a distributional score 0.45; the latter combines normalized mutual
information 0.40, Hellinger histogram affinity 0.30, and symmetric binned
correlation ratio 0.30. Histograms use 3–8 montage-scaled bins. Retaining the
electrode-wise term prevents identical marginal distributions at different
locations from scoring perfectly. Signed mode preserves the selected comparison
score without trying the globally reversed map.

These metrics are AFNI-inspired rather than implementations of AFNI volume
registration: there is no affine search, image resampling, automask overlap, or
independently optimized local contrast. Their cohesion values are not calibrated
to be numerically interchangeable, so the UI labels non-Pearson values
as `score` and keeps the results preview-only.

Each node evaluates its centroid and member scores once and reuses them for
split selection and stored cohesion statistics. Farthest-seed scores are also
computed once per candidate, avoiding repeated scoring in comparator calls.
Tree completion uses a bounded budget of up to eight branch workers (limited by
active CPU count); branches smaller than 128 members stay serial. Left/right
joins preserve deterministic postorder IDs.

Review requests an initial frontier for the active cut before full completion.
Target-count frontiers expand one level ahead and use the same weighted split-gain
ordering as the full tree; cohesion frontiers expand only below-threshold nodes.
The resulting requested cut is exact, not an approximation. Already evaluated
nodes/splits are reused during completion. Partial hierarchies are marked
`isComplete = false`, never enter the hierarchy caches, and are only displayed for
the matching source/cut request. Exact requested-cut results may be cached. Cut
changes during completion wait for the final tree; suggested K is hidden until
completion. Cancellation prevents publishing a completed result or stale preview.

The grouping layer supports two cuts over the same cached hierarchy. **Cohesion**
cuts at a selected centroid score from 0.50–0.98. It can use the minimum member
score or the interpolated 10th percentile; every materialized group stores
minimum, p10, and median fit. **Force count** greedily splits the tree to K seeds,
then performs up to eight spherical/projective centroid-reassignment passes.
Representative members are fixed as anchors so no requested cluster disappears.
The suggested K is the largest drop between consecutive weighted-cohesion gains,
bounded by the requested maximum. It is a UI heuristic, not model selection.
Both modes apply a separate outlier floor after assignment; below-floor members
join the cut's unassigned IDs rather than being forced into a family.

Spatial nodes now retain normalized centroids. Centroid cards use a single scale
across the current cut. Projective centroids get a display-only deterministic
sign: the upper layout quartile is made positive when available, falling back to
the largest-magnitude sensor. Representative cards retain measured amplitude and
sign. Cards report orientation counts relative to the displayed centroid. The UI
also computes the closest centroid pair over the visible cut. This is quadratic
only in the number of displayed groups, not the event count.

Representative events remain closest to the centroid. Cards are lazy-rendered,
and filtering a preview preserves the existing eighteen-example grid and waveform
scores. Shift selects a contiguous card range; Control/Command toggles individual
cards. A preview merge rebuilds a centroid/statistics record from the union of
selected event IDs without mutating the cached tree. It can consequently feed one
nested waveform hierarchy. The Review UI presents maps in an adaptive center grid
and moves clustering and rule controls into collapsible inspector sections. The
artifact source list uses a separate multi-selection set from the primary detail
artifact: Shift selects a range, Command/Control toggles items, and a treatment
change mutates the compatible highlighted artifacts in one transaction. Dragging
a card anywhere into the artifact sidebar extracts it;
when the dragged card belongs to a multi-selection, the selected union is used.
Changing a cut invalidates session-only merges.

A three-entry actor cache retains vectors and trees keyed by the review analysis
key plus polarity and comparison modes. Revision, candidates, definition
channels/window/taper/reference, excluded channels, and mapped sensor IDs also
invalidate that key. Cancellation and key checks prevent stale publication; no
partial tree is cached. The workspace additionally retains completed analyses
(12 entries), spatial hierarchies (24), cuts (48), and waveform results (12).
Synchronous keyed lookups let a returning artifact render cached results without
waiting for the analysis → hierarchy → cut task chain. Keys include layout
positions/name and threshold candidate spans, as well as the source inputs above.
Old entries are evicted in insertion/update order. Cached cohesion cuts only
traverse nodes; target refinement
touches normalized feature vectors but never signal samples. Grouping, filtering,
and preview merges do not modify choices or replay. A separately confirmed class
move does, as described below.

Review defaults waveform-only hand definitions to **Waveform bands**. Definitions
that used a topographic reference, plus threshold ocular families, default to
**Spatial groups**. Ocular spatial review starts with polarity ignored, Global Pearson, and
a forced two-family preview. This is only a browsing default: the outlier floor
can still leave incompatible events unassigned, and the user can request one or
more families or switch back to cohesion.

`ArtifactWaveformGrouping` adds a second hierarchy nested inside one selected
spatial node or one session-only preview-merged family. It reuses finite
complete-core resampled profiles from review,
selects up to five definition channels by summed per-event energy fractions,
and resamples to at most 64 points per channel. The chosen channel set is fixed
for the family. Each candidate aligns to the spatial representative's usable
waveform (deterministic fallback if needed) using a common lag across channels:
at most 20 ms, four profile points, and 10% of the window. All shifts share a
fixed cropped interior support; per-channel centering and pooled unit norm
preserve relative channel amplitude and polarity without time warping. Invalid,
flat, or incomplete profiles remain unassigned within the parent family.

The waveform-polarity control either preserves these raw signs or applies the
parent spatial node's single retained orientation sign to the complete
multichannel profile before alignment and clustering. Projective spatial mode
defaults to orienting waveforms; signed spatial mode defaults to preserving them.
This canonicalization is session-only and never modifies signal samples, review
decisions, cleaning inputs, or replay state.

Normalization/alignment runs in up to four task-group batches, then the shared
signed-vector divisive builder produces the waveform hierarchy. Waveform nodes
retain normalized centroids for cheap mean/representative preview rendering;
signed spatial nodes can omit them, while projective spatial nodes retain their
canonical centroids so each event's orientation remains recoverable. A separate
six-entry actor cache is keyed by review analysis key plus spatial node ID.
Spatial granularity chooses the parent family, while waveform granularity only cuts
its cached tree. Detached tasks use cancellation and key guards before cache/UI
publication.
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

Splitting moves a waveform band, waveform subgroup, or union of selected spatial
families into a new `DefinedArtifact`. It retains independent
window/treatment/reference settings and an original-source ID, including the
ocular channel topology for threshold descendants. `transfer` can instead move
the same selected candidates to an existing sibling or between the threshold
blink and movement roots. Choices travel with them and both references are
rebuilt. Same-root descendants carry their threshold details while the
detector-owned root retains its complete native candidate ledger and a nil
`sourceArtifactID`, allowing identical refreshes to recognize the partition.
Cross-root events use the optional `importedCandidateSourceIDs` map; a refresh of
their origin removes them from the destination, while a refresh of the destination
first returns them to their unchanged origin. The source must retain at least one
candidate. Moved members are removed from the source rather than cleaned twice. A threshold
refresh with identical inputs preserves the partition; changed detection inputs
reset the root and remove its derived classes. Define/BCG rescans likewise retire
their derived classes. Continuous MAAC definitions use their specialized review
workflows instead of this event-based workspace.

Drag-to-extract uses the same move transaction but marks the child with the
optional `displaysAsStandaloneArtifact` review flag. The sidebar therefore shows
it as a top-level artifact while `sourceArtifactID` remains intact for duplicate
prevention and detector refresh semantics. The new artifact defaults to Standard
OBS and can receive any compatible treatment. Its spatial review starts with a
forced count of one because the drag already represents an explicit family choice;
the user can raise that count to inspect substructure. The source stays selected;
removing the extracted members changes its analysis key, so its remaining spatial
hierarchy is visibly rebuilt and re-sorted in the background.

Review choices and classes round-trip through the existing optional sidecar
fields. Reviewed regression averages are re-derived at execution time; reviewed
PCA-S classes use included artifact events, so R-wave fallback cannot bypass
held/excluded candidates. Threshold descendants retain the original separation
from automatic epoch-rejection selection. Source-revision/replay limitations
noted above still apply; cross-recording detector re-execution remains separate.
