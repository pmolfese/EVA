# Recipe 1: add a display-only option

**Goal:** let the Dataset Info sheet hide its Acquisition section without changing
the recording or saved processing. Prerequisites: [recipe setup](README.md) and
the [SwiftUI state guide](../swift-in-eva.md). Use
[01-display-option.patch](../examples/01-display-option.patch) for the exact edit.

## 1. Find the view and choose the lifetime

Open [`DatasetInfoSheet.swift`](../../../EVA/IO/DatasetInfoSheet.swift). It is a
standalone `View` that receives the recording, epoching model, and callbacks from
its caller. Its body contains Dataset, Acquisition, and optional XML sections.
This option affects only whether metadata rows are shown; it does not modify the
metadata or samples.

The option belongs to this sheet presentation, so add local state alongside its
other `@State` properties:

```swift
    /// Presentation only; recreated with this sheet, never written to the recording.
    @State private var showsAcquisitionDetails = true
```

`@State` lets SwiftUI preserve and observe the value for this view's identity
while its body is recomputed. A plain stored `Bool` would not provide a mutable
binding in this value-type view. `@AppStorage` would persist the setting across
presentations and potentially windows; that is a different product requirement.

## 2. Bind a control and conditionally build content

Place the following toggle immediately before the Acquisition section, then wrap
that existing section in `if showsAcquisitionDetails { ... }`, as the patch shows:

```swift
                Toggle("Show acquisition details", isOn: $showsAcquisitionDetails)
```

The `$` produces a `Binding<Bool>`: the toggle can read and update the state.
The `if` inside the view builder controls which child views exist. It does not
prevent the existing metadata-loading task from running, and it does not delete
the loaded metadata. The default `true` preserves the existing initial display.

Keep this control local to the sheet; no app menu command is needed. If the
requirement later moves to a recording-wide menu, promote ownership deliberately
to the window/store and connect focused-window command state. Do not create an
app-global flag merely to make the menu reach it.

## 3. Compile and inspect

Apply the patch using [the common instructions](README.md#work-safely-in-a-practice-checkout),
then build the normal EVA scheme:

```sh
xcodebuild -project EVA.xcodeproj -scheme EVA -destination 'platform=macOS' build
```

Run from Xcode, open the synthetic recording, and choose **File → Dataset Info**.
Confirm the Acquisition section initially appears; switch the option off and on.
The section should disappear/reappear without changing channel count, sample
rate, category labels, or processing history. Try a non-MFF import too: hiding
the rows should not affect the sheet's existing handling of unavailable metadata.
Close and present the sheet again, and check the intended local-state lifetime.
Test two recording windows independently. Check the fixed sheet size with the
section both visible and hidden.

This reversible view change needs compilation and UI checks; a unit test that
merely asserts a Boolean can change would not verify the behavior. The patch
adds no such test. UI acceptance is recorded separately from compilation.

## 4. Review the boundary

Only `DatasetInfoSheet.swift` changes. There is no processing parameter, sample
revision, invalidation, `eva.xml` field, or replay step because nothing about
the recording or computation changed. The existing metadata task still has its
normal lifetime. If a toggle instead changed filtering or file interpretation,
this boundary would be wrong; use the next recipe.

**Common mistakes:** hiding the whole Form rather than the section; moving the
toggle inside the section it hides; using a plain mutable property instead of
state; persisting a presentation detail without a requirement; treating a
successful compile as a completed visual check.

**Exercise:** add a second local display choice for the XML browser. Keep the
control accessible when its content is hidden and explain whether toggling it
should cancel the parsing task or only hide its result. Verify that choice in
the UI before describing the exercise as complete.
