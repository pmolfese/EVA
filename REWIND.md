# EVA — REWIND

Design for **processing history**: linear undo/redo and step-by-step scrubbing
inside each recording window, with deliberate experimentation performed by
forking to a second window.

Written 2026-08-11.

**Document role after 2026-08-25.** This file is retained as REWIND's detailed
design rationale and implementation archive. [`ROADMAP.md`](ROADMAP.md), section
**RW-1**, is the authoritative list of current behavior, remaining work, and
priority. Every execution-relevant decision, gap, proposal, and open question in
this document is represented there; dated proposals below are not independent
TODO lists.

**Where this stands after 2026-08-25.** Undo and redo work: the History tab in
the status popover shows the processing lineage, clicking a cached node restores
that point instantly, evicted supported nodes can be re-derived, and
back/forward transport is live. Fork to New Window is also built. Items 1, 4,
and 9 are built; 5 and 8 have had a substantial first pass. What is *not* built
is A/B compare, session persistence, the complete interaction menu, or the
fully hardened re-derivation contract. In particular, processed-file prefix
navigation and rapid competing rebuilds need the safeguards in ROADMAP RW-1
items 1–2.

**Behavior correction 2026-08-25.** A normal recording window no longer keeps
every replaced processing choice as a persistent sibling branch. Removing a
stage keeps its descendants temporarily so Forward is a real redo. Once a new,
different action is applied from that earlier point, EVA deletes the abandoned
future and its cached snapshots—standard linear undo semantics. Re-applying the
exact undone action follows the retained node instead of recreating it.

The underlying `EVAHistory` value remains branch-capable for decoding older
trees and copying state, but preserving an alternative is now an explicit user
action: **Fork to New Window**. Each fork receives a value-copy of the current
lineage and snapshots and then evolves independently. This resolves the open
question at the bottom of this document: the branch tree did not earn its
complexity as the default one-window behavior.

**Start with ROADMAP RW-1 if you are picking this up.** The `Open threads`,
`Next`, and `Open questions` sections below are preserved for context; their
current disposition is indexed in the ROADMAP under *REWIND material carried
into this ROADMAP*.

---

## Historical checkpoint: 2026-08-13 prerequisites and first build

The morning's status: nothing in this document had been built, but the ground it
stands on had changed. That is still the right framing for the table below, which
records what the Priority 1 refactor and the parity work handed this design.
**What has since been built is listed under *Work-item record and current disposition*, item by
item** — `EVAHistory`, the ICA payload, and the determinism audit's first pass.

The `ROADMAP.md` Priority 1 refactor completed, and a day of headless/interactive
parity work landed several things this design assumed it would have to create:

| This design needs | Now exists |
|---|---|
| One place that knows "which sheet is open" (to reopen a stage from a node) | `ActiveRecordingSheet` + a single `.sheet(item:)` (ROADMAP B3) |
| UI state reachable without a live view | Four `@Observable` models on `RecordingStore` (B4) |
| **Item 9, progress consolidation** | **Done** — `OperationProgressCenter` owns all in-flight progress; `StatusLogSnapshot` is the aggregation boundary the Queue tab needs |
| Async work that can be superseded safely | `LatestOnlyRunner` — `.completed` / `.superseded` / `.cancelled`, mutation-tested |
| One invalidation cascade instead of hand-written per-stage ones | `PipelineInvalidation` — the precursor to item 3 |
| Re-applying a step headlessly and getting the same answer | **Verified byte-identical** (see below) |

**Item 9 (progress consolidation) is complete.** The shipped answer to item 3 is
the one centralized `PipelineInvalidation` cascade shared by interactive and
headless paths. History-derived invalidation is no longer the presumed next
architecture; ROADMAP RW-1 item 14 keeps it closed unless a concrete bug shows a
safety advantage.

### Determinism is no longer hypothetical

The core premise — *the step list is the truth, the signal is a cache* — assumes
re-applying a step reproduces the same bytes. That is now tested rather than
assumed: an interactive export and a headless batch of the same file, on a script
covering filter → threshold detection → segmentation → averaging → per-epoch
bad-channel interpolation → globally-bad escalation → category grouping, produce
a **byte-identical `signal1.bin`**, identical `categories.xml`/`epochs.xml`, and
matching provenance.

Getting there required closing four divergences and two bugs nobody was looking
for. **Every one was found by comparing bytes, not by reading code** — twice the
logs agreed while the data did not. Any determinism claim this design makes
should be verified the same way.

### Determinism audit (item 5) — first pass done 2026-08-13

The three entries the parity work left open, plus a sweep of every operation in
the table below against the code. Two of the three are closed; the third stands.

**1. SME bootstrap — fixed.** `EpochSNR.standardizedMeasurementError` drew its
200 resampling iterations from `SystemRandomNumberGenerator`, so paired runs
reported values up to ~19% relative apart on categories with few trials. It now
uses `SeededGenerator` (`EVA/Core/SeededGenerator.swift`, SplitMix64) with a
fixed seed. A bootstrap needs *arbitrary* draws, not *unpredictable* ones. The
seed is a constant rather than data-derived, so the estimate does not acquire a
second hidden dependence on its input. `EpochSNRDeterminismTests` pins both
halves: paired runs now agree exactly, **and** SME still falls as trials
accumulate and still responds to the data — a seed that collapsed the resampling
would also be perfectly reproducible and completely useless.

**Reach for `SeededGenerator`, never `SystemRandomNumberGenerator`, in anything
that contributes to a reported number or a written sample.** A sweep for
`Int.random`/`shuffled()`/`arc4random` across `EVA/` found exactly one other
use, and it was already seeded (`deterministicShuffle` in the ICA solver).

**2. The `parameters`-vs-apply-path sweep — done, four more found.** The
`categoryGroups` bug was not the only one. Every view model with a `parameters`
block had inputs its apply path reads and its serialization omitted:

| View model | Was missing | What replay silently changed |
|---|---|---|
| `FilterViewModel` | `lineNoiseWindowSeconds`, `lineNoiseStrength`, `filterPNS` | adaptive CleanLine ran with the *destination's* window and strength; PNS filtering switched on or off |
| `GradientViewModel` | `skipStart`, `skipEnd`, `appliesToPNS`, `excludeHighMotion` | which TR volumes were corrected at all, and whether PNS was corrected |
| `EpochingViewModel` | `segmentField` | segmenting on detected artifacts replayed as segmenting on event codes — a different set of epochs entirely |
| `ICAViewModel` | 9 fit inputs: `varianceThreshold`, `downsampleRate`, `maxIterations`, `minimumIterations`, `convergenceTolerance`, and the whole activation pre-filter | a different decomposition |

All now serialized, with absent keys leaving the current value alone so a
pre-audit `eva.xml` replays exactly as it did before. Covered by
`ParameterSerializationAuditTests`, including the XML boundary — which is where
`categoryGroups` was found — and the legacy-inference case in gradient
(a present `motionFDThreshold` used to *imply* `excludeHighMotion`; that
inference is kept for old files and overridden by the explicit key).

`WaveletReductionViewModel` was the one clean sweep: all 13 configuration fields
were already carried.

**3. `segmentedEpochSignal` is still not patched by globally-bad escalation**, so
toggling post-processing afterwards re-derives from pre-escalation raw epochs.
Unchanged, and still not a parity issue — both paths do it identically — but
still a real edge for a tree that re-derives from cached nodes.

#### What the sweep of the operation table found

- ~~**`markBad`, `interpolateChannels`, and `ecgDetection` are declared
  operations that nothing ever emits.**~~ **`markBad` and `interpolateChannels`
  fixed 2026-08-13** — see work item 4. `ecgDetection` is still emitted by
  nothing; unlike the other two it has no decision to lose, so it is a loose end
  rather than a gap.
- **GPU-computed nodes are reproducible on a machine, not across machines.**
  `WaveletReductionConfiguration.useGPU` and
  `GradientViewModel.computeBackend` both compute in `Float` on the GPU where the
  CPU path uses `Double`, and both are documented as close-but-not-bitwise. Both
  *are* serialized, so a CPU node and a GPU node are correctly different nodes.
  The consequence for work item 2 is narrower and worth writing down: **a
  cached signal computed on the GPU should be treated as machine-local** — safe
  to keep for this session, not safe to trust from a package written elsewhere.
  The same caveat applies more weakly to every Accelerate path, ICA included.
- **The filter is deterministic, including its `.auto` paths.** Precision
  resolution is a pure function of the cutoffs and slopes, and the
  float→double fallback is data-driven but deterministic on the same data.
- **The ICA fit copy took `bandPass`'s `.iir` default silently.** The activation
  filter passed only cutoffs and the notch flag, so it was IIR no matter what
  family the user had chosen — two filters in one session, different families,
  neither recorded. `ICAFitFilterSettings` had no field for it, which also made
  it an unrecorded input to the payload: change the default and old
  `eva_ica.json` files reproduce differently. Fixed 2026-08-13 with a `Fit Type`
  control in the ICA sheet. Note the hand-written decoder that came with it —
  **a Swift default value is not a decoding fallback**, and the synthesized
  `init(from:)` would have made every pre-existing sidecar fail to decode, which
  `ICAReplayPayload.read` turns into a silent `nil`.
- **But the filter has an unrecorded input: the bad-channel set.** With average
  reference on, `EEGSignalFilter.averageReferenceInPlace(_:excluding:)` excludes
  bad channels, so the set changes the output samples while appearing in neither
  the step's parameters nor the node hash. Found 2026-08-13; the fix is the
  per-stage recording described under *Channel decisions: the carry-through
  rules*. This
  is a fifth instance of the `categoryGroups` class, and the first one found by
  asking what a *node* needs rather than what a stage serializes.
- **Motion parameters are loaded per-recording from an external file** and are
  deliberately not in `eva.xml`. Correct as scope, but it means a gradient node
  using motion censoring is not fully described by its ancestry — the motion
  file is an unrecorded input.

#### Verified by paired run 2026-08-13 15:56 / 15:57

The serialization changes were confirmed the only way that counts — an
interactive export and a headless batch of the same file, compared byte for
byte, on a script covering filter (adaptive CleanLine) → threshold detection →
segmentation → averaging → per-epoch bad-channel interpolation → globally-bad
escalation:

- **`signal1.bin` byte-identical** (3,102,312 bytes). `categories.xml`,
  `epochs.xml`, `info1.xml`, `coordinates.xml`, `sensorLayout.xml`, and
  `Events_EVA.xml` identical.
- **`eva.xml` identical apart from timestamps**, with `lineNoiseWindowSeconds`,
  `lineNoiseStrength`, `filterPNS`, and `segmentField` present in both.
- **`sme` is now reproducible** — every `average SNR` line matches exactly, where
  paired runs previously differed by up to ~19% relative. The `SeededGenerator`
  fix, confirmed on real data rather than synthetic trials.
- **The 1-based channel conversion agrees with the audit log**: `eva.xml` step
  `channels 8,21,25` against the log's `channels=8,21,25`. An off-by-one here
  would have been invisible until someone acted on it.
- `subject.xml` differs only in its Patient ID, which `MFFWriter` seeds from the
  export's package name by design.

**What that run did not exercise**, so the green result is not read as broader
than it is:

- **`markBad` was never emitted** — correctly, because all three escalated
  channels were interpolated and interpolation removes a channel from `bad`, so
  the bad set was empty. The two sets were disjoint as documented, but the
  `markBad` path needs a run where a channel is marked bad and *not* repaired.
- **Gradient's `skipStart` / `skipEnd` / `appliesToPNS` / `excludeHighMotion` are
  unverified** — absent from both files because the script had no gradient step.
  Needs a concurrent-MRI recording.

The standing rule is unchanged: the test suite cannot prove parity. Any future
change to the processing chain wants the same comparison, and twice now the logs
have agreed while the data did not.

### One thing this design should reconsider

`ROADMAP.md` B2 concluded, with trace evidence, that extracting `WaveformAreaView`
as a single struct would make things *worse*: 7+ generic parameters, and deep
generic nesting is what made the body's type metadata cost 358 ms to instantiate.
The sidebar UI in item 8 should be built as several small `View` types with value
inputs, not one large generic container.

---

## Original problem that motivated REWIND

The present implementation has history, snapshots, linear undo/redo, centralized
invalidation, and explicit window forks. This section preserves the pre-REWIND
failure mode; it is not a description of the current UI.

Undo exists per-stage, but there is no history and no redo.

Each stage owns a `clear*()` that nils its cached output and then **hand-cascades
into every downstream stage**. `clearGradientCorrection()`
(`EVA/Gradient/MRIGradientArtifactViews.swift:1034`) is the clearest example — it
manually nils `ica.cleanedSignal`, `ica.decomposition`, `filter.output`,
`filter.pnsOutput`, `filter.pnsInputSignalType`, calls
`clearAppliedArtifactCleaning()`, bumps `artifactVM.detectionRefreshToken`, then
invalidates epochs and interpolations.

