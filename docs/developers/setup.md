# Set up EVA and open your first recording

**Goal:** build the app, generate a small recording containing no participant
data, and open it in EVA. You need basic terminal/Git knowledge; no prior Swift
or EEG experience is assumed. Then continue with [your first change](first-change.md).

## 1. Check the development environment

EVA's documented runtime requirement is an Apple silicon Mac with macOS 15 or
later. The project deployment target is macOS 15.0. Building also requires the
full Xcode application and its macOS SDK and Metal compiler components; installing
only Command Line Tools is insufficient. Complete Xcode's first-launch setup.

Run these in Terminal:

```sh
xcode-select -p
xcodebuild -version
xcrun swift --version
uname -m
```

The selected developer directory should belong to the Xcode installation you
intend to use, for example `/Applications/Xcode.app/Contents/Developer`, and
`uname -m` should report `arm64`. If multiple Xcodes are installed, select the
intended Command Line Tools installation in Xcode's settings. A per-terminal
alternative, if Xcode is at the path above, is:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

The [validation record](onboarding-validation.md) names the toolchain used to
check this guide and its limitations. It is not a tested minimum-Xcode claim.
The project uses Swift language mode `5.0` with newer compiler features, including
default main-actor isolation; that setting does not mean any Swift 5 compiler
can build it. See [Swift in EVA](swift-in-eva.md) when these terms appear in code.

## 2. Open the checkout and understand the build choices

For a new checkout:

```sh
git clone https://github.com/pmolfese/EVA.git
cd EVA
git status --short
open EVA.xcodeproj
```

If you already have the project, use its existing folder instead. Run all later
terminal commands from the directory containing `EVA.xcodeproj`. Inspect existing
Git changes before editing so you can distinguish your work from earlier work.

A **target** defines a build product, such as an app or test bundle. A **scheme**
chooses which targets to build, run, and test. A folder can supply source files
to several targets without being a library of its own.

| Target(s) | Purpose / where the source comes from |
| --- | --- |
| `EVA` | Main app; compiles `EVA/`, `EVACore/`, and `EVAPreviewKit/` source groups. Builds and embeds the simulator and Finder extensions. |
| `EVATests`, `EVAUITests` | Unit/integration tests and UI automation tests for EVA. Both are listed in the shared `EVA` scheme. |
| `EVAResolve`, `EVAResolveTests` | Separate head-model app and its tests, using the shared `EVAResolve` scheme. Resolve also compiles `EVACore/`. |
| `EVAQuickLook`, `EVAThumbnail` | Finder extension products; share `EVAPreviewKit/` and `EVACore/` sources. |
| `EVASimulate` | Command-line recording generator; explicitly listed tool sources plus the `EVACore/` group. It is a target, not a shared scheme. |

