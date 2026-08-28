# Command-Line Tools

EVA ships a handful of command-line programs alongside the app, in the `Tools/`
directory of the repository. They cover the jobs that do not belong in a
graphical application: batch format conversion, generating test data, checking
one run against another, and regenerating model or fixture files.

None of them are installed with the app. Each is built from source with a small
script, and each writes its binary into its own `.build` directory.

## What each one is for

| Tool | Use it when you want to |
| --- | --- |
| [EVA Simulate](eva-simulate.md) | Generate synthetic EEG with known ground truth — for teaching, for testing a correction method, or for benchmarking. |
| [Method Comparison](method-comparison.md) | Measure every correction method EVA offers against simulated ground truth and get a table — which method is better, and by how much. |
| [EVA BIDS](eva-bids.md) | Convert recordings between MFF and BIDS-EEG, or check a BIDS-EEG dataset before importing it. |
| [EVA Helper](eva-helper.md) | Batch-apply gradient and carbon-wire-loop correction to simultaneous EEG/fMRI recordings without opening the app. |
| [MFF Timing Tool](mff-timing-tool.md) | Inspect the event codes in an MFF package, or measure the offset between a stimulus code and its DIN. |
| [Maintenance scripts](maintenance-scripts.md) | Compare two processed recordings byte for byte, rebuild the ICLabel model, or regenerate a test fixture. |

## Building

Every Swift tool has a `build.sh` next to its sources. Run it from anywhere:

```bash
sh Tools/EVASimulate/build.sh
```

The script prints the path of the binary it produced, which is always
`Tools/<Tool>/.build/<binary-name>`. `.build` is ignored by git.

The tools compile directly against EVA's own source files rather than importing
a framework — `Tools/EVASimulate/build.sh`, for instance, compiles
`EVA/Core/DSP.swift` and `EVA/IO/MFFReader.swift` into its binary. That is
deliberate: a tool cannot drift away from the app's behaviour if it is built from
the app's code. It does mean a build script has to be updated when a file it
compiles is renamed or when that file gains a new dependency.

!!! note "If a build script fails on a missing file"
    A tool's build script lists its source files explicitly, so a file removed or
    renamed in the app breaks it until the list is updated. The error names the
    missing path. This is a known state for [EVA Helper](eva-helper.md).

### Building requires a Swift toolchain

Xcode or the Swift command-line tools must be installed, and `xcode-select -p`
should point at a working Xcode. The tools target macOS and use Accelerate for
their numerical work.

## Two things worth knowing before you start

**Path capitalization matters for the build cache.** Each build script keys its
module cache by the path it was launched from, because clang records the literal
path of every cached module and refuses to load two spellings of the same one. On
a case-insensitive filesystem, `~/Programming/eva` and `~/Programming/EVA` are the
same directory but different spellings — without the keying, building from one
after the other crashes the compiler with `module '_DarwinFoundation1' is defined
in both …`. If you hit that in a tool that does not key its cache, delete the
tool's `.build/ModuleCache*` directory and rebuild.

**These tools read and write real MFF packages.** An `.mff` "file" is a directory,
and the tools that write one replace it wholesale. Passing an existing output path
either fails with a clear message or requires `--overwrite`, depending on the
tool. None of them modify their input.