Three consequences:

1. **The cascade is hand-written per stage**, so every new stage means editing
   every earlier stage's clear function. It is a correctness hazard by
   construction — a missed line leaves a stale downstream signal that silently
   contradicts the chain.
2. **Undo is destructive.** The cleared work is gone; there is no redo, and no way
   to compare "with ICA" against "without ICA" other than redoing it by hand.
3. **The chain order is knowledge held in three places** — `body`,
   `currentMFFExportSnapshot()`, and `currentProcessingScript()`
   (`EVA/IO/MFFExportFlowViews.swift`) — with a comment asking future editors to
   keep them in sync.

A history model fixes all three, because the cascade becomes *derived* rather
than written.

---

## Original visual prototype

![History sidebar beside the waveform view](docs/figures/REWIND_FIG_1.png)

This figure records the original sidebar/tree proposal. The shipped UI moved
History into the processing-status popover, and the 2026-08-25 policy correction
removed ordinary sibling accumulation. The visual language—lineage, current-node
highlight, parameter subtitles, and transport—still applies.

Figures are generated from the HTML sources beside them:

```bash
cd docs/figures && for n in 1 2; do "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --force-device-scale-factor=2 --hide-scrollbars --screenshot="REWIND_FIG_$n.png" --window-size=760,700 "file://$PWD/REWIND_FIG_$n.html"; magick "REWIND_FIG_$n.png" -trim +repage -bordercolor '#f1efe8' -border 32 "REWIND_FIG_$n.png"; done
```

---

## Core model

**The step list is the truth. The signal is a cache.**

A node is not "a saved copy of the data". A node is the ordered list of steps
that produced it, plus whatever subject-specific payload is needed to re-apply
those steps exactly. The signal at that node is derived, cacheable, and
evictable.

This is the whole design. Everything below follows from it.

```
Node
  id            stable hash of (parentID, operation, sorted params, payload digest)
  parent        Node?  — nil for `raw`
  step          EVAProcessingStep     (already exists, already Codable)
  payload       subject-specific data needed for exact re-application
  cache         MFFSignalData?        (evictable; never the source of truth)
  preview       decimated signal for display — cheap, cached far more freely
  computeCost   measured wall time of the first computation; drives eviction
  label         user-editable, defaults to a rendering of the step
```

Navigating to a cached node restores its `PipelineSnapshot`. A supported evicted
node is rebuilt from a valid source and then snapshotted. Undo is "navigate to
parent" and redo is "navigate to the child you came from". The value type can
represent a second child for old/copied histories, but ordinary window history
is linear; retained alternatives use Fork to New Window.

### Why the payload matters

Recomputation only works if steps are **deterministic**. Several are not, and
this is the single most important design constraint:

| Operation | Deterministic? | Payload needed |
|---|---|---|
| `filter` | yes | none |
| `waveletReduce` | yes | none |
| `thresholdArtifactDetection` | yes | none |
| `segment` / `baseline` / `average` | yes | none |
| `mriGradientCorrection` | yes, given same params | none |
| `interpolateChannels` | yes, given the channel list | channel indices |
| `markBad` | n/a — it *is* a decision | channel indices |
| `icaClean` | **yes, in EVA** — see below | `unmixingMatrix` + `mixingMatrix` + excluded indices |
| `artifactClean` | **no** — user-drawn templates | template/event definitions |
| `bcgDetection` | subject-specific | detection parameters + marks |

Every payload is small. Nothing here approaches the size of a signal.

**This overlaps `REPORTS.md` work item 1** — persisting ICA state is a
prerequisite for both the report and the history tree. Do it once, serve both.

### ICA payload — settled 2026-08-13, and three things above were wrong

Built as `ICAReplayPayload` / `ICAReplay` (`EVA/ICA/ICAReplayPayload.swift`),
written into the package as `eva_ica.json` beside `eva.xml`, covered by
`ICAReplayPayloadTests` — including the load-bearing one: a payload round-tripped
through disk and re-applied produces **exactly equal `Float` samples**, not
samples within a tolerance.

Three corrections, each checked against the code rather than reasoned from first
principles:

1. **`mixingMatrix` is required; the table said `channelMeans`.**
   `ICAArtifactDetector.cleanedSignal` factors the artifact as
   `mixing[:,excl] · (unmixing[excl,:] · x)` — it reads *both* matrices. Mixing is
   mathematically `pinv(unmixing)` (with `unmixing = R·W`, `mixing = dewhitening·R⁻¹`,
   the identity holds exactly), but recomputing a pseudo-inverse would not
   reproduce the same floating-point bytes. Persist both: `2·k·n` doubles,
   ≈41 KB at 128 ch / 20 components, ≈1 MB at a full-rank 256 ch.
2. **`channelMeans` is not the payload it looks like.** `cleanedSignal`
   recomputes the means from the *activation* data it is handed; the fitted means
   never enter the arithmetic (only `channelMeans.count` is read, as a length
   clamp). They are persisted anyway — they are the right thing for reports and
   source reconstruction — but they are not why replay works.
3. **`icaClean` is not stochastic in EVA.** The solvers are seeded: identity
   starts for Infomax/FastICA, a fixed-constant LCG for the Picard orthonormal
   start, and a `deterministicShuffle`. `ICAArtifactDetectorTests
   .isDeterministicAcrossRuns` already asserts bit-identical unmixing matrices
   across two fits of the same input, for both Picard and Picard-O.

   That third correction changes the *design*, not just the prose. If the fit
   were stochastic, a missing payload would be an unrecoverable loss and the
   node would have to be marked cache-only. Because it is deterministic, **a
   payload miss degrades to a refit** — slow, but correct — so `eva_ica.json`
   can be a plain optimization with a safe fallback rather than a hard
   dependency. That is a much cheaper promise to keep.

   The payload still earns its place: re-applying is two skinny matmuls against
   a full eigendecomposition plus an iterative solve; determinism holds for a
   given binary on a given machine but not across Accelerate versions or
   microarchitectures, and the fit runs in `Float`; and **the exclusion set is a
   human decision that no amount of refitting recovers.**

**One real bug fell out of this.** The interactive removal path rebuilt the
band-passed activation copy and, on filter failure, *swallowed the error and
carried on with a `nil` activation* — which does not fail, it reconstructs the
sources from the unfiltered base and returns different samples. Both paths now
go through `ICAReplay.activationSignal`, and both abort rather than substitute a
different activation. Same shape as the four parity divergences: no error, just
quietly different data.

**Re-rooted 2026-08-13.** The apply orchestration was on `WaveformView`, so
`ProcessingCore` could not perform `icaClean` at all. The pipeline half now lives
in `ICAComponentRemoval` (`EVA/ICA/ICAComponentRemoval.swift`) — reconstruct via
`ICAReplay.apply`, then commit and cascade — and both paths run it.
`ProcessingCore` gained an `.icaClean` case, and `HeadlessBatchProcessor` reads
**the input package's own** `eva_ica.json` to feed it.

**The safety property is structural, not a check.** The payload comes from the
file being processed, never from the file the script came from, so a script
copied across subjects arrives without a sidecar and nothing happens. Carrying
one subject's unmixing matrix onto another's electrodes would produce plausible,
wrong data — the worst failure mode in this design.

Deliberately *not* folded into the shared core: re-applying the filter afterwards.
The interactive path does it because the user already had a filter on the old
base; in a script that is the next step's job, since `currentProcessingScript()`
emits `filter` after `icaClean`. Folding it in would filter twice headlessly.
Viewport, sheet, debug report, and the replay gate stay with the caller that has
a view — the same split PSA unification settled on.

The batch setup gate moved with it: `icaClean` counted as a decision that forces
a window, which is right only while the decision is *unmade*. It is now checked
per **file** — when every selected package carries its own sidecar, the removal
is already recorded and re-applying it asks nobody anything. Per file rather than
per script, because "this script contains ICA" says nothing about whether a given
file can re-apply it.

**One thing that looked like a bug and is not**, recorded so it is not "fixed"
later: with no payload, `ProcessingCore` *skips* `icaClean` rather than stopping.
That reads like a silent omission and is not one — a non-replayable step is
classified `.skip`, and the batch config pane lists it as "Recorded for
provenance only", unchecked. The user has already been told it will not run.
Making the absent-payload case stop would divert batches that complete today into
windowed replay for no reason.

---

## Navigation semantics: undo/redo, replace, fork

The data structure can represent branches, but the recording window applies a
linear policy over it. Node identity still makes exact redo and cache reuse
cheap; it no longer implies that every superseded choice remains visible.

| Intent | Mechanism | Old subtree | Cost |
|---|---|---|---|
| **Undo/redo** — click back, click forward | navigate; node ID unchanged so the cache is still valid | retained until replacement | free if cached |
| **Replace** — undo or remove, then apply something different | prune the abandoned future, then append the replacement | discarded immediately, including snapshots | compute the replacement only |
| **Fork** — "try it the other way" | Fork to New Window, then edit independently | retained in the other window | no initial recompute; copy-on-write state |

Consequences worth designing around:

- Undo does not destroy redo. Destruction happens only when the operator makes a
  new choice from an earlier point, which is the familiar document-editor rule.
- Replacement pruning is immediate, not memory-pressure policy. Otherwise the
  History rail continues to imply that superseded processing remains part of the
  active work.
- Replay must never recompute when a valid snapshot for the exact source and
  state exists. Node identity is necessary, but ambient channel decisions and
  external inputs must also be captured before identity alone can guarantee the
  bytes; that is ROADMAP RW-1 item 3.
- The A/B case ("with and without ICA") belongs in two forked recording windows,
  where both alternatives are visible and neither silently changes the other.

---

## Memory: original cache-policy design

Snapshots and a byte budget shipped; manual pinning, measured cost, disk spill,
and the preview tier did not. Treat the policy below as rationale for ROADMAP
RW-1 items 7, 11, and 12, not as current behavior.

A cached signal is large. 128 ch × 1000 Hz × 20 min × 4 bytes ≈ **614 MB**.
256 ch × 60 min ≈ **3.7 GB**. Caching every node is not an option.

Policy:

- **Always cache**: `raw` (or memory-map it from the package) and the current node.
- **Pin manually**: user can pin a node; pinned nodes stay resident. Pin the
  expensive ones — post-gradient, post-ICA.
- **Evict LRU**, spilling to the scratch directory rather than dropping outright
  when disk is cheaper than recompute.
- **Auto-pin expensive stages** by measured wall time: if a step took >30 s, keep
  its output by default.
- **Show the cost.** Each node in the History popover should say whether navigating to it is
  instant (cached), fast (a few cheap steps), or slow (needs a gradient re-run).
  Surface that before the click, not after.

Recompute cost is bounded because the chain is short — at most ~8 stages — and
the expensive ones are exactly the ones worth pinning.

### Making it feel seamless

Three levers, in rough order of payoff.

**1. Cache at display resolution, not full rate.** `WaveformView` draws decimated
data anyway. A 10× decimated cache is ~60 MB instead of ~614 MB, so a dozen nodes
fit in the memory of one. Navigation repaints instantly from the decimated cache
while the full-rate signal recomputes in the background — needed only when the
user *acts* on the data (export, next processing step, ICA fit), not when they
merely look at it. `Downsampler` already exists. This is probably the single
biggest lever on perceived responsiveness.

**2. Measure, never guess.** Store measured wall time on every node the first
time it is computed. The policy is then self-tuning — no hardcoded "gradient is
expensive" table that is wrong on a different machine or a longer recording.
Eviction becomes a standard cost-per-byte decision: evict the lowest
`recomputeCost / bytes` first, which keeps FASTR and ICA outputs resident while a
filter output (cheap to redo, same size) is dropped freely.

Rough thresholds, subject to the measured numbers:

| Estimated recompute | Policy |
|---|---|
| < ~100 ms | never cache — it is free |
| ~100 ms – ~2 s | let cost-per-byte decide |
| > ~2 s | always try to cache; auto-pin |

**3. Speculate on the retained redo child.** Sitting at node N after undo,
background-compute its retained child so click-forward is instant. Alternatives
that must coexist belong in forked windows; each window can pin its own current
state. Cancel speculation when the user moves elsewhere — `ProcessingQueue` and
the existing cancellation checks (`try Task.checkCancellation()`) already
support this.

---

## Granularity

Settled for ordinary recording windows; threshold editing is the remaining
edge case (ROADMAP RW-1 item 5).

**Proposal: a node is a step that changes the derived signal, or changes what
gets exported.** That means `apply filter`, `remove ICA components`, `mark bad`,
`interpolate`, `segment`, `turn artifact correction off` all get nodes. Panning
the waveform, changing a display scale, or opening a sheet do not.

