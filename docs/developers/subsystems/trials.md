# Trials — `EVA/Trials`

**Purpose.** The statistical engines that run over epochs/averages: cluster-based
permutation testing (the main group/condition inference), and latency-variable
single-trial decomposition (RIDE, Woody, nonlinear alignment). These are UI-free
analyzers; the [epoching.md](epoching.md) UI drives them.

**Start here.** `ClusterPermutationAnalyzer.analyze(...)` (and the F variant) is
the cluster test; `ClusterStatisticsRunner` prepares data and orchestrates it.
`RIDEAnalyzer.decompose(...)` and `WoodyAlignmentAnalyzer.align(...)` do
trial-by-trial latency work.

## Files

**Cluster permutation statistics**

| File | Synopsis |
|---|---|
| `ClusterPermutationAnalyzer.swift` | t-based cluster permutation: `analyzeIndependent`/`analyzePaired`, `runPermutations`, threshold resolution; `Design`, `Condition`, `Result`. |
| `ClusterPermutationFAnalyzer.swift` | F-test (>2 conditions) variant of the above. |
| `ClusterFormation.swift` | Forms spatiotemporal clusters (`SpatiotemporalCluster`, TFCE, `ClusterGrid`, `Workspace`). |
| `ClusterSpatialAdjacency.swift` | Builds electrode adjacency (`ClusterAdjacencyMethod`) that defines "neighbouring" for clustering. |
| `ClusterStatisticsDistributions.swift` | Null-distribution / p-value machinery. |
| `ClusterStatisticsRunner.swift` | Prepares conditions (`PreparedData`), picks statistic/pairing, runs the analyzer, and packages output + waveform summaries. |
| `ClusterStatisticsViews.swift` | The results UI: cluster heatmap and per-condition trace charts. |

**Latency-variable single-trial analysis**

| File | Synopsis |
|---|---|
| `RIDEAnalyzer.swift` | Residue Iteration Decomposition: separates S/C/R components by latency (`decompose`, `estimateTemplate`, `reconstruct`, `bestLag`). |
| `WoodyAlignmentAnalyzer.swift` | Woody adaptive-filter latency alignment (`align`, `bestLag`, `peakLag`). |
| `NonlinearAligner.swift` | Nonlinear time-warping alignment + functional PCA (`WarpedTrial`, `FunctionalPCA`). |
| `CWTRidgePipeline.swift` | Per-trial CWT-ridge feature extraction (`TrialResult`, `PeakSource`). |

## How to extend this

A new **statistic** is a `ClusterStatisticKind` handled in
`ClusterStatisticsRunner` and fed to the analyzers; a new **correction** extends
`ClusterFormation` (mirror TFCE). Adjacency is separable — a new neighbour
definition is a `ClusterAdjacencyMethod`. For single-trial work, add an analyzer
here (mirror `RIDEAnalyzer`/`WoodyAlignmentAnalyzer`) and wire a run job in
[epoching.md](epoching.md)'s `SingleTrialAnalysisViews`. These engines are
performance-critical and run many permutations/trials concurrently — keep them
allocation-light and free of shared mutable state.
