# MFF Timing Tool

Quick Swift command-line helper for inspecting `Events*.xml` files inside an
EGI MFF package and calculating timing offsets between two event code sets.

## Build

```sh
Tools/mffTimingTool/build.sh
```

The binary is written to:

```sh
Tools/mffTimingTool/.build/mff-timing-tool
```

## Usage

List unique event codes parsed from every `Events*.xml` file:

```sh
Tools/mffTimingTool/.build/mff-timing-tool --list path/to/recording.mff
```

The list output includes counts, source XML files, labels, descriptions, source
devices, and key names seen for each code.

Calculate offsets from one event code to another:

```sh
Tools/mffTimingTool/.build/mff-timing-tool path/to/recording.mff --code stm+ --din DIN1
```

By default, each `--code` event is paired with the nearest `--din` event across
all event files. Use `--pair next` or `--pair previous` to require the DIN event
to occur after or before the code event:

```sh
Tools/mffTimingTool/.build/mff-timing-tool path/to/recording.mff --code stm+ --din DIN1 --pair next
```

Matching is case-sensitive and based on the MFF `<code>` field.