Two things deserve care:

- **Toggles.** "Turn artifact correction off" changes the derived state, but it
  is an undo-shaped action and therefore navigates/removes rather than appending
  an inverse operation. Node identity does **not** automatically collapse
  `off → on`: ancestry makes that a different node. Linear replacement semantics
  are what prevent six flips from creating six persistent states.
- **Parameter tweaking.** Adjusting a filter cutoff four times while previewing
  should produce one node, not four. Debounce: only commit a node when the stage
  is *applied*, not while its sheet is open. EVA already distinguishes preview
  from apply in the wavelet and artifact flows.

---

## Original proposal: Queue and History as one state machine

**Current correction.** The shipped tabs are adjacent, not two renderings of
the same node lifecycle. Queue shows active operations and the status log;
History shows committed processing lineage. The lifecycle/work-class design
below remains useful if full-rate background rebuilds later need it, but it is
not the present model. Linear replacement also means the old proposal to keep
stale descendants visible does not describe ordinary current behavior. See
ROADMAP RW-1 item 8.

The original proposal treated the tabs as two renderings of the same objects: a
queued operation would have been a node without its signal yet.

![Queue and History tabs](docs/figures/REWIND_FIG_2.png)

Every node has a lifecycle:

```
stale → queued → running → cached (preview) → cached (full-rate)
```

History renders that lifecycle **positionally** (where in the tree). Queue
renders it **temporally** (what order, how long, what is blocking). The count
badge on the Queue tab is the number of nodes in `queued` or `running`.

### Work classes and priority

Pending work must say *why* it is waiting, because that determines cancel
semantics:

| Class | Shown as | Cancelling it |
|---|---|---|
| User-initiated | "queued by you" | also cancels everything downstream |
| Dependency of user work | "waiting on ICA fit" | cancels the parent request |
| Speculative (neighbor precompute, full-rate rebuild) | de-emphasized, "background" | free and silent |

Priority order: user-initiated > dependency-of-user > speculative. **Speculative
work is always preemptible** — it must yield the moment real work arrives.
`ProcessingQueue` and the existing `try Task.checkCancellation()` checks give us
most of this.

### Original proposal: stale descendants stay visible

When an ancestor changes, its descendants do not disappear from the tree. They
render dashed and greyed as `stale · queued`. This is what makes "you changed
step 2, so steps 3 and 4 will be different" legible rather than surprising, and
it gives the user something to click to prioritise.

### Resolving the preview race

The two-tier cache creates a window where the display shows node N but the
full-rate signal is not ready. Rather than blocking:

- Say so plainly in the History popover — "viewing a preview; edits will queue".
- Scrolling, zooming, and inspection work immediately off the preview.
- Any action needing real samples (apply a stage, fit ICA, export) is **enqueued**
  against the full-rate rebuild rather than reading a partial buffer.

Reading a not-yet-valid buffer is the same class of bug as the current
hand-written cascades. Making the queue the only path to the full-rate signal is
what prevents reintroducing it.

### Progress consolidation that did ship

Progress was formerly per-view-model. `OperationProgressCenter` now consolidates
in-flight progress, and the Queue tab is its single status-area consumer. That
completed work does not imply that queued operations and history nodes share one
lifecycle.

This is a simplification, not an addition — and it is a natural companion to the
Priority 1 Observation work, since it removes a set of frequently-ticking
`@Published` properties from view models whose bodies are expensive to
re-evaluate.

---

## Interactions

This section records the intended Mac interaction model. The shipped primary
view is the **History tab in the processing-status popover**, not a sidebar.
Click navigation, back/forward transport, and **Fork to New Window** are built.
Keyboard undo/redo, pinning, rename, delete-future, reopen-stage,
export/report-from-node, cost hints backed by measured `computeCost`, and A/B
comparison remain proposals tracked by ROADMAP RW-1 items 7, 9, and 10.

**Click a node** — navigate to it. It is instant when cached; supported evicted
nodes currently launch re-derivation. The latest-only/source-valid safeguards
and truthful cost UI are still required. This is undo and redo: clicking the
parent is undo, clicking back down is redo. No separate undo stack.

**Right-click a node** — intended context menu. Only **Fork to New Window** is
currently wired:

| Item | Behavior |
|---|---|
| Fork to New Window | copies this point into a second independently editable window |
| Pin / unpin | force the signal resident, exempt from eviction |
| Rename… | user label, replacing the default step rendering |
| Compare with Fork… | future A/B view against a related forked window |
| Export from here… | export the package at this node, not at the tip |
| Report from here… | generate an `EVAReport` for this node (see `REPORTS.md`) |
| Delete future | prune this redo node and its descendants; disabled on ancestors of current |

**Hover a node** — proposed: show the cost hint (cached / fast / needs a
gradient re-run) only after measured `computeCost` is populated.

**Double-click a step's parameters** — proposed: reopen that stage's sheet with its recorded
parameters loaded. Applying with changes replaces the redo chain in this window;
applying unchanged follows the retained node or is a no-op.

**Transport controls** — step back, step forward, replay to tip. Forward follows
the retained redo child, so back-then-forward is always a round trip until a
different action deliberately replaces that future.

**Keyboard** — proposed: `⌘Z` / `⇧⌘Z` map to step back and step forward, so the
feature is reachable without the popover open and behaves like a Mac document.

### A/B compare

The payoff of the whole design, and worth building explicitly rather than leaving
users to align two windows by eye. Selecting two related forked states offers:

- overlay both signals in `WaveformView` in contrasting colors
- difference trace (A − B)
- side-by-side SNR / channel-health metrics for the two nodes
- for epoched nodes, butterfly plots side by side

"What did ICA actually buy me?" becomes a two-window question: fork before the
choice, apply the alternative independently, then compare the windows. This also
feeds `REPORTS.md`: a comparison report between two explicitly forked states of
one recording is a genuinely novel artifact to offer.

---

## Machinery that already exists

Most of this is built.

| Need | Existing |
|---|---|
| Node payload type | `EVAProcessingStep` / `EVAProcessingScript` — already `Codable`, already serialized as `eva.xml` |
| Canonical chain order | `currentProcessingScript()`, `currentMFFExportSnapshot()` |
| Applying a step list without UI | `HeadlessBatchProcessor`, `ProcessingCore` |
| Walking a script with pauses | `ReplayController` — this *is* fast-forward, with `.auto` / `.review` / `.decision` gates already classified by `ReplayInteraction` |
| Which steps need human input | `EVAProcessingStep.replayInteraction` |
| Per-stage teardown primitives | the existing `clear*()` / `resetForClose()` functions |
| Provenance rendering | `EVAProcessLog` |

`ReplayController` is the standout. It already walks an ordered script, applies
each step, and gates on the ones needing a decision. Fast-forward is that,
pointed at a node's ancestry instead of an imported script.

---

## Work-item record and current disposition

This numbered list is retained because later design notes refer to it. The live
TODO ordering is ROADMAP RW-1.

1. ~~**`EVAHistory`**~~ — **done 2026-08-13** (`EVA/Pipeline/EVAHistory.swift`,
   `EVAHistoryTests`). A pure value type: no SwiftUI, no view models, no signals,
   no I/O. Nodes, current pointer, `apply`/`navigate`/`stepBack`/`stepForward`/
   `deleteBranch`, per-node annotations (label, pin, measured `computeCost`), and
   `currentScript` — the tree's answer to "the chain order is knowledge held in
   three places".

   Node ID is `SHA-256(parentID, operation, sorted parameters, payload digest)`,
   over **length-prefixed** fields rather than separator-joined ones: a parameter
   value containing the separator would otherwise let two different parameter
   sets hash identically, which in a content-addressed tree means serving one
   node's cached signal for another's. Same hazard the `categoryRegex`
   serialization avoided with one key per field. Excluded from the hash:
   `EVAProcessingStep.id` and `appliedAt` (a UUID and a wall clock would make
   every node unique), `note`/`rejections`/`replayable` (prose, a result, a
   classification), and the annotations (renaming a node must not move it).

   **One design correction, and it changes behavior rather than prose.** This
   document says a user flipping a toggle six times should not produce six nodes,
   and that the ancestry hash makes that automatic. Half true. Appending
   "correction off" then "correction on" yields the ancestry `[…, off, on]`,
   which is a genuinely different node from `[…]` — same samples, different
   identity, no deduplication. Only re-applying the *same* step at the *same*
   parent deduplicates. So **an undo-shaped action must be expressed as
   `stepBack()`, not as appending an inverse step**; that is the rule that keeps
   the tree finite while someone explores, and both halves are pinned in the
   tests.

   Also settled while building it: `eva_history.json` should be written with
   `EVAHistory.encoder()`, which uses `.deferredToDate`. `.iso8601` truncates at
   whole seconds and `.secondsSince1970` re-bases by 978307200 and loses low
   mantissa bits, so neither decodes back equal to what wrote it.

   **Recording landed 2026-08-13 — as `adopt`, not as per-apply-site calls.**
   Every pipeline mutation now has its half off `WaveformView` — the five stage toggles (`PipelineStageToggles`),
   ICA removal (`ICAComponentRemoval`), averaging (`PSAAveraging`), and
   artifact cleaning (`ArtifactCleaningCore`), joining the gradient/filter/
   wavelet/segment applies that were already VM-level. That is what makes the
   tree *recordable*. In the event the recording is driven from the canonical
   chain rather than from those call sites — see the `adopt` note in item 8 for
   why application order is the wrong thing to write down — but the extraction
   still pays: those commits are where measured `computeCost` has to come from,
   and cost is what work item 2's eviction policy runs on.

   **Still owed before this is a full record:** measured per-node `computeCost`
   and the remaining interaction affordances. Navigation itself is built.

   The low-level value remains branch-capable, but ordinary recording history
   now prunes a divergent redo chain. Deliberate branching is the separate
   Fork-to-New-Window action, not an accidental consequence of changing a field.
2. **Signal cache** — two tiers (decimated preview, full-rate), pinning,
   cost-per-byte eviction, scratch-disk spill, measured `computeCost` per node,
   and retained-redo speculation.

   **Partly superseded 2026-08-13, and the design had a false premise.** This
   document's model — *the step list is the truth, the signal is a cache* — reads
   as "navigating means re-applying the steps", and everything in this item
   follows from that. It is the right model for **reproducing a package
   elsewhere**, which is what the payload and batch work serves. It is the wrong
   model for **undo/redo inside a session**, where re-running a gradient
   correction to answer a click is absurd when the answer is still in memory.

   So navigation now *restores* — `PipelineSnapshot`
   (`EVA/Pipeline/PipelineSnapshot.swift`) captures every stage output plus the
   channel decisions as the chain moves, and clicking a node puts them back.
   Instant, and it needs no payloads at all.

   Two things this cost less than the document assumed:
   - **Not 614 MB per node.** `MFFSignalData.data` is `[[Float]]` — copy-on-write
     — so a snapshot holds a *reference* to the buffer the view model already
     holds. Nodes sharing an unchanged filter output share one allocation. Real
     memory is spent only on signals nothing else references.
   - **No eviction policy needed to start.** A byte budget with oldest-first
     eviction (never the current node) is enough; the cost-per-byte machinery can
     wait for a measurement rather than a guess.

   **Current disposition.** Evicted-node re-derivation is built for supported
   steps. It still needs latest-only/source-valid commits, a safe rule for
   processed-file prefixes, honest supported-step/failure UI, and channel-state
   carry-through. The memory preference, measured `computeCost`, truthful
   pin/eviction behavior, and optional preview/disk tiers remain open (ROADMAP
   RW-1 items 1, 2, 3, 7, 11, and 12).
3. **Generic invalidation — original proposal, superseded unless evidence
   reopens it.** The proposal was to derive "everything after node N is invalid"
   from the history tree and collapse stage-specific clears into navigation.
   The shipped architecture instead defines the cascade **once**, in
   `PipelineInvalidation` (`epochsAndDerived`, `interpolations`,
   `appliedArtifactCleaning`, `downstreamOfBaseSignalChange`,
   `downstreamOfFilterChange`, `downstreamOfWaveletChange`), used by both the
   interactive and headless paths. This centralized shared cascade is the
   current design; do not create a second invalidation authority without a
   concrete correctness case (ROADMAP RW-1 item 14). Note the
   deliberate asymmetry encoded there — filter clears applied artifact cleaning,
   wavelet does not, because cleaning sits between them in the chain.
