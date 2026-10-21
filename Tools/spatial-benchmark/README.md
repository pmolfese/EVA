# Spatial hierarchy benchmark

Run from the repository root:

```sh
./Tools/spatial-benchmark/run.sh 1000 256 3 > /tmp/spatial-timings.csv
```

The runner compiles the actual `EVA/Artifacts/ArtifactSpatialGrouping.swift`
with `swiftc -O`. Minimal display-data adapters avoid launching the app; the
scoring and hierarchy algorithms are not copied into the benchmark.

The deterministic fixture has three smooth scalp-field families, alternating
whole-map polarity, and event-specific sensor noise on a synthetic disk montage.
All events have complete windows and valid maps. Each cost receives identical
maps. This measures compute cost, not accuracy or clinical suitability.

CSV columns:

- `build_seconds`: complete tree, without requesting an early cut.
- `cut_seconds`: two-family target refinement and outlier pruning on that tree.
- `initial_ready_seconds`: a separate progressive run, from build start through
  the first exact two-family cut, including its refinement and pruning.
- `progressive_complete_seconds`: that progressive run through full completion;
  includes the initial cut performed in the callback. In the app, that cut runs
  concurrently with completion instead of delaying the builder callback.
- `signature`: deterministic fingerprint of node IDs, membership, centroids,
  orientation, cohesion statistics, and child links. Each progressive run must
  reproduce the non-progressive tree's signature.

Times exclude signal-window extraction, peak-topography calculation, drawing,
SwiftUI task scheduling, and disk I/O. They are optimized-build synthetic estimates,
not promises about real recordings. Event diversity, sensor coverage, requested
count, compiler configuration, CPU load, and hardware change the times. Costs can
produce different trees and iteration counts, so ratios are workload-dependent.

The checked-in October 19, 2026 runs use medians of three sequential measurements
on the same Apple Silicon Mac. Before/after runs were made with the production
source immediately before and after the optimization; their complete tree
signatures match. The original source snapshot was a temporary comparison input,
not another maintained implementation. Re-running the script measures the current
implementation. Saved CSV files support the timing summary below.

## Measurements (seconds)

### 300 events × 128 sensors

| Cost | Before: full tree + cut | After: first two families | After: full progressive completion |
| --- | ---: | ---: | ---: |
| Global Pearson | 0.015 | 0.006 | 0.010 |
| Local Pearson | 0.191 | 0.039 | 0.114 |
| LPA+ (same contrast) | 0.451 | 0.114 | 0.295 |
| LPC+ (opposite contrast) | 0.487 | 0.116 | 0.330 |
| crM (correlation ratio) | 0.304 | 0.068 | 0.228 |
| Spearman | 0.276 | 0.068 | 0.166 |
| Robust composite | 0.627 | 0.146 | 0.370 |
| Information composite | 0.326 | 0.054 | 0.232 |

### 1000 events × 256 sensors

| Cost | Before: full tree + cut | After: first two families | After: full progressive completion |
| --- | ---: | ---: | ---: |
| Global Pearson | 0.108 | 0.033 | 0.071 |
| Local Pearson | 1.700 | 0.442 | 1.012 |
| LPA+ (same contrast) | 3.351 | 0.588 | 1.642 |
| LPC+ (opposite contrast) | 3.569 | 0.581 | 1.557 |
| crM (correlation ratio) | 1.942 | 0.315 | 0.790 |
| Spearman | 2.644 | 0.480 | 1.514 |
| Robust composite | 6.171 | 1.052 | 3.426 |
| Information composite | 1.980 | 0.266 | 0.789 |

All eight metrics retained their original full-tree fingerprints for both sizes.
The focused macOS review suite passed 44 tests, including exact initial/final-cut
comparisons across all metrics and both polarity modes, serial/parallel node
comparisons, cancellation, partial-cache rejection, and native render checks.

## Choosing a cost

Global Pearson with global polarity ignored is a useful first choice for scalp-map
shape matching: it directly compares the whole electrode pattern, is fast, and
has an interpretable spatial-correlation threshold. This recommendation is an
engineering judgment, not an artifact-label accuracy result from this fixture.
Spatial correlation is established in EEG map clustering; the cited microstate
study is not a validation study of artifact families:
[EEG clustering study](https://pmc.ncbi.nlm.nih.gov/articles/PMC6119811/).

LPA+ is worth comparing when whole-map correlation gives visually poor families.
It blends strong local correlations with histogram-derived terms, which can
accept broader map differences. It is slower and its scores are not Pearson r.
EVA implements a sensor-map adaptation, not AFNI's full registration algorithm.
[AFNI documents LPA+ for similar-contrast MRI alignment and LPC+ for
opposite-contrast alignment](https://afni.nimh.nih.gov/pub/dist/doc/program_help/3dAllineate.html);
that evidence does not establish superiority for EEG artifacts. No artifact-label
accuracy comparison was performed here. Ocular review now defaults to Global
Pearson with global polarity ignored. Thresholds should be reassessed when
changing metrics.