There is **no separate `EVACore` library target** in this project. When adding a
shared source file, check all targets and CLI build scripts that consume that
folder. See the [architecture map](architecture.md#source-groups-and-build-targets).

## 3. Build and run locally

In Xcode, choose the **EVA** scheme and **My Mac** destination. Use **Product →
Build** (Command-B). After a successful build, use **Product → Run** (Command-R).
The expected checkpoint is an EVA recording window with an option to open a
recording, before you have loaded any data.

If signing fails, select the project in the navigator and inspect **Signing &
Capabilities** for `EVA` and the embedded `EVAQuickLook` and `EVAThumbnail`
targets. The checked-in project has the maintainer's development team setting.
For a signed local run, select a team and signing setup available to you; an
account may not have access to the checked-in bundle identifiers/capabilities.
Keep any machine-specific team/identifier edits out of an unrelated code change.
Resolve a specific signing diagnostic with your maintainer if your account cannot
satisfy it. Distribution credentials and `scripts/release.sh` are not part of
this first local build.

The equivalent normal terminal build is:

```sh
xcodebuild -project EVA.xcodeproj -scheme EVA -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/onboarding build
```

Expected output ends with `** BUILD SUCCEEDED **`; the app is at
`build/onboarding/Build/Products/Debug/EVA.app`. `build/` is Git-ignored. If you
only need a compilation diagnostic that does not require development signing,
add `CODE_SIGNING_ALLOWED=NO` before `build`. An unsigned successful compilation
does not verify launching, sandbox entitlements, or Finder extension behavior.

Keep Metal enabled in the normal build. Some app paths load a compiled
`default.metallib`; omitting `.metal` files to bypass a compiler failure can
produce an app that fails at runtime.

## 4. Generate a small synthetic recording

Build the simulator independently, which is also useful when investigating an
app-specific setup problem:

```sh
EVA_SIM_BUILD_DIR="$PWD/build/onboarding-simulator"
xcodebuild -project EVA.xcodeproj -target EVASimulate -configuration Release \
  SYMROOT="$EVA_SIM_BUILD_DIR/products" OBJROOT="$EVA_SIM_BUILD_DIR/objects" \
  CODE_SIGNING_ALLOWED=NO build
EVA_SIM_BIN="$EVA_SIM_BUILD_DIR/products/Release/EVASimulate"
"$EVA_SIM_BIN" --help
```

Keep using the same terminal so these variables remain defined. The simulator
is a separate command-line program; its successful build does not prove the
EVA app or Metal shaders build successfully.

Create a fresh output directory and a short, repeatable recording:

```sh
EVA_SAMPLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eva-onboarding.XXXXXX")"
"$EVA_SIM_BIN" generate --output "$EVA_SAMPLE_DIR" \
  --channels 8 --rate 1000 --duration 10 --seed 42
printf 'Open this recording in EVA: %s\n' "$EVA_SAMPLE_DIR/sim_noisy.mff"
ls "$EVA_SAMPLE_DIR"
```

Expect `sim_clean.mff`, `sim_noisy.mff`, and `sim_truth.json`. The clean recording
is simulated ground truth; the noisy recording adds artifacts; the JSON records
the simulation's truth/settings. There are eight EEG channels, sampled 1,000
times per second for ten seconds (10,000 EEG samples per channel), plus generated
metadata and peripheral channels. A `.mff` is a directory package: keep it intact.
This tiny example exercises opening data, not the scientific validity of a
cleaning method. Longer examples are in the [simulator guide](../../Tools/EVASimulate/README.md).

## 5. Open it and check the result

1. Run EVA from Xcode. Choose **File → Open Recording…** (Command-O).
2. In the file chooser, use Command-Shift-G and paste the full `sim_noisy.mff`
   path printed above. Select/open the package rather than a file inside it.
3. Wait for loading to finish. Confirm that the window shows channel labels and
   non-flat traces. Check that it represents approximately ten seconds of data;
   zoom/scroll if the current viewport shows only part of the recording.
4. Open `sim_clean.mff` as well. Opening a recording creates another recording
   window. The clean and noisy traces should differ; the clean data should
   still contain simulated brain activity.
5. Close the recording windows. No editing or export is required for this check.

If using Finder's Open With, make sure you are opening the development build
you just built rather than an older installed EVA. Running from Xcode avoids
that ambiguity. Record this manual result in the [validation log](onboarding-validation.md).

## When a checkpoint fails

| Symptom | What to check next |
| --- | --- |
| `xcodebuild` requires Xcode, or an SDK is missing | Check `xcode-select -p`, Xcode's first-launch setup, and the selected developer directory. |
| Compiler does not recognize isolation/Swift features | Compare the toolchain to the validation record; Swift language mode is not the compiler version. |
| `cannot execute tool 'metal' due to missing Metal Toolchain` | Install the Metal compiler component for the selected Xcode. Its command-line help supports `xcodebuild -downloadComponent metaltoolchain`; this downloads a component and needs network access. Then rerun the normal build. |
| Signing/provisioning error | Read the failing target name and inspect its Signing & Capabilities, including embedded extensions. Do not use release credentials for this tutorial. |
| `Multiple commands produce` a fixture resource | Read the full destination and both producing inputs. MFF fixture packages must not be flattened into one resources directory. Preserve the package structure and investigate target resource membership separately. |
| Swift macro plugin reports a malformed response | Check whether your build runner/sandbox prevents compiler plugins from executing. Compare with the same build in Xcode before changing valid Swift source. |
| Simulator executable is missing | Check that its build succeeded and that the shell variables still point to the Release product directory. |
| Noisy file cannot be opened | Check the printed output directory, generated files, and that the whole `.mff` package was selected. Check EVA's reported import error. |

Capture the first relevant error, command, scheme, and Xcode version. A final
`BUILD FAILED` line alone is not enough to diagnose a problem. Continue with
[your first change](first-change.md) once the normal build is working; use the
[reading path](getting-started.md) to understand the larger app.
