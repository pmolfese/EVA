# BDF import validation

EVA reads BDF and contiguous BDF+ natively in Swift. Python/MNE is used only to
produce independent regression references, never at application runtime.

`make_bdf_fixtures.py` creates the tiny Government-authored
`EVATests/Fixtures/BDF/sample.bdf` and MNE's sample-by-sample `.f32` and event
`.json` answers. The fixture includes signed 24-bit extrema, nontrivial per-channel
calibration, initial triggers, code-to-code transitions, and pulses crossing a
record boundary. Rebuild it with:

```sh
python -m pip install mne numpy
python Tools/bdf-import/make_bdf_fixtures.py
```

MNE reports voltage channels in microvolts for the reference. Its Status/STIM
output is masked to 17 bits; EVA preserves all 24 raw bits, so the comparison
uses MNE's mask. Separate tests assert the full raw words. Event comparisons use
`mask=0xffff`, `consecutive=True`, `initial_event=True`, `shortest_event=1`.

## Optional manufacturer recordings

BioSemi supplies two 60-second, 17-channel sine-wave recordings at 256 and
2048 Hz: <https://www.biosemi.com/faq/file_format.htm>.
Download <https://www.biosemi.com/download/BDFtestfiles.zip>, extract it into
`.regression-corpus/bdf/`, then generate local references:

```sh
python Tools/bdf-import/make_bdf_fixtures.py --vendor-dir .regression-corpus/bdf
xcodebuild test -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' \
  -only-testing:EVATests/BDFImportTests
```

The vendor test compares every sample and trigger onset in both files; it skips
explicitly if the optional corpus is missing. Manufacturer files and their
references stay in the ignored corpus and are not redistributed. The committed
synthetic fixture always runs.

Additional synthetic Swift tests cover mixed rates, analog resampling, raw Status
sample-and-hold, auxiliary channel roles, calibration offsets and negative gains,
unknown record counts, BDF+ UTF-8 annotations and fractional start times,
four-digit dates, malformed files, real discontinuities, and MFF export with
PNS/events/eva.xml intact.

Format references:

- <https://www.biosemi.com/faq/file_format.htm>
- <https://www.biosemi.com/faq/trigger_signals.htm>
- <https://www.teuniz.net/edfbrowser/bdfplus%20format%20description.html>
- <https://www.edfplus.info/specs/edfplus.html>