4. **Payload persistence** — **ICA and channel decisions done 2026-08-13.**
   - `ICAReplayPayload` / `eva_ica.json` — see the ICA payload section above.
   - `ChannelDecisionSteps` (`EVA/Pipeline/ChannelDecisionSteps.swift`) closes
     the hole the determinism audit found: `markBad` and `interpolateChannels`
     were declared operations that **nothing ever emitted**, so those decisions
     reached disk only as prose in `log_eva_*.txt` and the rail could not show
     the `mark bad · 4 ch` node this document's own figure has in it. Both are
     now written into `eva.xml`, 1-based to match the log and the UI.

     **Emitted `replayable: false`, deliberately.** Replaying "interpolate
     channel 8" onto another subject would repair a channel that may be perfectly
     good there. Making them replayable is a product decision, not a
     serialization one, and it should be taken on purpose.

     **Two things to settle before making them replayable.** First, position:
     they are inserted immediately before `segment`, which is right for
     interpolation (that is exactly where `currentMFFExportSnapshot()` applies
     it) but **not obviously right for `markBad`** — wavelet reduction reads
     `channels.bad` as its excluded set, and that runs upstream of this position.
     A replay engine trusting the position would exclude nothing from a wavelet
     pass it should have. Second, the interpolation *recipe* (neighbour indices
     and spline weights) is still not persisted; it does not need to be, because
     spherical-spline interpolation is deterministic given the channel list, the
     bad set, and the electrode positions — but that reasoning should be
     re-checked rather than inherited.

     One divergence closed on the way: `HeadlessBatchProcessor` wrote back the
     script it was *handed*, so a batch run whose PSA escalation marked and
     interpolated channels described a run that did not happen. Both paths now go
     through the same insertion.

   - `ArtifactReplayPayload` (`EVA/Artifacts/ArtifactReplayPayload.swift`) —
     `eva_artifacts.json`, read by a `ProcessingCore.artifactClean` case and by
     the per-file batch gate, on exactly the terms ICA uses.

     **It stores definitions, not waveforms**: event times, channels, window,
     method and its parameters. The averaged template is re-derived from the
     signal at apply time. That is not a size optimisation — it is already how
     five of the six cleaning methods work. OBS, SSP/PCA, and the local-template
     family never read a stored average; only `applyTemplateRegression` did, and
     it was the odd one out.

     **Re-deriving is also more correct, and this is the one part that changes
     results.** `PipelineInvalidation.appliedArtifactCleaning` clears the applied
     state on a signal change but keeps the drawn `average`, so a template drawn
     before a filter was applied would be subtracted from post-filter data —
     describing samples that are no longer there. Re-derivation ties the template
     to the signal it is subtracted from, which is what regression means. **Wants
     a paired run.**

     Two things that had to be got right: re-derivation must use the *detector's*
     averager, not the preview's (they centre on different event fields and one
     detrends — `ArtifactTemplateDetector.templateAverage` is now the exposed
     canonical one); and `DefinedArtifact` is `Codable` by **synthesis** rather
     than an explicit `CodingKeys` list, so a cleaning parameter added later is
     persisted automatically. An explicit key list is precisely the shape that
     lost `categoryGroups`, `segmentField`, and nine ICA fit inputs.

   Work item 4 is now closed for every payload the pipeline produces.

   **The `markBad` / interpolation carry-through rules** these decisions
   imply are designed but not built — see *Channel decisions: the carry-through
   rules* below, after the work-item list.

5. **Determinism audit** — **first pass done 2026-08-13**; see the audit section
   above for what it found (the SME seeding fix, four more
   serialized-vs-read gaps, and the GPU/machine-locality caveat for the cache).
   Not finished: nothing here proves interactive/headless parity, which needs a
   paired run and a byte comparison rather than a green test suite.
6. **Session persistence — designed, not built.** This was a one-line placeholder here; now has a real
   design, see *The EVA cache: content-addressed snapshots and normalized
   imports* below. Short version: a private, non-user-facing cache holds
   snapshots content-addressed by `EVAHistoryNodeID` (so an evicted snapshot
   is a disk read away instead of gone) and normalized copies of non-MFF
   imports (so fork and reopen do not depend on a BrainVision file's original
   scattered access). A slim `eva_history.json` sidecar may still travel with
   the package for the tree structure itself — small and portable, versus
   the cache's large and disposable snapshots — see that section's open
   questions.
7. **Queue integration — deferred original proposal.** Node lifecycle states,
   the three work classes with preemptible speculation, and enqueueing user
   actions against a pending full-rate rebuild remain a possible future model.
   Today Queue and History are adjacent systems; see ROADMAP RW-1 item 8.
8. **UI** — the Queue / History status popover: lineage rail, current-node
   highlight, stale-descendant rendering, transport controls, per-node cost hint,
   pin toggle, labels, and the right-click menu.

   **Navigation landed 2026-08-13.** Rail rows are clickable and the History tab
   has working back/forward transport; clicking restores that node's snapshot.
   A node without a snapshot originally rendered disabled. Supported evicted
   nodes now initiate re-derivation; the rail still needs accurate availability,
   progress, failure, and cost communication.

   **The branch-rendering pass landed before the policy was simplified.** The
   rail can still decode and display older branch-capable histories, but a normal
   window now presents one lineage plus a retained redo path. New alternatives
   are created through Fork to New Window rather than accumulating siblings in
   this rail.

   **First pass done 2026-08-13**, and it lives in **the status
   popover as a Queue / History tab view** — the layout in
   `docs/figures/REWIND_FIG_2.png` — not in a sidebar.
   `ProcessingStatusPopoverView` (`EVA/Waveform/ProcessingStatusPopover.swift`)
   hosts it; `HistoryRailNodeList` / `HistoryRailRow`
   (`EVA/Waveform/HistoryRailView.swift`) draw the trunk, dots, connectors,
   per-node parameter subtitles (`HistoryStepSummary`), current-node highlight,
   and pin indicator. Click navigation and back/forward transport have since
   shipped. Fork to New Window is the only context-menu action currently wired;
   the other interaction ideas are tracked in ROADMAP RW-1 items 7 and 9.

   **It began as a 260 pt sidebar left of the waveform and that was wrong.** It
   worked, but it spent permanent horizontal room on something consulted
   occasionally, and the waveform is what people are actually looking at. The
   status area already owns "what is this app doing", already opens a popover,
   and is already where progress appears — so the tree costs no waveform width
   and sits beside the queue. They are adjacent status views, not currently two
   renderings of one shared node lifecycle.

   **This also fixed an older problem.** The status area used to switch between a
   live-progress popover and a status-history popover depending on whether
   anything was running, so whichever one you wanted, you got the other. Both are
   temporal, so both are now the Queue tab: running operations on top, the
   message log beneath. Nothing was lost — the log's Clear button and full
   scrollback came across — and the popover opens on Queue when something is
   running, History when nothing is.

   **Linear replacement correction, 2026-08-25.** The canonical chain is still
   folded on every change and the unchanged prefix still resolves to existing
   nodes. A strict prefix move retains descendants for Forward; a later divergent
   chain prunes those descendants and their snapshots before applying the new
   steps. Widening a filter after undoing a narrower filter therefore leaves one
   filter in this window's History, not two siblings.

   **Driven from the chain, not from each apply site — and that is the correct
   choice, not a shortcut.** Applying a stage upstream of one already applied,
   gradient after filter, invalidates the downstream stage; so the order things
   *happened* in is not the order that describes the resulting signal. A node
   appended in application order would claim filter → gradient produced this data
   when gradient → filter did. The canonical script is the one that reproduces
   the bytes, and reproducing the bytes is the whole promise of a node ID.

   ICA's payload digest is threaded in alongside, because two removals that
   excluded different components carry *identical* portable parameters — without
   it they would collapse to one node and navigating there would serve the wrong
   cached signal.

   The rebuild hangs off an `.onChange` of a signature made of stage-output
   `dataRevision`s, not off the body. `dataRevision` is what makes that correct
   rather than merely cheap: re-running a stage always produces new sample data,
   so a re-apply with different parameters is caught even though the signature
   never reads a parameter — and a parameter edited *without* applying correctly
   changes nothing.

   **Sequencing note for whoever picks this up.** Doing the rail before the
   cache, before navigation, and before recorded nodes was deliberate: this
   document flags granularity as "the one most likely to be got wrong", and a
   real rail beside a real recording answers it by looking rather than by
   reasoning. The questions it is there to settle — does "turn artifact
   correction off" deserve a node, does a re-applied filter, is one node per
   stage the right density — are cheaper to answer now than after the cache is
   built around an assumption.

   Two things worth knowing before extending it:
   - **`ImageRenderer` renders nothing inside a `ScrollView`.** A headless render
     of the whole popover shows its tab bar and footer with empty space between,
     which looks exactly like every row collapsing. That is why both tabs'
     contents are separate views (`HistoryRailNodeList`, `QueueTabContent`) and
     why `HistoryRailRenderTests` checks chrome and content separately. Worth
     remembering, because it cost a wrong diagnosis here.
   - **The first version of that render test passed on a blank rail.** It counted
     distinct colours across the whole image, and the header, footer, and
     dividers alone cleared the threshold. It now measures ink between the
     chrome, and separately in each half, so rows that collapse onto one another
     fail too.
9. ~~**Progress consolidation**~~ — **done 2026-08-13.**
   `OperationProgressCenter` on `RecordingStore` owns all in-flight
   `OperationProgress`, keyed by source; `WaveformView` and the status area read
   that one list instead of reaching into view models by name. A new stage joins
   by *reporting*, not by editing the status view.
10. **A/B compare** — overlay, difference trace, and side-by-side metrics for two
    selected nodes.

---

## Channel decisions: the carry-through rules

Designed 2026-08-13, not yet built. Bad-channel marks and interpolation recipes
behave unlike every other step — they are *ambient decisions* whose effects are
re-derived, not transforms positioned in a chain. Pretending otherwise is what
made their placement in `ChannelDecisionSteps` "not obviously right".

**They are an input to other stages, not a transform of their own.**
`FilterViewModel.apply` passes `store.channels.bad` to
`EEGSignalFilter.averageReferenceInPlace(_:excluding:)`; wavelet reduction takes
it as its excluded set; PSA reads it for per-epoch interpolation and escalation.
So with average reference on, **the bad set changes the filter's output samples**
— and it appears in neither the filter step's `eva.xml` parameters nor the filter
node's hash. Two filters with different bad sets produce different data and hash
to the same node. Same class as the ICA payload gap, and it means a cached signal
can be served for a state that did not produce it.

**The rule:** emit the absolute bad set immediately before each stage that reads
it, recording the set as it was *when that stage ran*.

Everything else falls out of that rather than needing its own mechanism:

- **Marks coalesce when nothing consumed them in between.** Mark 8, then mark 16
  with no stage between → one node, `markBad{8,16}`.
- **They stay separate when a stage ran between.** Mark 8 → filter → mark 16
  gives `markBad{8}` → `filter` → `markBad{8,16}`, because the filter genuinely
  ran with only `{8}` and its node has to say so.
- **Absolute, never incremental.** An incremental encoding reads better as a
  chain but makes *unmarking* inexpressible: an inverse step does not deduplicate
  (see the toggle rule above), and `stepBack()` only works if the mark was the
  last thing you did. Absolute keeps unmark trivial — a node with a smaller set.
- **Replacement stays linear.** Under the recording model, changing
  `markBad{8}` to `markBad{8,16}` at the same point replaces the earlier redo
  future. Sets separated by a stage remain separate ancestors because they
  describe genuinely different stage inputs; that is not branch fan-out.

**Prerequisite:** `currentProcessingScript()` builds from current state and
cannot reconstruct what was bad when the filter ran. Each stage has to record the
bad set it ran with (`filter.appliedBadChannels` and siblings). That is also the
fix for the identity gap, since the recorded set is what belongs in the step's
parameters and therefore in the node hash.

**Scope when this is built** — one pass, because the pieces share a prerequisite
and a verification run:

1. Per-stage bad-set recording, into the step parameters and the node hash.
2. `markBad` emitted before each stage that reads it, absolute, with the
   coalescing behaviour above falling out.
3. Interpolation recipes surviving base-signal changes (`isEmpty` fix included),
   and re-deriving when the bad-or-interpolated set changes.
4. The status-line notice, its error tier for a failed re-solve, and the
   lost-interpolation state behind the warning triangle on the channel row.

All four change what the exported samples are, so they want **one paired run
together** rather than four separately — a single byte comparison covers the lot,
and a divergence is easier to attribute when the change is one coherent idea
rather than four unrelated ones.

### `interpolateChannels` carries too — and the code already half-agrees

An earlier draft of this section said interpolation "is genuinely positioned and
recomputed, not ambient". **That was wrong**, and wrong in a way that mattered,
because it was used to exclude interpolation from the carry-through design.
`PipelineInvalidation.interpolations` does not *recompute* — it deletes.

`ChannelInterpolationSnapshot.applying(to:)` already re-derives each target from
its donor recipe against whatever signal it is handed, falling back to cached
samples only for state written before recipes were retained. Its own
documentation states the intended rule:

