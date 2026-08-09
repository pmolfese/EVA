# Supported Formats

## Native Support

| Format | Extensions | Notes |
| --- | --- | --- |
| EGI/MagStim MFF | `.mff` | Native reading and processed MFF export. |

## Additional Readers

| Format | Extensions | Notes |
| --- | --- | --- |
| BrainVision | `.vhdr`, `.vmrk`, `.eeg` | Not fully tested. |
| EDF / EDF+ | `.edf` | Not fully tested. |
| Persyst | `.lay`, `.dat` | Not fully tested. |
| BESA | `.avr`, `.mul` | Not fully tested. |

## Sensor Sidecars

EVA can use optional electrode-location sidecars when the recording does not include sensor geometry:

- `.sfp`
- `.elp`
- `.loc`

## Export

EVA can export processed recordings back to MFF, including continuous, epoched, or averaged data.
