# Getting Started

## Requirements

EVA is a native macOS application. It is built with Xcode and uses Apple platform technologies including SwiftUI, Accelerate/vDSP, Core ML, Swift concurrency, and SwiftData.

For development builds, use:

```bash
xcodebuild -project EVA.xcodeproj -scheme EVA -destination platform=macOS build
```

## Open A Recording

EVA supports drag-and-drop import and standard file-opening workflows. Start by opening a supported EEG recording, then wait for the waveform to appear in the main view.

After the file loads, confirm:

- Channel labels are visible.
- Events appear above or near the waveform when event metadata is available.
- Sampling rate and timing appear plausible.
- Sensor geometry is present if you plan to use topographic views or interpolation.

!!! note "Verify in app"
    Confirm the exact menu path and toolbar labels for opening files before publishing this page.

## First Checks

Before running processing steps, make a quick visual pass:

- Look for flat channels, saturated channels, and high-noise channels.
- Check whether event timing matches the task design.
- Confirm whether auxiliary or physiological channels should be visible.
- Decide whether the current view should use raw, filtered, or averaged data.

EVA is most useful when these checks remain visible while you make processing choices.
