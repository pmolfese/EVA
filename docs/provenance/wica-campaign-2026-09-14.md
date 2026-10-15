# W-ICA campaign — 2026-09-14

This is the first full run of the fixture-only W-ICA campaign described in the
[W-ICA campaign runbook](../manual/tools/wica-campaign.md).

## Invocation

```bash
scripts/evaluate-wica-campaign.sh
```

The run completed 90 ICA fits (10 seeds × three severities × blink, EMG, and
electrode-pop artifacts) plus every cleaning arm in 1,520 seconds. The raw
per-seed table is `eva-wica-campaign.csv`; the grouped table is
`eva-wica-campaign.md` in the generated `.wica-campaign/` directory.

## Main result

Truth-selected component rejection was the best endpoint in this first grid.
Mean artifact-error reduction, averaging the three severities equally, was
0.752 for blinks, 0.699 for EMG, and 0.871 for electrode pops. Corresponding
mean planted-transient preservation was 0.963, 0.937, and 0.982.

Oracle-selective W-ICA at the 0.25× coefficient gate was within 0.001 reduction
of rejection for all three artifact classes. That is not evidence that W-ICA is
better: in these simulations ICA usually isolated the artifact into one or a
few high-purity components, and hard wavelet thresholding removed nearly the
entire selected component. EMG output was numerically identical at 0.25×,
0.50×, and 1.00×. The next W-ICA experiment needs deliberately mixed
brain/artifact components and a sweep over threshold *rule/model*, especially
soft shrinkage, rather than another scale-only sweep.

All-component W-ICA was unsafe in this grid. Averaged over severity, its
artifact reduction was -3.855 for blink, -8.052 for EMG, and -0.145 for pop;
the negative values mean greater error than the uncorrected recording. Direct
channel wavelets also strongly damaged planted brain transients and only became
competitive for very large electrode pops.

## Routing and ICA findings

ICLabel selection was the main practical bottleneck. Deduplicated across
campaign cells, it selected components carrying an average 53.2% of known blink
artifact energy, 50.0% of EMG energy, and 0% of pop energy. Its extra false
selections often made correction worse than leaving the signal untouched. A
deployable policy therefore cannot equate every non-Brain ICLabel class with
automatic rejection or W-ICA processing; it needs class-specific confidence,
topographic/temporal checks, and an explicit Channel Noise path.

Picard-O averaged 7.14 seconds per 24-second, 20-channel fixture at a 100 Hz fit
rate. Sixty-four of 90 fits (71.1%) reached the 250-iteration cap. A focused ICA
algorithm comparison should precede the mixed-component campaign: Picard,
Picard-O, and FastICA should be compared on convergence, runtime, artifact
energy concentration, and downstream cleaning—not merely whether a fit returns.

## Decision

Keep W-ICA fixture/test-only. Preserve the current panel because it exposes the
right evidence (labels, topomaps, original/cleaned component waveforms), but do
not enable automatic all-component processing. The next ordered experiments
are:

1. compare ICA algorithms on this fixed corpus;
2. calibrate class-specific ICLabel selection and Channel Noise detection;
3. create mixed-component stressors and sweep hard/soft threshold models;
4. only then compare strict full-ICA reconstruction with residual-preserving
   reconstruction.
