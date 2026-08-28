# Troubleshooting

## A Recording Does Not Open

Check:

- The file format is supported.
- Sidecar files are present for split formats.
- The recording is not still inside a compressed archive.
- The app has permission to access the selected folder.

## Events Are Missing

Check:

- Event sidecar files are present for formats that store markers separately.
- The selected file is the header or package expected by the format.
- The event labels are not hidden by the current view settings.

## Topographic Maps Are Unavailable

Check:

- Sensor geometry is included in the recording or sidecar file.
- Channel labels match the sensor layout.
- Non-EEG auxiliary channels are not being treated as scalp electrodes.

## Processing Feels Slow

Large recordings and artifact-correction workflows can be computationally expensive. Let long-running jobs finish and avoid stacking multiple heavy operations at once.

For development builds, collect a reproducible example and include the recording type, sampling rate, channel count, operation, and approximate recording length.