> The donor weights are persistent; the replacement samples are re-derived so
> filtering, OBS, wavelets, and other upstream transforms cannot reveal the
> original target channel.

But `interpolations(store:)` calls `removeAllInterpolations()`, which wipes
`replacements` **and** `sources`. So the recipe that is designed to persist is
destroyed on every gradient, ICA, or wavelet change, and the user re-does the
work by hand. The mechanism and the cascade disagree.

**So interpolation is ambient in the same sense `markBad` is**, which is why
`ChannelDecisionSteps` groups them: the *decision* ("channel 8 is unusable,
reconstruct it") persists, and the samples are derived.

Three things to get right when this is built:

- **`isEmpty` blocks the obvious fix.** `ChannelInterpolationSnapshot.isEmpty`
  keys off `cachedReplacements`, and `applying(to:)` early-returns on it. Keeping
  the recipes while clearing the cached samples would silently apply nothing. It
  has to become `cachedReplacements.isEmpty && recipes.isEmpty`.
- **Re-derivation is triggered by the bad set *and* the interpolated set.** The
  donor pool is `not the target, not bad, not already interpolated, has a
  position`. So interpolating channel 12 invalidates any recipe that used 12,
  exactly as marking it bad would. Both sets are inputs to every recipe's
  validity.
- **Re-deriving is a full re-solve, not a weight deletion.** Spherical-spline
  weights come from a solved system (`SphericalSpline.interpolationWeights`);
  dropping a donor's weight and renormalising is not the same answer. And the
  solve can fail when too few good channels remain — that path already exists and
  reports an error. On a re-derivation, a failed solve must **drop the
  interpolation and return the channel to bad** rather than leave a stale
  reconstruction standing.

Placement stays where it is: immediately before `segment`, matching where
`currentMFFExportSnapshot()` applies interpolation.

### Telling the user, without a modal

Marking a channel bad can silently re-interpolate other channels, so it has to
say so — but it is a side effect of a routine action, not something to block on.

Reuse `RecordingStatusModel.channelStatusMessage`, the line that already carries
"Interpolated Ch 8 from 125 neighbors." It is non-blocking, it is the established
channel for exactly this class of message, it is recorded into `statusHistory`
and therefore into the status popover's Queue tab, so it is recoverable if
missed, and it costs no new UI:

> Marked Ch 12 bad · re-interpolated Ch 8 and Ch 21 without it.

The failure case takes the existing error tier, because a channel silently losing
its repair is worse than the interruption:

> Marked Ch 12 bad · Ch 8 no longer has enough good neighbours; its interpolation
> was removed.

The History rail is the durable half of the same message. Re-interpolation
changes the chain, so it produces a node — the transient line says it happened,
and the rail says exactly when, weeks later. Worth designing the two together
rather than treating the notification as the only surface.

#### And a warning triangle on the channel itself

A status line is transient and the rail needs looking for. A channel whose repair
broke should say so where the user is already looking: in its own row.

`ChannelLabelRow` currently picks one icon from a three-way chain —
`eye.slash` when hidden, **`wand.and.stars` when interpolated**, `xmark.circle`
when bad. Replace the wand with a yellow `exclamationmark.triangle.fill` when the
interpolation was lost.

**It needs a third state, not a variation on the existing two.** When a re-solve
fails the channel is dropped back to plain bad, so `isInterpolated` goes false and
`isBad` goes true — the row falls through to `xmark.circle` and the fact that it
*used to be repaired* is gone. So `ChannelModel` needs a set alongside `bad` and
`interpolated`: channels whose interpolation was lost. It:

- **outranks `isBad` in the icon chain**, because "your repair broke" is the more
  informative fact than "this channel is bad" — the user already knew the second
  one;
- **stays below `isHidden`**, since hiding a channel is an explicit choice not to
  look at it;
- **clears when the user acts** — a successful re-interpolation, or unmarking the
  donor that caused it. It is a transition, not a standing property.

The triangle carries the explanation the status line only had time to flash:

> `.help("Interpolation lost — Ch 12 was marked bad and Ch 8 no longer has enough good neighbours.")`

Two things to get right:

- **`ChannelLabelRow.==` is hand-written.** ROADMAP B2 measured that one-line
  `Equatable` as the single biggest win in the whole Priority 1 refactor, and it
  compares a fixed list of inputs. A new input that is not added to it means the
  triangle simply never appears — the row is skipped as unchanged. This is the
  exact shape of silent failure this codebase keeps finding, and the compiler will
  not catch it.
- **A *degraded* re-solve gets no triangle.** If a donor goes bad and the re-solve
  succeeds with fewer neighbours, that is a normal outcome and the status line
  already reports it. Reserving the triangle for actual loss is what keeps it
  meaning something.

The loss should also reach `log_eva_*.txt` through `ProcessingAuditLog` — "Ch 8's
interpolation was dropped when Ch 12 was marked bad" is provenance, not just UI.
It is the kind of thing someone asks about months later, and by then the status
line is long gone.

The general rule worth stating once, since it has now come up in three places:
**stages record absolute state, and navigation is how you go backwards.**

## Open: replay and batch should let you *make* the per-file decisions

Raised 2026-08-13. Steps classified `.skip` — `markBad`, `interpolateChannels`,
`bcgDetection`, and anything non-replayable without a payload — are shown in the
replay/batch config pane greyed out, with their toggle `.disabled`, and then
simply do not happen. The user is told "Recorded for provenance only", which is
accurate and unhelpful: the step *should* happen on this file, just with
**this file's** answer rather than the source file's.

The proposal is to let those steps open their own interface mid-replay, in chain
order, so the operator makes the choice for the new recording and replay
continues. "The source marked 3 channels bad — here is the channel panel, mark
yours." "The source removed 5 ICA components — here is the sheet."

**Most of the machinery exists.** `ReplayController` already gates `.decision`
steps exactly this way: it pauses, the relevant sheet opens, the user resolves,
and `replay.resume(.proceed)` continues the walk. That is how ICA behaves in
windowed replay today. What is missing is the classification and one gate per
operation, not an engine.

Design questions worth settling before building it:

- **Which `.skip` steps become interactive, and which stay inert?**
  `markBad` and `interpolateChannels` obviously qualify. `bcgDetection` probably.
  A `split` step almost certainly does not.
- **Does a payload change the answer?** With `eva_ica.json` present, ICA needs no
  human at all — the per-file batch gate already skips the window for it. So the
  classification is not a property of the *operation*; it is a property of
  (operation, what this file carries). That is a third state beyond
  auto/decision: *resolvable-from-payload*.
- **What does Full Auto mean then?** Today "Full Auto" and "no decision steps
  included" are the same thing, which is why the headless gate can be a static
  check. If skip steps become interactive, Full Auto needs to mean "use each
  file's own payloads, and skip what cannot be resolved" — and files that need a
  human get routed to windowed replay individually rather than the whole batch
  falling back.

This is arguably a document of its own (a `REPLAY.md` covering the replay/batch
engine — `ReplayController`, `ReplayConfigSheet`, `BatchController`,
`ProcessingCore`, `HeadlessBatchProcessor` — which has no design doc despite
being most of the batch suite). Recorded here for now because the payload work
above is what makes the third state necessary. Its current implementation home
is ROADMAP RW-1 item 6, with the broader resume/skip/preflight workflow in PB-1.

---

## Interactions with existing features

**Copy processing from…** replaces the current window's redo future with the
copied script. Fork first when both the existing and copied alternatives need to
remain available.

**Batch processing** gains a natural definition of "process these 40 files to the
same node" — the chain hash from `REPORTS.md` §3 identifies the target state.

**Reports** get better: a report can name the exact node it describes, and a
comparison report between two forked states of the same recording becomes
possible—which is a genuinely novel thing to offer ("what did ICA actually buy
me?").

**Multi-recording combine** needs thought: combining N recordings means N history
trees converging on one node. Probably the combined output starts a fresh tree
that records its inputs' node IDs as provenance, rather than trying to merge
trees. Deferred.

---

## Historical open threads — 2026-08-13

Carried out of a long session. These headings preserve the investigation record;
ROADMAP RW-1 now owns anything still actionable.

### Baseline correction is its own step too

Same move as `reference`, and simpler. `baselineCorrected` was a `Bool` inside
`segment`'s parameters; it is now its own `EVAProcessingStep.Operation.baseline`
— another reserved-but-unfilled case from the original enum.

Simpler than `reference` in every way that mattered there: one domain (baseline
correction has no continuous equivalent — it is inherently per-epoch), no
ambient dependency (`withBaselineCorrection()` reads only the segment window
`segment`'s own step already carries), and no interactive/headless split to
find (`applyBuildJob` was already the one shared path both directions use, so
there was no duplicate pass to accidentally run twice the way the first
`reference` draft did). The step itself needs no parameters — its node address
comes entirely from its presence and its parent.

Emitted before `segment`, alongside `reference (domain: .epoch)`, for the same
reason: both are flags `applyBuildJob`'s fold consumes while building the
epochs, not passes performable from outside afterward. `ReplaySettingsRestore`
gained a fourth light (`baselineCorrection`) for the same total-derivation
reason as the others.

### Fixed: opening a processed file showed "raw", discarding its lineage

Reported with a real file: `Josh_pilot_run1_20260814_030010-averages.mff`, whose
`eva.xml` records `filter → thresholdArtifactDetection → interpolateChannels`
already baked into `signal1.bin`. Opening it showed the rail at a bare "raw"
root, as if none of that had happened.

**Cause.** `recordProcessingHistory()` only ever reflects *this session's*
pipeline view models — `filter.output`, `ica.cleanedSignal`, and so on — and
those are all `nil` the moment a file opens, whatever produced the bytes it
loaded. There was no path from "what `eva.xml` says happened" to the history
tree at all; the tree was built exclusively from live state.

**Fix.** `RecordingHistoryModel.seedOnDiskPrefix` reads the package's `eva.xml`
(`EVAProcessingScriptXML.read`, which already existed — only the write side had
a caller) into a fixed prefix, and `record()` now walks `onDiskPrefix + <live
steps>` on every call rather than the live steps alone. Called from
`seedProcessingHistoryFromDisk()` in `loadRecordingIfNeeded()`, matching
`currentPayloadDigests()`'s live disambiguation for `icaClean` so an on-disk ICA
removal gets its own node too.

Idempotent by design, and has to be: `recordProcessingHistory()` fires from an
`.onChange(initial: true)` that runs once while the file is still loading
(view models empty, signal nil) and again once it has finished — so seeding and
live recording can arrive in either order. Storing the prefix as state every
`record()` re-reads, rather than mutating the tree once, makes the result the
same regardless of which comes first.

**No snapshot exists for the prefix's interior nodes** — the intermediate
signals were never in this session's memory, only the final loaded bytes are.
Those nodes originally rendered disabled. Re-derivation now makes some
snapshotless nodes navigable, which exposes a serious newer constraint: the
loaded signal is already the processed prefix tip, so using it as the source for
an interior prefix can apply recorded steps twice. ROADMAP RW-1 item 1 requires
either a true pre-prefix source or an explicit non-navigable rule. The tip—what
is actually on screen—still gets a snapshot after seeding.

### Fixed: a regex-only PSA average left no `segment` step in eva.xml

Same reported file (`Josh_pilot_run1_20260814_030010-averages.mff`), a second
issue: its audit log (`log_eva_*.txt`) records a real segment result, per-epoch
bad-channel detection, an interpolation escalation, and four categories' SNR —
a genuine PSA average happened — but `eva.xml`'s `<step>` list has none of it:
just `filter`, `thresholdArtifactDetection`, `interpolateChannels`. The seeded
history above faithfully showed that truncated lineage, which is what surfaced
the gap: "even though this file is filtered, the PSA averaging and average
reference and baseline correction doesn't show up in the history."

**Cause.** The export builder's guard for emitting `.segment` (and the
epoch-domain `.reference` step ahead of it) was `!epoching.selectedEventCodes
.isEmpty` — plain-checkbox codes only. The live PSA pipeline's own eligibility
check, `canApplyPSA` in `PSAEpochingViews.swift`, already accounts for a second
path: a regex sub-selection rule (`categoryRegexRules`) can drive a build on its
own, with none of its source codes also ticked as a checkbox. A session that
segments entirely by regex — plausible for the reported file, whose SNR log
lines name categories `cb0/cb1/cb2/cb5`, not raw event codes — leaves
`selectedEventCodes` empty while genuinely epoching and averaging. The export
guard and the live gate had silently drifted apart.

**Fix.** `EpochingViewModel.hasSegmentSelection` — `!selectedEventCodes.isEmpty
|| !categoryRegexRules.isEmpty` — is now the one condition both `canApplyPSA`
and the export builder use, so they cannot diverge again the way they just did.
Regex rules were already fully serialized into `eva.xml` (`categoryRegex.N.*`
flat keys, round-tripped by `apply(parameters:)`) — only the *gate on whether to
emit the step at all* was wrong, not the step's own content.

### Fixed: navigation walked off the node you clicked

Reported as "raw → filter → artifact; go back to filter and artifact stays; go to
raw and it goes to a *second* artifact." One cause, and it is a new instance of
the family this document keeps finding.

`detectsEyeBlinkArtifacts` is a plain `Bool` on the view that decides whether
`thresholdArtifactDetection` is in the script **at all**. Restoring never reset
it, so the chain-signature observer immediately re-derived a script that still
contained the step: at `filter` that walked the pointer forward onto the artifact
node again, and at the root the same step had a different ancestry and therefore
a different content address — the second artifact.

The general rule, now in `ReplaySettingsRestore`:

> A setting whose value lives *inside* a step is restored by replaying that
> step's parameters, and a stale one is cosmetic. A setting that decides whether
> the step **exists** cannot be restored that way, because an absent step cannot
> say it is absent. Those must be reset to absent and then re-asserted by the
> path — total over the operation set, not driven by the steps present.

`definedArtifacts` moved into `PipelineSnapshot` for the second-order version of
the same thing: it is a *decision* like `badChannels` rather than a sheet
parameter, `artifactClean`'s address is computed from it, and the step's
parameters are a lossy summary that cannot rebuild it.

Still open here: `blinkThresholdConfig` / `movementThresholdConfig` change the
step's parameters but are absent from `ProcessingChainSignature`, so editing a
threshold records nothing and a later unrelated re-record forks. Adding them to
the signature would record a node per slider tick, so the fix is not simply to
add them.

### Re-referencing is its own step now

`averageReference` was a `Bool` serialized as a parameter of whichever stage
hosted it — `filter` and `segment`. It is now an `EVAProcessingStep.Operation`
`.reference` (an operation that already existed in the enum and was never
emitted), with `scheme`, `domain`, and the **excluded-channel list**. Three
reasons, in order of how much they matter:

1. Referenced-versus-not is the A/B people actually run, and as a filter
   parameter it forks the tree at `filter` and recomputes a band-pass that did
   not change.
2. It reads the bad-channel set, and nothing recorded that — the "channel
   decisions are ambient" problem in its worst form, because the effect is on
   every channel at once. Now the excluded set is a hashed parameter.
3. Two toggles for one concept meant ticking both referenced twice, silently.

Continuous and epoch are one operation with two domains rather than two
operations, but they are **not** interchangeable: the epoch one runs inside the
PSA fold, after trial rejection and before baseline correction, so it sees a
different channel mean. That is why `.continuous` is emitted after `filter` and
`.epoch` before `segment`. The arithmetic stayed exactly where it was in both
cases; replay derives the *flags* from the step list rather than re-implementing
the pass, so there is no interactive/headless split to diverge. `ReferenceScheme`
is an enum so linked-mastoid and single-channel references are a case, not
another `Bool`.

**eva.xml changes for every file.** `signal1.bin` must not — that is the paired
run this wants.

### Fixed: stale segment health reported a clean recording

"Going from segments to filtered re-runs the segment quality check and marks the
whole recording green."

Navigating empties `epochSegments`, so `SegmentHealthAnalyzer.analysisSegments`
falls through to fixed continuous windows with different IDs. Green was
structural, not luck: nearly every metric is scored *relative to this
recording's own distribution*, which makes the median window good by
construction, and the one decisive absolute metric is artifact overlap — which
`PipelineSnapshotting.restore` had just emptied along with `artifactVM.events`.
The panel therefore made its strongest claim at the moment it knew least.

Restore now takes the panel down rather than clearing it, because
`refreshSegmentHealthIfNeeded` re-runs on any signature change while `shows` is
true. Accept/reject labels survive — those are the operator's decisions, not
derived state, and they reappear when their segments do.

Worth deciding separately, and **not** changed: the `artifact` metric scores
"fully good" when no detection has ever run, which conflates *no artifacts
found* with *nobody looked*. Skipping it instead of passing it would be more
honest, but it changes scoring semantics for already-exported training data
(`SegmentHealthTrainingExport`), so it is a call to make deliberately.

### Unverified, and wanting a paired run

Five changes to the sample path have **not** been confirmed byte-for-byte. Use
`Tools/compare-paired-run.sh`, and remember it proves parity only when both sides
start from the same raw input.

1. **Artifact regression re-derives its template** instead of using the frozen
   average. This is the only change that deliberately alters existing results —
   see work item 4 — and the size of the effect is unmeasured.
2. **The ICA replay path** (`ICAComponentRemoval`, `ProcessingCore.icaClean`).
3. **`markBad` is now applied** by `ProcessingCore` rather than skipped, and the
   headless batch honours step inclusion.
4. **Gradient's `skipStart`/`skipEnd`/`appliesToPNS`/`excludeHighMotion`**, which
   need a concurrent-MRI recording to exercise at all.
5. **The `reference` step.** eva.xml is expected to differ; `signal1.bin` is
   expected not to. Run it with average reference on in both the filter and PSA,
   and with at least one channel marked bad so the exclusion list is non-empty.

### One thing that does not add up

A paired run produced an output whose `eva.xml` contains **no `icaClean` step**
while `eva_ica.json` was written beside it. Writing that sidecar requires
`core.ica.cleanedSignal != nil`, which requires the step to have run — and a step
that ran would be in the outgoing script. Both cannot be true as the code reads.
Three explanations were proposed and all three were wrong (file copy-through:
`MFFWriter` copies only `coordinates.xml` and `info.xml`; stale output: the
writer deletes an existing package first; wrong input file: confirmed by the
user). **Do not guess a fourth — instrument it.**

Still unresolved; carried as ROADMAP RW-1 item 4 alongside the paired-run work.

### Historical reasoning-only notes

- ~~**The double-window fix.** `WindowGroup` → `Window` makes a second window
  structurally impossible.~~ **Superseded 2026-08-15:** EVA deliberately uses a
  `WindowGroup`; explicit multi-window ownership and Fork to New Window are
  built. The current behavior is recorded under *EVA as a multi-window app* and
  ROADMAP C4.
- **The snapshot memory budget.** Sized from physical memory now, but the
  original slowness report is *unexplained*. The retention theory was disproved
  (137 GB machine, 2 GB budget — not swapping). The one real cost found and fixed
  was `processingChainSignature` building a `String` on every body pass. Whether
  that was the cause is unknown; the discriminating question is whether the
  slowness is per-frame, per-operation, or per-panel.

### Known-stale UI

- **`ReplayInteraction` cannot express the third state.** A step is `auto`,
  `review`, `decision`, or `skip` — with no way to say *resolvable from this
  file's own record*. The batch pane works around it with a local
  `resolvesFromPayload` check. That belongs in the type, and doing it properly is
  the same work as *Open: replay and batch should let you make the per-file
  decisions* below.

Tracked by ROADMAP RW-1 item 6.

### Historical next list — superseded by ROADMAP RW-1

1. ~~**Forking as a deliberate act.**~~ **Built 2026-08-15.** Fork to New
   Window preserves the chosen state and gives each alternative an independent
   future. The 2026-08-25 linear-history correction makes this the sole normal
   way to preserve divergent processing choices.
2. **A/B compare** remains open as ROADMAP RW-1 item 10. Its inputs are related
   forked windows, not sibling nodes accumulated by ordinary editing.
3. ~~**Basic re-derivation for evicted snapshots.**~~ **Built.** Its correctness
   hardening is now ROADMAP RW-1 items 1–3 and 7: safe prefix sources,
   latest-only commits, channel carry-through, and truthful cache policy/UI.
4. **The `markBad` and interpolation carry-through work** remains ROADMAP RW-1
   item 3.

The current order begins with processed-prefix safety and latest-only
re-derivation commits. Do not infer implementation priority from this historical
list.

## Forking to a new window

**Built 2026-08-15**, same day as the multi-window work it depends on. Raised
in response to "what if fork opened a second window on the same file and let
you keep editing independently from there?" Agreed, and worth being precise
about the mechanism, because the obvious-sounding version ("reprocess the
file the same way in a new window") is the wrong one. Design record kept
below; "What was actually built" is the as-shipped shape.

### What was actually built

- **`RecordingHistoryModel.ForkSeed`** (`RecordingHistoryModel.swift`) — a
  plain struct (`history`, `snapshots`, `snapshotOrder`, `onDiskPrefix`,
  `onDiskPayloadDigests`). `forkSeed()` exports the source window's; `seedFork(_:)`
  applies one wholesale, replacing whatever the target model already has. No
  defensive copying needed beyond the assignment itself — `EVAHistory` and the
  snapshot dictionary are already value types, which is exactly the property
  the design section below anticipated.
- **`ChannelModel.copy()`** (`ChannelModel.swift`) — a fresh instance carrying
  `bad`/`hidden`/`interpolated`/`interpolationSources`, *not* health results
  (session-only derived state, same category `PipelineSnapshotting.restore`
  already declines to carry over).
- **`PendingWindowForks`** (`EVA/App/PendingWindowForks.swift`) — the same
  FIFO-queue shape as `PendingWindowOpens`, carrying a richer payload:
  `packageURL`, the `ForkSeed`, a freshly-captured live `PipelineSnapshot`,
  and a `ChannelModel` copy. Known, accepted gap: only `packageURL` is
  threaded through, not any BrainVision sidecar-folder security scope, so
  forking a BrainVision-opened window can fail to load — visibly, the same
  way any other open failure does, not silently. This is the problem *The EVA
  cache* below exists to fix properly, by giving every non-MFF import a
  normalized on-disk copy to reopen from instead of depending on the
  original scattered files at all.
- **`WaveformHistoryRail.forkToNewWindow()`** — captures
  `recordingStore.processingHistory.forkSeed()`, a fresh
  `capturePipelineSnapshot()`, and `recordingStore.channels.copy()`, pushes
  them, then `openWindow(id: "main")`.
- **`WaveformView.applyForkSeed()`** — runs *last* in `loadRecordingIfNeeded()`,
  after `seedProcessingHistoryFromDisk()` and `adoptOnDiskEpochsIfPresent()`
  rather than instead of them. Those still run (same file, same `eva.xml`,
  harmlessly redundant); this call is what makes the fork's full — possibly
  live-edited — history and live pipeline state win over their result rather
  than depending on which happened to run last. Ends with the exact
  `PipelineSnapshotting.restore` call ordinary history navigation already
  uses, targeting the new window's freshly-constructed view models.
- **The claim path**: `ContentView.onAppear` checks `PendingWindowForks`
  before `PendingWindowOpens` (a window is only ever created for one reason,
  so this ordering doesn't have to matter in practice, but costs nothing to
  get right). `claimedForkSeed` is explicitly cleared in `open(_:)` and
  `closeRecording()`, not just consumed once — a fork claimed into a window
  that is later closed and reused for an ordinary file must not leak into it.
- **The UI**: a toolbar button in the History tab's footer (`macwindow.badge.plus`),
  next to the step-back/forward transport rather than a per-node context
  menu — forking acts on *wherever the pointer currently is*, the same node
  those controls already operate on.
- **Tests**: `RecordingHistoryForkTests` — whole-tree and on-disk-prefix
  carry-through, post-fork independence (mutating one tree doesn't touch the
  other), identical-next-step hashing to the same node id across two
  independently-copied trees (the content-addressing consequence the design
  section predicted), and `ChannelModel.copy()`'s carry-through/omission/
  independence.
- **Not verified**: this needed the multi-window mechanism itself, which per
  the plan above is manual-QA territory — the actual click of the fork
  button, watching a second window open showing the same state, and editing
  it independently, has not been done by a human yet.

### Original design (kept for context)

**Memory copy, not reprocessing.** Re-running the pipeline for the new window
risks exactly the class of bug this document keeps finding: two code paths
computing "the same thing" and quietly diverging — that is what caused the
double average-reference bug, the stale-detection-on-rewind bug, and the
interactive/headless split found in `reference`. A copy has no such risk: it
is the same bytes, guaranteed, not a claim that needs verifying by a paired
run. And it is nearly free — `MFFSignalData.data` is `[[Float]]`,
copy-on-write, the same property `PipelineSnapshot` already exploits for
instant undo/redo. **Forking is structurally the same operation as navigating
history — it just lands in a second window instead of the same one.**

### Mechanism

1. **`EVAHistory` copies whole, not just the current node.** It is already a
   pure value struct (see "Undo/redo is snapshot-based, not re-derived" above),
   so copying `RecordingHistoryModel.history` into the new window's own model
   is cheap and correct. The new window can navigate the *shared* past just as
   well as the original can. After the copy the two are independent values, so
   each window's future edits diverge naturally with no explicit branch
   bookkeeping needed — they are just two structs that used to be equal and no
   longer are.
2. **Snapshots copy whole too**, same copy-on-write reasoning — there is no
   cost argument against it, and it gives the new window the same "instant
   navigation" depth into pre-fork history that the original has, rather than
   starting with only the current state recoverable.
3. **The pipeline view models seed from a captured `PipelineSnapshot`**, via
   `PipelineSnapshotting.restore` — literally the same restore call navigation
   already uses, just targeting a freshly-constructed set of view models
   instead of the current window's.

A nice consequence of this that is not the point but falls out of it for
free: because node IDs are content-addressed hashes, not object identity, two
windows that independently apply the *same* next step compute the *same*
node ID even though their `EVAHistory` copies are now separate structs. If
session persistence (work item 6, not built) ever reads two forked windows'
histories back in, they would still line up on their shared prefix.

### Two hazards, both concrete rather than hypothetical

- **`ChannelModel` is a reference type** (`final class`), not a value. A naive
  fork would leave the new window's `RecordingStore` pointing at the *same*
  `ChannelModel` instance — marking a channel bad in one window would silently
  mark it bad in the other. Needs an explicit copy of `.bad`/`.interpolated`/
  `.hidden`, not a shallow one.
- **`MFFRecording` cannot be shared between the two windows at all.** It is a
  class, and `tearDownForClose()` nils out `signal`/`pnsSignal` on close. If
  both windows held the same instance, closing window A would rip the loaded
  data out from under window B mid-edit. The new window needs its own
  `MFFRecording(packageURL:)` — a fresh load of the raw file. That is the one
  part of a fork that is not free: forking costs one file re-read, even though
  the processing itself costs nothing.

Session-only UI state (selection range, viewport scroll, sheet visibility) is
not carried over — treated the same as `PipelineSnapshotting.restore` already
treats it on ordinary navigation, where it is cleared because it may not make
sense against a different signal. For a fork the signal starts identical, so
it *could* be preserved, but consistency with the existing restore behavior
argues for not special-casing it, at least at first.

### Why a window fork is the branch operation

Clicking an earlier rail node and continuing with a different action replaces
that window's redo chain. **Fork to New Window** is the explicit gesture for
preserving both alternatives. Its selling point is real side-by-side comparison
— two live `WaveformView`s on screen at once, independently scrollable and
independently scaled — which the single-rail model cannot offer without a whole
separate split-view feature. It also resolves *A/B compare*'s visual question:
the compared states live in two windows, while each window keeps ordinary linear
undo/redo.

**Hard dependency: this cannot be built before EVA is a multi-window app.**
There is currently only one `recording` in the whole process to fork *from*.
The rest of this section is that prerequisite, folded in from the standalone
scoping pass it was written as (`MULTIWINDOW.md`, 2026-08-15) now that forking
gives the multi-window work a concrete first consumer rather than being
speculative.

## The EVA cache: content-addressed snapshots and normalized imports

Not started. Scoped 2026-08-15, prompted by forking's one accepted gap —
"forking a BrainVision-opened window can fail to load" — while asking a
bigger question out loud: does EVA need its own file format, richer
serialization into MFF, or something else entirely? The answer settled on is
**something else**: not a new save format, not more sidecars — a private,
non-user-facing cache EVA manages for itself. This is now the concrete design
for work item 6 ("Session persistence"), which was a one-line placeholder
before this.

### Why not a native EVA project format

The tempting version is a real EVA-owned file format — its own binary layout,
replacing MFF as the working representation, something users save and reopen
as *the* file. Worth naming why this document steers away from it: the moment
people rely on it for real sessions, format compatibility becomes a permanent
obligation in a way optional sidecars never asked for, and MFF export becomes
a lossy round-trip out of a richer format instead of the native shape it is
today. That is a much bigger commitment than either motivating problem below
actually needs.

### Why not more MFF sidecars

The current trajectory — `eva.xml`, `eva_ica.json`, `eva_artifacts.json`, and
the placeholder plan for `eva_history.json` — has been working, and stays for
anything meant to leave the app: exports, and anything another tool or a
collaborator might open. But it has a ceiling this document is now close to.
MFF's schema belongs to EGI, not EVA; every sidecar is EVA quietly annexing
territory in someone else's directory. Fine for a handful of small XML/JSON
files. Not fine for what this section is actually for: multiple window lineages
with snapshot caches that today exist only in RAM, which is not a sidecar-sized
problem, and non-MFF imports (BrainVision, EDF, Persyst, BESA), which have no
package directory to annex at all — there is nowhere to *put* a sidecar for a
recording that is three loose files in a folder the user did not intend to
hand over to EVA.

### What the cache actually is

A directory EVA owns and the user never has to look at —
`~/Library/Caches/EVA/`, keyed by source file — holding two independent
things:

1. **Content-addressed snapshot storage.** `EVAHistoryNodeID` is already a
   stable hash of everything that produced a node — that hash can be a key
   into an on-disk blob store exactly as well as it is a key into
   `RecordingHistoryModel`'s in-memory `snapshots` dictionary. Once that
   exists, an evicted snapshot stops meaning "gone, re-derive it" (REWIND's
   "next, in order" item 3, unbuilt since the memory-budget work landed) and
   starts meaning "not in RAM right now, one disk read away." This is the
   highest-leverage single feature the cache offers: it turns the existing
   memory-budget eviction from a hard loss into a soft one, for free, because
   the addressing scheme was already built for an unrelated reason.
2. **Normalized copies of non-native imports.** The moment EVA reads a
   BrainVision (or EDF/Persyst/BESA) file, it is converted into
   `MFFSignalData` in memory — every import format is already normalized to
   one internal shape. The gap is only that this normalized form is never
   written back to disk. Doing so once, on first load, gives fork (and
   reopening generally) something to read that does not depend on the
   original scattered files or their security scope — this is the direct fix
   for the fork limitation that prompted this section. `eva.xml`-equivalent
   metadata travels with the cached copy the same way it would with a real
   MFF package.

Both are genuinely optional: delete the cache directory and EVA loses
*speed* (snapshots re-derive, non-native imports re-read their originals) but
nothing it cannot recover on its own. That reversibility is what keeps this
from becoming the native-format commitment the section above steers away
from — it is allowed to be wrong, stale, or missing without ever being the
thing anyone's data actually lives in.

### Open questions

These are retained as cache-design rationale and are consolidated in ROADMAP
RW-1 items 11–12.

- **Eviction policy for the on-disk store**, independent of the in-RAM
  budget — presumably larger and slower to fill, but not unbounded.
- **Invalidation**: a normalized import copy is only correct as long as the
  original file has not changed on disk since. Needs a cheap staleness check
  (mtime + size, most likely). Expanded SHA-256 manifests or whole-recording
  hashing are explicitly **not** a project priority or prerequisite.
- **Does this replace the `eva_history.json` sidecar plan, or sit alongside
  it?** Leaning toward: the cache holds the *snapshots* (large, disposable,
  never meant to leave the machine); a slim `eva_history.json` sidecar still
  travels *with the package* for the tree structure itself (small, meant to
  survive a copy to another machine — REWIND's original "should nodes
  survive export?" open question). The cache is what makes the sidecar's
  tree navigable without a full re-derive; the sidecar is what makes the
  tree portable at all.

## EVA as a multi-window app

**Built 2026-08-15**, same day it was scoped — the answers to every open
product question below (window scoping, batch's own window, close/quit
rules) were settled first, which is what made this a same-day build rather
than a longer pass. First scoped after "make the main window single-instance"
(0.1.7) closed a Finder double-open bug by making two windows structurally
impossible rather than merely rare. This section is kept as the design
record; "What was actually built" below is the as-shipped shape, which
matches the plan closely but not everywhere — read that first if you are
touching this code.

### What was actually built

- `EVAApp.swift`: `Window("EVA", id: "main")` → `WindowGroup(id: "main") {
  ContentView() }`. `recording` is `ContentView`'s own `@State`.
- **`PendingWindowOpens`** (`EVA/App/PendingWindowOpens.swift`) — a tiny
  `@MainActor` FIFO queue, not `WindowGroup(for:)`. Deliberate: `for:` ties a
  window's identity to macOS state-restoration, which would try to relaunch
  the exact file selection (via a possibly-stale security-scoped bookmark)
  on EVA's *next* launch — a bigger commitment than "always open a new
  window" was asking for. `OpenRecordingButton` pushes the picked URLs
  immediately before calling `openWindow(id: "main")`; the new window's
  `ContentView.onAppear` claims them once, guarded by
  `hasClaimedPendingOpen` so a second `.onAppear` firing cannot steal a
  *different* window's pending file.
- **Three different "does this reuse a window?" rules, one per trigger, each
  argued from what that trigger naturally means** — not the single uniform
  "always new" the open question below originally posed:
  - **Menu "Open Recording…"** (`OpenRecordingButton`): always a new window.
    It lives in the menu bar, not inside any particular window, so "the
    current window" has no unambiguous referent for it to reuse. Uses raw
    `NSOpenPanel` rather than `.fileImporter`, which must attach to an
    on-screen view that does not exist yet when this fires.
  - **`.onOpenURL`** (Finder double-click / Open With): reuses *this*
    window if it is empty, otherwise opens a sibling. Not "always new" —
    a fresh launch delivers the open-file event to the `WindowGroup`'s
    auto-created default window, which is empty, and filling it directly is
    what keeps a Finder launch from spawning a redundant empty window every
    time. A blind "always new" here would have reintroduced a milder,
    on-purpose version of the exact double-open bug `Window` was built to
    fix in 0.1.7.
  - **Drag-and-drop**: unchanged from before multi-window — always loads
    into the window it was dropped on, full stop. A drop is inherently
    targeted.
- **`@FocusedValue` routing** — `RecordingWindowActions` (`ContentView.swift`)
  is a struct (`hasRecording`, `close: () -> Void`), not a raw
  `Binding<MFFRecording?>`, so `CloseFileButton` can act without also being
  able to overwrite `recording` directly and bypass `closeRecording()`'s
  teardown. Turned out **not** needed for Open or Batch — both resolved to
  an unambiguous target on their own (a new window; the single batch
  window), so `@FocusedValue` ended up scoped to exactly one command, not
  three as the original plan assumed.
- **Batch's own window** — `BatchWindowView.swift`, a `Window("Batch", id:
  "batch")` hosting the same `WaveformMarkerContainer`/`WaveformView` a
  manual window does, with its own private `@State private var batch =
  BatchController()`. **Closing it mid-run cancels the batch** (`.onDisappear
  { if batch.isActive { batch.stop() } }`) — decided explicitly rather than
  left to fall out of default behavior; no confirmation, since "Stop Batch"
  already ends a run with none and completed files are already written.
  `BatchSetupSheet`'s Cancel now closes the window itself
  (`dismissWindow(id:)`) rather than leaving an empty background behind, for
  the same "nothing to leave behind" reason.
- **Every manual recording window carries its own private, always-idle
  `BatchController`** — not a shared one. `WaveformView` unconditionally
  reads `@Environment(BatchController.self)` (for
  `autoStartBatchIfNeeded()`), so something has to be there; giving each
  window its own means a manually-opened file can never accidentally
  `.matches()` a batch running in the *other*, dedicated window and hijack
  itself into review mode mid-edit — a real risk that would have existed had
  `BatchController` stayed a single shared instance now that two kinds of
  window both hold one.
- **`ChannelSetStore.activeSensorLayout`/`activeChannelNames`** — kept as
  storage, but the *write* moved from "wherever a recording loads" (stale
  the moment two windows exist — reflects load order, not focus) to a
  **focus mirror**: `ChannelSetContext` is a new `@FocusedValue`, published
  by `WaveformView` alongside its existing dozen; `ChannelSetFocusMirror`
  (`ChannelSetStore.swift`) is a zero-size view mounted in `.commands`
  purely to keep that read live regardless of which window is key, then
  writes what it sees into the store. It has to live in `.commands`
  specifically — `@FocusedValue` read from *inside* the Channel Sets
  editor's own window body would go nil the instant that window became key,
  since the editor does not publish the value itself. This is the
  "(a) track focus" option from the open question below, chosen over
  "(b) per-window editor." `clearActiveRecordingContext()` and its three
  call sites were deleted outright rather than kept as a no-op — the mirror
  makes explicit clearing unnecessary (focus moving to a different or no
  window updates or nils the mirrored value on its own).
- **Per-window frame-autosave name** — `ContentView` generates a
  `@State private var windowInstanceID = UUID()` once per window instance
  and keys `WindowAccessor`'s autosave name off it. Deliberately *not* keyed
  by the recording's package name, despite that being the more obvious
  per-window-feeling identifier: window position/size is a property of the
  window's slot on screen, not of whichever file happens to be showing —
  keying by file would make a window forget its position every time a
  different file opened in it, and would make two windows on the *same*
  file collide on one saved geometry, reintroducing the exact autosave
  collision this was fixing, just from a different cause.
- **`@NSApplicationDelegateAdaptor(EVAAppDelegate.self)` restored.** Found
  missing from `EVAApp.swift` while starting this work — the 0.1.7
  last-window-closes-quits fix had regressed at some point after landing.
  Fixed as part of this pass since multi-window depends on it working
  correctly (closing the last of *N* windows still needs to quit).
- **Not built in this pass, and not needed for it:** forking to a new
  window (above — this was the prerequisite, not the feature itself); the
  "can the same file be open twice" and "does Open Recording ever reuse an
  empty frontmost window" open questions below were answered (always-new,
  and no-reuse respectively) rather than left open.

### Original scoping (kept for context)

### The headline finding

**Most of EVA is already scoped correctly for this.** The pipeline state that
actually matters — filter output, ICA, artifact cleaning, wavelet reduction,
channel decisions, the processing queue, the history tree itself — all lives
in `RecordingStore`, and `RecordingStore` is already `@State` owned by
`WaveformView`, freshly constructed every time `WaveformMarkerContainer` is
re-keyed by `.id(recording.id)`. Two recordings already cannot
cross-contaminate each other's *processing* state, because that state was
never shared to begin with — REFACTOR.md's L4 extraction did this work
already, for an unrelated reason (testability), and multi-window inherits the
benefit for free.

The actual work is concentrated in three places: **the window scene itself**
(`Window` → `WindowGroup`), **routing menu commands to the right window** (a
standard SwiftUI mechanism, not currently used anywhere in EVA), and **a
short, specific list of true singletons** that assume exactly one recording is
ever active. That list is short because most candidates checked turned out
fine — see "Audited and fine" below.

### What has to change

**1. The window scene: `Window` → `WindowGroup`.**
`EVAApp.swift` currently declares `Window("EVA", id: "main") { ContentView(
recording: $recording, ...) }`, with `recording` as `@State` on `EVAApp`
itself, passed down as a binding. That is *why* it is single-instance: there
is exactly one `recording` variable in the whole app, so there can only ever
be one window showing it.

The fix is not a flag — it is moving that state to where it structurally
belongs. `ContentView` should own `@State private var recording:
MFFRecording?` itself; the scene becomes `WindowGroup(id: "main") {
ContentView() }`. SwiftUI then gives each window instance its own
independent `@State`, and — because `WaveformMarkerContainer`/
`RecordingStore` are already downstream of that — its own entire pipeline,
for free. This is the one piece of real leverage this plan has: the hard part
(isolating processing state) is already done, and switching scene types is
what turns "already isolated" into "actually usable across two windows."

**2. Menu commands need to know which window they mean.** Today, "Close
File", "Open Recording…", "Batch Process…" mutate the one `@State` on
`EVAApp`. With a `WindowGroup` that indirection has nowhere to point — a menu
click has to act on the frontmost window, not all of them and not an
arbitrary one. SwiftUI's answer is `@FocusedValue`/`.focusedSceneValue`,
unused anywhere in EVA yet but standard, documented multi-window SwiftUI —
known shape, not an open design problem. `ContentView` publishes what the
frontmost window needs (open/close/canClose, or a focused binding to
`recording` itself); `.commands` reads it and disables items with no live
target.

**3. Window-frame autosave collides across instances.** `WindowAccessor`
calls `window.setFrameAutosaveName(autosaveName)` with the fixed literal
`"EVAMainWindow"`. Two windows sharing one AppKit frame-autosave name will
fight over the same saved position/size. Needs a name keyed per window
instance — the recording's package name is a reasonable choice, with a
per-window UUID fallback for two windows on the same file (see the open
question below).

**4. `ChannelSetStore.activeSensorLayout`/`activeChannelNames`.** The one
genuine "assumes a single active recording" singleton found in this audit.
`ChannelsPanelViews.swift` sets these on every load; the separate Channel Sets
editor window (single-instance) reads them to draw its electrode map. With
two-plus recording windows this reduces to "whichever recording loaded or was
touched most recently" — the editor would silently show the wrong recording's
layout, with no indication that happened. Two fixes, and it is a product
decision, not a mechanical one:
   - **(a) Track focus, not load order** — same `@FocusedValue` plumbing as
     above. Minimal, matches how the other single-instance utility windows
     already relate to "the app," but the editor's content changes underneath
     you as you click between windows.
   - **(b) Make the editor per-recording**, opened from that recording's own
     window rather than the Window menu globally. More consistent, more work,
     and raises the same "which window does this belong to" question the
     editor was trying to avoid by being global in the first place.

**5. The close → quit flow needs a per-window rule, not an app-wide one.**
0.1.7 built: close a recording (confirm if unsaved work exists) → window
survives as an empty drop target → closing *that* quits the app
(`applicationShouldTerminateAfterLastWindowClosed`). Correct for exactly one
window, where "empty" and "nothing left to do" are the same state. With N
windows, "empty window, but a sibling window still has a recording open" has
no rule yet. Likely answer: an empty window with siblings still open just
closes outright (no confirmation needed — nothing to discard) rather than
requiring the two-step close-then-quit dance, which exists only to give a
*last* window a landing state instead of vanishing.
`applicationShouldTerminateAfterLastWindowClosed` itself needs no change —
"last window closed" already means what it says regardless of how many
windows existed a moment before.

### Audited and fine — no change needed

Checked because they are `.shared` singletons and looked at first with
suspicion; none of them assume one active recording:

- **`ProcessingDefaults.shared`** — genuinely global, UserDefaults-backed
  *preferences* (default filter cutoffs, default ICA method, …), read once
  when a view model is constructed to seed its starting values. Not runtime
  state that depends on which recording is showing.
- **`FigureExportBasket.shared`** — already documented as session-wide.
  Two-plus recording windows feeding one basket is not just harmless, it is
  plausibly the actual motivating use case for wanting two windows at all —
  building a comparison figure from two different subjects' data.
- **`DebugLog.shared`** — one log for the app's own behavior, correctly
  global regardless of window count.
- **`ProcessingQueue`** — already a member of `RecordingStore`, not a
  singleton at all. Already per-recording.
- **SwiftData `.modelContainer(for: UserMarker.self)`** — attached at the
  scene level. With `WindowGroup` this is shared across all window instances
  automatically, which is correct: one marker database, already filtered
  per-recording via `@Query` inside `WaveformMarkerContainer`.
- **`GradientCPUBackend.shared`/`GradientMetalBackend.shared`/
  `LocalTemplateMetalBackend.shared`** — compute backends, stateless between
  calls. Safe to share, same as any other shared engine object.

### A significantly attractive option: batch gets its own dedicated window

Raised as a hypothetical partway through the original scoping pass, and
worth building in as the actual recommendation rather than a footnote — it
resolves what was otherwise the single least-obvious, most open-ended piece
of the whole plan: whether windowed batch claims a manual window, refuses to
run with several open, or something else. This makes that question not need
an answer.

**The idea:** instead of windowed batch meaning "drive whichever window
happens to be `recording`'s owner through a queue of files," give it a
fourth single-instance utility window — `Window("Batch", id: "batch")`,
opened from the Window menu, exactly like Debug Log, Channel Sets, and Figure
Export already are. Batch processing stops being a *mode* an ordinary
recording window can enter, and becomes its own place entirely. This is a
fourth instance of a pattern already proven three times over in this
codebase, not a novel design.

**Why it is more than a relabeling.** Windowed batch only exists because some
steps (ICA component removal, gradient review) cannot be resolved headlessly
and need a human to look at the real interactive UI. That review UI is not
separate from ordinary editing — `ReplayController`'s pause/resume state
(`.awaitingReview`/`.awaitingDecision`) is `@State` living directly inside
`WaveformView`, gating the exact same sheets and panels a manual user
touches. So a batch window needs the *same* UI a recording window needs; the
difference is only what drives `recording` — a person picking files, versus
`BatchController.currentIndex` advancing through a queue. Today both live in
the same place: `ContentView`'s `.onChange(of: batch.currentIndex) { idx in
recording = MFFRecording(...) }` sits right next to manual open/close, in the
view every ordinary window would become an instance of under `WindowGroup`.
Splitting batch out moves that whole branch into the batch window's own
content instead — simplifying the *manual*-window code path too, not just
the multi-window story: `ContentView` stops needing to know batch exists at
all.

Concretely this removes or shrinks three things:
- **Open question "does batch claim a window?" stops being a question.**
  Batch always has exactly one window, structurally, identified by its own
  scene id rather than by focus. Nothing left to arbitrate.
- **The `@FocusedValue` work only has to cover manual windows.** Batch's own
  commands (Stop Batch, its progress display) belong to the batch window
  specifically and never need to ask "which window is this for."
- **`ContentView` sheds a whole branch of state it doesn't conceptually
  own.**

What it adds, small but new: `ChannelSetStore` gets a third contributor
(manual window A, manual window B, and now the batch window all set
`activeSensorLayout` on load) — the fix above is unchanged but the batch
window needs to participate in whichever is chosen. And a genuinely new
question: what happens if the batch window is closed mid-run? No equivalent
case exists today, since the only window there is *is* the batch. Options:
disable closing while a batch is active (matches "Stop Batch" already being
the deliberate way out); or closing prompts to stop the batch first, same
shape as the existing discard-confirmation on a manual window. Small, but
worth deciding on purpose.

**Net assessment: worth doing.** It turns the plan's one open-ended,
product-judgment item into a mechanical one, reuses a pattern already proven
three times over, and simplifies the manual-window code path as a side
effect rather than merely avoiding making it worse.

### Suggested order, if this goes ahead

1. `Window` → `WindowGroup`, `recording` moved into `ContentView`'s own
   `@State`. Get a second window opening and independently loading a
   *different* file working end to end before anything else — proof that
   "most of EVA is already scoped correctly" holds under a real second
   window, not just under code reading.
2. **Batch's own window**, alongside step 1, not after — it removes the
   `batch.currentIndex` branch from `ContentView` entirely, so building it
   early means step 1's manual-window code never has to carry batch-swapping
   logic it would only lose again later.
3. `@FocusedValue` plumbing for File commands on manual windows. Test with
   two windows open, confirming ⌘W / Close File / Open Recording each act on
   the right one. Narrower than originally scoped, now that batch has its own
   window and its own commands.
4. Window-frame autosave naming fix, for every window type including batch.
5. `ChannelSetStore` decision (focus-tracking vs. per-window editor),
   covering all three window sources (two-plus manual, one batch).
6. Close/quit-flow adjustment for N manual windows, plus the close-mid-batch
   decision for the batch window.
7. **Forking to a new window** (above) — the actual motivating feature,
   buildable once steps 1–3 exist. This is why the plan is worth doing now
   rather than staying speculative.

With batch given its own window, nothing in this list is open-ended the way
step 6 used to be — every remaining item has a known shape.

### Open questions specific to multi-window

- **Can the same file be open twice?** Answered by omission, not by a
  detection check: nothing stops it (menu "Open Recording…" always makes a
  new window regardless of what is already open elsewhere), and no warning
  was built. Two windows opened separately on the same file can silently
  diverge with no indication they are related. Still true after the build;
  revisit if it turns out to matter in practice.
- ~~Does "Open Recording…" always create a new window, or reuse an empty
  one if the frontmost window has no recording?~~ **Answered: always new,
  for the menu command specifically.** `.onOpenURL` (Finder/Open With) got
  the *other* answer — reuse this window if empty — because it has a
  natural receiving window to reuse and the menu command does not. See
  "What was actually built" above for why those needed to differ rather
  than share one rule.
- **Cross-window comparison beyond fork** — the current direction is comparison
  between related forked windows. A second single-window sibling-node A/B mode
  is not assumed; ROADMAP RW-1 item 10 owns the product and identity details.

---

## Open questions

This is an archive of the original questions. Their current homes are ROADMAP
RW-1 and the completed milestones.

- ~~**Does the branch tree earn its complexity, or is linear undo/redo enough?**~~
  **Answered 2026-08-25:** linear undo/redo is the one-window behavior. Explicit
  Fork to New Window preserves an alternative when the operator actually wants
  one; ordinary replacement truncates redo.
- ~~**What happens when the user edits an ancestor's parameters?**~~ **Answered
  2026-08-25:** it replaces that window's redo descendants. Fork first to retain
  the old version.
- **Should nodes survive export?** A package written from node N — does it carry
  the whole tree or just its own lineage? Leaning toward whole tree, since it is
  small (steps + payloads, no signals) and makes a package self-documenting.
  **Current home:** ROADMAP RW-1 item 11.
- ~~**Interaction with the Priority 1 Observation refactor.**~~ **Resolved:**
  that refactor is complete (ROADMAP C1). Remaining history memory/cache policy
  is ROADMAP RW-1 item 7.
