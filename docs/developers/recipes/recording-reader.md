# Recipe 4: add a small recording reader

**Goal:** add an explicitly limited teaching format, `.evademo`, and follow it
from file selection to normalized signal data and MFF export/reimport. Read
[recipe setup](README.md) and [the data contract](../data-and-lifecycle.md).
Apply [04-recording-reader.patch](../examples/04-recording-reader.patch).

This is a tutorial format, not support for a real vendor format. A production
reader also needs representative files, a documented format specification,
provenance/license review, and the relevant malformed-input/performance checks.

## 1. Define a format that cannot be misinterpreted

Save this JSON as `example.evademo` in a practice directory:

```json
{
  "version": 1,
  "samplingRateHz": 1000,
  "channelNames": ["Demo1", "Demo2"],
  "samplesMicrovolts": [[1, -2, 3, 4], [4, 3, -2, 1]]
}
```

Arrays are channel-major: two channels, four samples each, in microvolts. The
duration is `4 / 1000 = 0.004` seconds. This tiny fixture is for deterministic
tests; use a longer generated file to inspect a waveform meaningfully in the UI.
Version 1 has no events, epochs, PNS, sidecars, recording date, or measured
geometry. Absent metadata stays absent; the reader does not fabricate it.

## 2. Implement validation before constructing the signal

The patch adds `EVA/IO/DemoSignalReader.swift` with the NIH header and a
`nonisolated` enum. Its nested `Decodable` struct defines the JSON fields. The
reader loads bytes, limits JSON input to 1 MiB before decoding, rejects versions
other than 1, and checks:

- A finite, positive sampling rate and finite resulting duration.
- At least one nonempty channel, with the same sample count in every row.
- A matching count of unique, nonblank channel names.
- Finite sample values.

Parse/shape errors become `SignalImportError.malformedFile`; an unknown version
becomes `unsupportedVariant`. A file I/O failure remains an I/O error. The size
check bounds accepted JSON, but loading/mapping happens before it; it is not a
streaming-reader design for huge files.

The initializer receives explicit shape and timing:

```swift
        let signal = MFFSignalData(signalURL: url, signalType: "EEG",
            numberOfChannels: data.count, samplingRate: document.samplingRateHz,
            duration: duration, recordingStartTime: nil,
            events: [], data: data, channelNames: document.channelNames,
            channelUnits: Array(repeating: "uV", count: data.count))
```

The reader returns `ImportedRecording` with no PNS or explicit geometry. The
common import path can still perform its normal location inference. A real
format with volts would require conversion to microvolts at this boundary;
changing a unit label alone would not convert the samples.

## 3. Register and route the input

In [`SignalImportReader`](../../../EVA/IO/SignalImportReader.swift), add `evademo`
to `supportedRecordingExtensions` and dispatch that extension to the reader.
Both matter: a working parser hidden behind an unsupported-extension check
cannot be opened normally. Existing extension normalization handles capitalization.

The patch adds an exported type declaration in
[`EVA/Info.plist`](../../../EVA/Info.plist), conforming to `public.json`, and
updates the recording-open hints in
[`ContentView`](../../../EVA/App/ContentView.swift). The open panels already
accept data/text types. The tutorial does not advertise Finder preview support
or add a QuickLook reader: those are separate extension products/contracts.

The new file belongs to the synchronized `EVA/` source group. It is app-only:
it uses `ImportedRecording` and `SignalImportError` from the app import layer.
Moving a reusable parser into `EVACore/` would require an app adapter plus checks
of all consuming targets. Do not add `import EVACore`; there is no such standalone
module in the current project.

## 4. Test dispatch, failure, and export

The patch adds `EVATests/IO/GuideDemoReaderTests.swift`. It creates temporary input
files and cleans up only its own UUID-named files. The successful case goes
through **the dispatcher**, checks samples/rate/duration/labels, exports using
`MFFExportWriter`, and reads the MFF back to compare samples and labels.
Parameterized cases reject unknown version, zero rate, ragged rows, duplicate
labels, empty channels, and malformed JSON.

```sh
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' \
  -only-testing:EVATests/GuideDemoReaderTests \
  -only-testing:EVATests/MFFExportWriterTests
```

Run the normal app and open a longer `.evademo` file through File → Open Recording
and drag-and-drop. Verify reported dimensions and errors for a malformed file.
Apply a filter and export to a new MFF destination; reopen and compare metadata.
Existing processing/history code now consumes normalized signal data and should
not need a format-specific branch in each engine. Interactive/headless batch
input discovery may have separate format restrictions: this patch does not claim
every batch preflight or CLI tool accepts `.evademo`. Extend and test those paths
explicitly before advertising format support there.

## 5. Before treating a reader as production support

Add coverage for size boundaries, very small rates/invalid durations, missing
fields, nonfinite/overflow numbers, uppercase extensions, names/units and
recording metadata. Decide how events, gaps, segmented data and geometry are
represented rather than guessing. Verify security-scoped sidecars for formats
that use multiple files. Update the user format reference, feature map, source
inventory, and any affected CLI/Finder/batch consumers.

**Exercise:** add a test that a valid file with exactly one sample per channel
has the correct duration and survives MFF export, then explain why that is not
the same as a four-second waveform-display test.
