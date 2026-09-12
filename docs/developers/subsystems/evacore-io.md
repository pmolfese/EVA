# EVACore IO — format readers/writers — `EVACore/IO`

**Purpose.** The UI-free file-format layer: read and write every neuroimaging
format EVA understands. This is the single source of truth for the on-disk
formats — the app (`EVA/IO`), the CLI tools, and the QuickLook/Thumbnail
extensions all go through here, so a format change made here reaches all of them
at once.

**Start here.** `MFFReader` / `MFFWriter` (EGI `.mff`, EVA's native format) and
`MFFSignalData` — the in-memory signal the whole app is built around. The `FIF/`
group reads MNE `.fif`; `NIfTI/` and `GIFTI/` read MRI volumes and surfaces;
`OpenMEEG/` imports BEM geometries.

## MFF (native) — `EVACore/IO`

| File | Synopsis |
|---|---|
| `MFFReader.swift` | Parses the `.mff` package: `MFFPackage`, `MFFSignalData` (the in-memory signal), `MFFEvent`, epoch/category blocks, anti-alias timing correction, reference state; non-destructive editing helpers (`replacingSamples`, `reconstructingTimeline`). |
| `MFFWriter.swift` | Writes `.mff` back out (`MFFExportKind`, export blocks/events, timestamps). |
| `MFFFileType.swift` | MFF file-type/UTI identification. |
| `EGISensorXMLParser.swift` | Parses EGI `sensorLayout.xml` (note the historical y-flip fix). |

## FIF (MNE) — `EVACore/IO/FIF`

| File | Synopsis |
|---|---|
| `FIFFile.swift` | The FIFF tag stream: `FIFReader` / `FIFWriter`, `FIFTag`, errors. |
| `FIFDocument.swift` | High-level FIFF document/outline (block structure). |
| `FIFRecording.swift` | A recording read from FIFF (`Content`, `Segment`, `FIFAnnotation`). |
| `FIFMeasurementInfo.swift` | Measurement info: channels, projectors (`FIFChannelInfo`, `Projector`). |
| `FIFInterop.swift` | Interop types: digitization points, BEM surfaces from FIFF. |

## NIfTI (volumes) — `EVACore/IO/NIfTI`

| File | Synopsis |
|---|---|
| `NIfTIHeader.swift` | NIfTI-1/2 header parsing: version, byte order, datatype, affine, orientation. |
| `NIfTIVolume.swift` | The volume itself + write datatypes + gzip encoding. |
| `NIfTIByteSource.swift` | Abstracts file vs. gzip byte access (`NIfTIByteSource`). |
| `NIfTIScalarDecoder.swift` | Decodes scalar voxel data across datatypes. |

## GIFTI (surfaces) — `EVACore/IO/GIFTI`

| File | Synopsis |
|---|---|
| `GIFTIQuickLookReader.swift` | Parses GIFTI (`.gii`): arrays, encodings, datatypes, coordinate transforms. |
| `GIFTIPreviewModel.swift` | A renderable model: points/triangles/labels/scalar overlays. |
| `GIFTICompanionSurfaceResolver.swift` | Finds the companion geometry surface for an overlay `.gii`. |

## BEM geometry — `EVACore/IO/OpenMEEG`

| File | Synopsis |
|---|---|
| `OpenMEEGGeometry.swift` | Reads OpenMEEG `.geom`/`.cond` geometry (`Interface`, `DomainBound`) for BEM import. |

## How to extend this

A new **format** is a reader (and, if writable, a writer) here that produces
`MFFSignalData` or the appropriate model — never parse bytes in the app layer, or
QuickLook and the tools won't see it. Keep readers tolerant of real-world files
(the MFF/FIF readers carry hard-won workarounds for scaling, timing anchors, and
reference state — read the surrounding comments before "simplifying"). Anything
that changes `MFFSignalData` affects every downstream stage, so treat it as a
data-model change.
