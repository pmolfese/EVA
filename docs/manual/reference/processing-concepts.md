# Processing Concepts

## Keep The Signal Visible

EVA's central design principle is that processing choices should be inspectable. A user should be able to see the waveform, understand what changed, and revisit decisions.

## Processing History

When documenting a workflow, include the order of operations. EEG processing is order-sensitive: filtering, referencing, interpolation, artifact cleaning, epoching, and averaging can interact.

## Preview Before Applying

Preview cleaning and correction steps when possible. Compare before and after views for:

- Reduced artifact
- Preserved plausible signal
- Absence of new edge artifacts
- Consistency across channels and events

## Explainability

Health scores, ICLabel predictions, and artifact matches should be documented as evidence. Avoid writing documentation that suggests automated outputs are always correct.

## Reproducibility

For methods sections and lab protocols, record:

- EVA version
- Input file format
- Filter settings
- Reference choice
- Bad-channel and interpolation decisions
- Artifact-cleaning methods and parameters
- Epoch windows and baseline intervals
- Export format
