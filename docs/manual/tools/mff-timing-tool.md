# MFF Timing Tool

`mff-timing-tool` inspects the `Events*.xml` files inside an MFF package. It
answers two questions: *what event codes does this recording actually contain*,
and *how far apart are these two codes*.

The second is the common one in practice — measuring the offset between a
stimulus code written by presentation software and the DIN pulse from a photocell
or audio trigger, which is how you find out what your true stimulus timing was.

```bash
sh Tools/mffTimingTool/build.sh
```

The binary lands at `Tools/mffTimingTool/.build/mff-timing-tool`.

## Listing event codes

```bash
Tools/mffTimingTool/.build/mff-timing-tool --list path/to/recording.mff
```

Prints a tab-separated table of every unique code found across all `Events*.xml`
files, with counts, the source XML file, and the labels, descriptions, source
devices and key names seen for each. This is the fastest way to find out what a
recording is actually marked up with — including codes EVA's UI may not surface
prominently.

## Measuring an offset between two codes

```bash
Tools/mffTimingTool/.build/mff-timing-tool path/to/recording.mff \
  --code stm+ --din DIN1
```

| Option | Default | Notes |
| --- | --- | --- |
| `--list` | — | List codes instead. Cannot be combined with `--code`/`--din`. |
| `--code <event-code>` | *required* | The primary (stimulus) event code. |
| `--din <din-code>` | *required* | The comparison/DIN event code. |
| `--pair <mode>` | `nearest` | `nearest`, `next`, or `previous`. |
| `-h`, `--help` | — | |

Pairing modes:

- `nearest` — pair each `--code` event with the closest `--din` event in either
  direction.
- `next` — require the DIN to fall *after* the code event.
- `previous` — require it to fall *before*.

Use `next` when you know the DIN follows the stimulus code and want to avoid a
stray earlier pulse being matched.

Matching is **case-sensitive** and uses the MFF `<code>` field exactly.

## Reading the output

Two tab-separated tables and a summary block:

1. **Per-pair rows** — `code_index`, `code_time`, `code_xml`, `din_index`,
   `din_time`, `din_xml`, `delta_ms`.
2. **Summary** — the code and DIN used, the pairing mode, the number of pairs,
   and the mean, median and mode of the delta in milliseconds.
3. **Frequency table** — how often each distinct delta occurred, with
   percentages.

The frequency table is usually the interesting one. A tight single-valued
distribution means a fixed, correctable presentation lag; a broad or bimodal one
means jitter you cannot correct by subtracting a constant.

If no pairings are found under the chosen `--pair` mode, the tool says so rather
than reporting an empty summary.
