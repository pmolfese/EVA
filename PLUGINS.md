# EVA Plug-in Architecture Plan

Status: proposed architecture, 2026-09-17  
Initial candidates: MARA and external FMRIB FASTR; MAAC migration assessed  
Scope: planning only; no plug-in code is incorporated into EVA by this document

## Executive recommendation

EVA should support plug-ins, but its first plug-in boundary should be an
**out-of-process command protocol**, not a Swift dynamic-library or framework
API. EVA would export a versioned job bundle to a private working directory,
launch a separately installed executable, receive progress messages, validate
the result, show it for review when appropriate, and only then add the result to
EVA's processing history.

For GPL tools such as MARA and FMRIB FASTR, the safest initial distribution
posture is:

1. EVA ships the plug-in host, an open protocol, a harmless conformance plug-in,
   and installation documentation.
2. EVA does **not** ship, link, load, copy, or translate MARA, FMRIB FASTR,
   EEGLAB, MATLAB, or their assets.
3. A user or site administrator installs those tools separately and registers a
   separately distributed adapter with EVA.
4. The adapter runs in its own process and communicates through documented
   command-line arguments, JSON, and simple files. It does not import an EVA
   framework or share EVA memory.
5. EVA records the exact plug-in, adapter, runtime, license declaration,
   parameters, and hashes in its provenance.

This is useful architecture even apart from licensing: a crashing MATLAB or
Python process cannot corrupt EVA's address space, the same adapter can run in
batch or on a cluster, and untrusted results can be checked before they replace
data.

This design is not a device for evading the GPL. The Free Software Foundation's
[GPL FAQ on plug-ins](https://www.gnu.org/licenses/gpl-faq.html#GPLPlugins)
says that both the communication mechanism and the semantics matter. Simple
`fork`/`exec`-style invocation can describe separate programs, while intimate
exchange of complex internal structures can make them one combined program.
NIH counsel or the appropriate software-release office must approve the actual
protocol and distribution arrangement before NIH distributes a GPL adapter or
places one in an official catalog.

## Goals

- Let EVA use specialist methods without incorporating every implementation
  into the application binary.
- Support GPL, permissive, public-work, proprietary, and locally written tools
  without pretending that all licenses have the same obligations.
- Preserve EVA's current public-work status and the no-copyleft-in-the-build
  posture recorded in `LICENSE` and `THIRD_PARTY_NOTICES.md` unless NIH makes a
  deliberate distribution decision to change it.
- Make external processing reproducible, inspectable, cancellable, and usable
  in EVA's interactive, replay, and headless-batch paths.
- Keep raw EEG local by default and expose exactly what a plug-in will receive.
- Support long-running methods with real progress rather than an indeterminate
  spinner.
- Give plug-ins access to well-defined scientific data, not EVA's private Swift
  model types.
- Start with MARA and an external FMRIB FASTR reference runner, while keeping
  the protocol general enough for later classifiers, importers, exporters, and
  corrections.

## Non-goals for version 1

- Loading arbitrary `.dylib`, Swift package, Objective-C bundle, or framework
  code into EVA's process.
- Reproducing EEGLAB's menu-extension mechanism inside EVA.
- Shipping MATLAB, EEGLAB, MARA, or FMRIB FASTR inside `EVA.app`.
- Automatically downloading and executing code from a registry.
- Promising App Store compatibility before it is tested and reviewed.
- A stable Swift ABI for third parties.
- Sending recordings to a network service without a separate, explicit design
  and consent flow.
- Allowing a plug-in to mutate an open `RecordingStore` or write directly into
  an MFF package.

## Why an external process is the right first boundary

EVA currently builds with the hardened runtime. Loading third-party libraries
in process would create three problems at once:

- It is the highest-risk GPL shape because the host and plug-in call one
  another and share data structures.
- It weakens fault isolation. A plug-in crash, memory overwrite, or dependency
  conflict becomes an EVA crash.
- Apple's library validation normally restricts libraries that are not signed
  by Apple or EVA's signing team. Disabling it is a meaningful security
  concession. Apple's
  [library-validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
  specifically warns against disabling it unnecessarily.

An external executable avoids dynamic linking, keeps library validation intact,
and has a natural cancellation and logging boundary. EVA already uses a bundled
command-line process for simulation, so `SimulatorRunner` supplies useful
process-management experience. Plug-ins differ in one important respect: their
executables are user-selected and separately installed, not bundled and signed
as part of EVA.

Apple requires hardened runtime for notarized Developer ID distribution and
requires App Sandbox for Mac App Store distribution; see
[Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
and [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
The v1 design should work with EVA's current hardened-runtime build and should
avoid assumptions that preclude a later sandboxed build.

## Licensing and distribution model

### What EVA's current license means

EVA's Government-authored source is a United States Government work. It has no
domestic copyright restriction, while third-party materials keep their own
licenses. `LICENSE` correctly notes that incorporating a copyleft component into
the build may make the assembled distribution subject to the copyleft license,
even though the Government-authored files remain public work when extracted.

The aim of the plug-in boundary is therefore not to protect proprietary EVA
source. It is to keep third-party obligations accurately scoped, keep EVA's
main distribution uncomplicated, permit independent upgrades, and avoid
shipping runtimes NIH is not entitled or prepared to redistribute.

### Recommended distribution levels

| Level | What NIH/EVA provides | Recommendation |
| --- | --- | --- |
| 1. User-supplied tool | EVA host and protocol; user supplies executable, runtime, and adapter path | **Use for the first MARA and FASTR experiments** |
| 2. External catalog | Signed metadata links to source/releases maintained outside the EVA app; no automatic execution | Add after security and legal review |
| 3. Separate NIH adapter release | Adapter source/binary distributed outside `EVA.app`, with its own license, notices, and corresponding source | Possible after counsel and release approval |
| 4. Bundled adapter/tool | GPL adapter or upstream code inside EVA's installer or app | Do not do initially; requires explicit whole-distribution review |
| 5. In-process plug-in | Third-party code loaded into EVA's address space | Reject for v1 |

If NIH distributes GPL object code, NIH becomes a redistributor and must meet
the applicable source, notice, and installation obligations. GPLv3, for
example, permits an aggregate of genuinely separate works without applying the
GPL to the independent parts, but still requires corresponding source for the
GPL-covered object code; see
[GPLv3 sections 5 and 6](https://www.gnu.org/licenses/gpl-3.0.html#section5).
GPLv2 details are not identical, so every proposed binary release needs an
exact license/version review rather than a generic "GPL compatible" checkbox.

### Rules for GPL-capable plug-ins

- A process boundary is necessary for the recommended design, but not by itself
  sufficient. Keep the protocol general, documented, and usable by unrelated
  tools.
- Do not dynamically link GPL code, load it with `dlopen`, import GPL source,
  translate it into Swift, or share memory containing EVA's private object
  graph.
- Do not make a nominal helper whose only purpose is to disguise an otherwise
  combined program. The adapter must be an independently runnable program with
  a real command interface.
- Do not copy GPL constants, model weights, sample assets, or training data into
  EVA merely because they are not executable source. Their copyright and
  redistribution terms require separate analysis.
- Keep every adapter's source, build scripts, license text, notices, and release
  artifacts together. Record an SPDX expression in its manifest, but retain the
  complete upstream license text as authoritative.
- Do not assume MATLAB is redistributable. The user supplies and licenses
  MATLAB and any required toolboxes.
- Preserve upstream names and citations without implying that NIH or the
  upstream authors endorse the other project.
- Keep an exportable bill of materials for a plug-in run: upstream version,
  adapter version, source URL and commit, runtime version, and asset hashes.
- A plug-in may be used privately without EVA distributing it. The obligations
  change when NIH conveys copies; the release checklist must make that
  distinction explicit.

### Legal questions to resolve before public release

1. Does counsel agree that the versioned, file-based protocol and separately
   installed adapters create independent programs for the proposed MARA and
   FASTR integrations?
2. May NIH host GPL adapter binaries, or should the catalog link only to
   upstream/source releases?
3. If NIH hosts a binary, what corresponding-source and retention process will
   be used for that exact binary?
4. Is EVA expected to ship through the Mac App Store? If so, review the store's
   signing and usage terms against each GPL version before making the plug-in
   available there. Direct notarized distribution should be the baseline.
5. Are the MARA training data and inverse matrix covered by the repository
   license, and are there any independent dataset/model restrictions?
6. The MARA repository advertises GPL-3.0, while source headers visible in
   `processMARA.m` state GPL-2.0-or-later. Which expression governs the complete
   release and its data files?
7. Confirm the exact FMRIB release and license expression. EVA's existing
   provenance records it as GPL-2.0-or-later; the adapter should pin and audit a
   specific upstream commit.

## Architecture

### Components

```text
EVA UI / Batch Controller
          |
          v
    PluginRegistry ------- saved user approvals / security-scoped bookmarks
          |
          v
    PluginRunner --------- process launch, progress, cancel, logs, timeout
          |
          v
  private job directory   request.json + simple binary/JSON inputs
          |
          v
separately installed adapter process
          |
          v
  private job directory   result.json + outputs + diagnostics + checksums
          |
          v
 PluginResultValidator -- shape, units, finiteness, identity, size, schema
          |
          v
 review UI -> ProcessingCore -> PipelineSnapshot / history / eva.xml
```

The host and protocol belong in `EVACore` only if they remain UI-free and avoid
AppKit. User selection, approval prompts, bookmarks, panels, and menu wiring
belong in `EVA`. A practical initial split is:

```text
EVACore/Plugins/
  EVAPluginManifest.swift
  EVAPluginProtocol.swift
  EVAPluginJob.swift
  EVAPluginResult.swift
  EVAPluginResultValidator.swift
  EVAPluginProvenance.swift

EVA/Plugins/
  PluginRegistry.swift
  PluginRunner.swift
  PluginProcess.swift
  PluginPreferencesView.swift
  PluginRunViewModel.swift
  PluginReviewViews.swift

EVATests/Plugins/
  ProtocolCodableTests.swift
  ResultValidationTests.swift
  ReplayTests.swift
  MaliciousPluginTests.swift

Tools/EVAPluginFixture/
  deterministic conformance executable; no third-party code
```

Do not put the MARA or FMRIB adapter under these directories. Use separate
repositories and release processes if EVA later maintains adapters.

### Plug-in package and registration

Call the user-facing object an **EVA external plug-in**, even though it is not
loaded into EVA. A registered plug-in is a small directory such as
`MARA.evaplugin` containing metadata and a launcher reference:

```text
MARA.evaplugin/
  manifest.json
  LICENSES/                 optional license texts for the adapter itself
  README.md
  launcher                  executable or a relative launcher shim
```

For the strictest GPL separation, the `.evaplugin` bundle itself is installed
separately and contains the adapter. EVA only stores a security-scoped bookmark
or an approved absolute path plus a cached copy of non-executable manifest
metadata. It does not copy the bundle into `EVA.app`.

Registration flow:

1. User chooses **EVA > Settings > Plug-ins > Register Local Plug-in…**.
2. EVA reads `manifest.json` without executing anything.
3. EVA shows the declared author, license, source, executable signature,
   requested capabilities, data exposed, network claim, and runtime needs.
4. User approves this exact plug-in identity and path.
5. EVA saves a security-scoped bookmark when sandboxing requires it.
6. **Test Plug-in** runs `launcher describe` and `launcher self-test` without
   providing a recording.
7. The registry marks the plug-in Ready, Needs Runtime, Incompatible, Modified,
   Disabled, or Untrusted.

Changing the executable hash, signing identity, manifest, or resolved path
invalidates prior approval and requires confirmation again.

### Manifest

The static manifest should be JSON, UTF-8, strictly decoded, and covered by a
JSON Schema. Unknown required fields fail closed. An illustrative v1 manifest:

```json
{
  "schemaVersion": 1,
  "id": "org.example.mara-eva-adapter",
  "name": "MARA for EVA",
  "version": "0.1.0",
  "publisher": "Example Publisher",
  "license": {
    "spdx": "GPL-3.0-only",
    "noticePath": "LICENSES/GPL-3.0.txt",
    "sourceURL": "https://example.org/mara-eva-adapter/source"
  },
  "launcher": "launcher",
  "minimumProtocol": 1,
  "maximumProtocol": 1,
  "capabilities": ["ica-component-classification"],
  "algorithms": [{"id": "mara", "name": "MARA"}],
  "runtimeRequirements": ["MATLAB", "EEGLAB", "MARA"],
  "inputKinds": ["eva-ica-v1"],
  "outputKinds": ["eva-component-scores-v1"],
  "parameterSchema": "parameters.schema.json",
  "network": "none",
  "determinism": "deterministic",
  "citations": ["doi:10.1007/s10548-014-0384-6"]
}
```

The live `describe` response must repeat the ID, version, protocol range, and
capabilities. EVA rejects a mismatch between static and live descriptions.

### Invocation and control plane

Use one process per job in v1:

```text
launcher run --protocol 1 --job /private/.../job-UUID
```

The process writes newline-delimited JSON to standard output. Standard error is
captured verbatim as a diagnostic log. Allowed stdout messages are:

```json
{"type":"started","protocol":1}
{"type":"progress","fraction":0.32,"stage":"Computing MARA features","detail":"18/64 components"}
{"type":"warning","code":"RUNTIME_VERSION","message":"..."}
{"type":"result","path":"result.json"}
```

Requirements:

- Progress fractions are monotonic within a named stage and end at 1.0.
- EVA rate-limits UI updates but retains stage changes and warnings.
- Lines over a fixed limit, malformed JSON, unknown message types, or paths
  outside the job directory fail safely.
- Cancellation sends `SIGTERM`, waits a short documented grace period, and then
  terminates the process. Partial output is never committed.
- A configurable timeout protects unattended batch runs.
- Exit code zero is not success by itself; a valid `result.json` and all output
  validations are required.
- The inherited environment is reduced to an allowlist. Secrets and unrelated
  environment variables are not passed through.

### Data plane and job bundle

Do not use shared memory, pointers, Swift archives, Objective-C objects, or an
EVA-only framework. Use an intentionally boring, public format:

```text
job-UUID/
  request.json
  inputs/
    signal.f32
    signal.json
    events.json
    montage.json
    ica.json              only for ICA-capable jobs
  outputs/
  logs/
  result.json
```

`signal.f32` is little-endian IEEE-754 Float32, channel-major, contiguous, with
dimensions, sampling rate, units, channel identifiers, and a SHA-256 hash in
`signal.json`. JSON is sufficient for events, montage coordinates, ICA matrix
metadata, and small diagnostic tables. Large array outputs use the same binary
container rather than enormous JSON arrays.

Protocol design principles:

- Channel IDs are stable identifiers; display names are metadata. Results map
  by ID, never by position alone.
- Units are mandatory and explicit. EVA uses volts at the interchange boundary
  even if a tool internally uses microvolts.
- Sampling rate and time origin are explicit decimal numbers.
- ICA data specify decomposition algorithm, rank, centering vector, whitening,
  unmixing, mixing, component activation layout, sign convention, and hashes.
- Every input and output file is relative to the job root and hashed.
- Unknown files are ignored; unknown required fields or unsupported schema
  versions are rejected.
- Inputs are read-only. The plug-in writes only under `outputs/` and `logs/`.
- The specification is public and implementation-neutral. At least one
  non-MATLAB fixture plug-in must demonstrate interoperability.

The file protocol deliberately exchanges scientific values, because any useful
signal-processing integration must do so. Legal review should nevertheless
assess whether the chosen semantics remain an exchange between independent
programs, as the GPL FAQ says semantics as well as transport matter.

### Result types

Version 1 should support only a small set of typed results:

1. `componentScores`: scores, labels, per-component features, recommended
   selections, and warnings. No sample data are changed until EVA applies a
   reviewed policy.
2. `correctedSignal`: a full signal with exactly the declared channel/sample
   geometry, optionally accompanied by an artifact estimate and diagnostics.
3. `annotations`: events or intervals proposed for review; add only if needed
   by an early plug-in.

Avoid a generic "execute arbitrary EVA commands" result. It would be difficult
to validate, unsafe to replay, and too tightly coupled to EVA internals.

### Validation and transaction rules

Before EVA exposes **Apply**, it must verify:

- manifest ID/version and live process identity match the approved registration;
- request ID and input hashes match the active job;
- every path resolves inside the job directory and is a regular file;
- total and per-file sizes are within declared bounds;
- channel IDs are unique and exactly match the permitted input set;
- sample count, rate, time origin, and units are unchanged unless the result
  type explicitly permits a transformation;
- all output samples and scores are finite;
- component indices and score ranges are valid;
- output hashes match `result.json`;
- no input file was modified; and
- warnings, runtime versions, seeds, and citations are present in provenance.

The plug-in works in a staging copy. EVA commits nothing to the recording or
history until validation succeeds and, for decision results, the user approves
the selection. On crash, cancellation, validation failure, or review dismissal,
the input remains unchanged. Diagnostic logs may be retained after an explicit
privacy-aware choice; working signal files should be deleted promptly.

## EVA pipeline integration

Plug-ins must use the same processing spine as native operations rather than a
parallel UI-only path.

### Processing script

Add an `externalPlugin` case to `EVAProcessingStep.Operation`. Its portable
parameters should include:

- plug-in ID and version constraint;
- adapter executable hash and, where present, signing identity;
- protocol and input/output schema versions;
- capability and algorithm ID;
- canonicalized algorithm parameters;
- declared license/SPDX and source URL;
- runtime names and versions actually used;
- deterministic flag and random seed where applicable;
- input and result hashes;
- whether the recorded result was advisory, reviewed, or automatically applied;
- citation identifiers; and
- a reference to a subject-specific sidecar when the result contains ICA
  scores/selections or other recording-specific data.

Do not put large score arrays, matrices, or samples into `eva.xml`. Store a
versioned `eva_plugin_<job-id>.json` sidecar and hash it from the step, following
the principle already used for ICA and drawn-artifact payloads.

### Replay classification

Replay behavior depends on result type:

- A MARA classification is subject-specific. Reuse it only when the target file
  carries its own sidecar whose ICA/input hashes match. A copied script should
  run classification again and pause for component review.
- A deterministic corrected-signal plug-in can be replayable from parameters if
  the exact approved plug-in/runtime is available and the target supplies its
  own required events and geometry.
- Missing plug-in, changed executable hash, incompatible version, absent runtime,
  or missing inputs pauses replay with **Configure**, **Choose compatible
  version**, or **Skip**. Never silently substitute a native method or another
  plug-in.
- Headless batch proceeds only when the exact dependency is ready and the step
  needs no user decision. Otherwise `HeadlessBatchProcessor` returns
  `needsInput` and the existing windowed path handles it.

The implementation must update the same integration points expected of every
EVA stage: `ProcessingCore`, `PipelineSnapshot`, invalidation rules, replay
settings and payload consistency, defaults, history summaries, audit log,
interactive export, and `HeadlessBatchProcessor`.

### Caching

A cache key may include protocol version, plug-in and executable hashes,
runtime versions, canonical parameters, every input hash, and seed. Cache only
plug-ins that declare determinism and pass repeatability tests. Treat the cache
as an optimization, never the provenance record. A cache hit is validated like
a new result and recorded as such.

## User experience

### Settings > Plug-ins

The settings page lists:

- name, version, publisher, and status;
- capabilities and menu locations;
- license and source link;
- executable location, hash, signature/notarization status, and last change;
- runtime checks, including MATLAB/toolbox/EEGLAB versions where applicable;
- data access and claimed network behavior;
- **Test**, **Reveal**, **Disable**, **Forget**, and **View Log** actions.

"Forget" removes EVA's registration and bookmark; it does not delete the
external program.

### Menus and run panel

Ready plug-ins appear under **Artifacts > External Plug-ins**, grouped by
capability. Native methods keep their existing locations. Selecting a plug-in
opens an EVA-owned sheet with:

- plug-in identity, version, license, source, and citation;
- a plain-language list of data being exported;
- runtime readiness and estimated disk requirement;
- parameters generated from the plug-in's constrained JSON Schema;
- Run and Cancel controls;
- current stage, item counts, elapsed time, and expandable logs; and
- a result-specific review before Apply.

EVA should not render arbitrary HTML/JavaScript or execute a plug-in-supplied UI.
The manifest can describe basic controls—number, integer, Boolean, enum, and
string with bounds—and EVA renders them consistently.

## MARA plug-in design

### Product role

[MARA](https://github.com/irenne/MARA) is an EEGLAB plug-in that classifies
independent components using six spatial, spectral, and temporal features. Its
repository says it was trained from expert ratings of 1,290 components and
requires MATLAB plus Statistics, Optimization, and Signal Processing toolboxes
in addition to EEGLAB.

MARA should enter EVA as a **component classifier and recommendation source**,
not as a second opaque ICA-and-cleaning pipeline. EVA should perform ICA,
export the exact decomposition, ask MARA to classify it, then show MARA beside
ICLabel in EVA's existing component review.

### Inputs

- continuous or epoched signal used for the ICA decomposition;
- sampling rate and channel units;
- channel names, types, and complete electrode coordinates;
- bad/excluded channel set;
- ICA rank, centering/whitening information, weights, sphere/unmixing, inverse
  mixing matrix, and activations;
- decomposition algorithm/version and hashes; and
- optional prior labels for comparison only, never as MARA features unless the
  algorithm explicitly requires them.

The adapter should construct the EEGLAB structure MARA expects inside its own
process. EVA must not serialize MATLAB's private object representation as the
public protocol.

### Outputs

- artifact probability or score for each component;
- recommended reject/retain flag using the adapter's declared threshold;
- the six MARA feature values with names and units;
- warnings for missing/fallback channel geometry;
- MARA, EEGLAB, MATLAB, toolbox, adapter, and model/data versions; and
- no reconstructed signal in v1.

EVA performs any component rejection itself using the decomposition already in
the recording. The review table can add **MARA score**, **MARA recommendation**,
and feature-detail columns beside ICLabel, topomap, raw waveform, and W-ICA
cleaned waveform. Disagreements should be visually prominent. Default behavior
is advisory: the user reviews selections before reconstruction.

Later, a named policy can propose selections such as MARA alone, ICLabel alone,
union, intersection, or agreement-only. Each policy must be evaluated against
the existing simulated corpus before it becomes a default, and the saved step
must record both source scores and the actual reviewed selection.

### MARA proof-of-concept gates

- Pin a single upstream MARA commit and exact EEGLAB/MATLAB support matrix.
- Re-audit licenses for every `.m`, `.mat`, and dependency; resolve the apparent
  repository-license/source-header difference.
- Produce identical component scores to direct MARA for exported fixture
  decompositions within a documented numeric tolerance.
- Verify component order, sign invariance where expected, rank-deficient data,
  missing coordinates, 64/128/256 channels, epoched/continuous data, and all EVA
  ICA algorithms intended for use.
- Keep CI independent of MATLAB: use recorded, license-cleared golden outputs
  for host tests and run live MATLAB tests only in an explicitly configured
  integration environment.

## External FMRIB FASTR plug-in design

### Product role and naming

EVA already contains an independent, clean-room **FASTR-family** implementation
in `GradientTemplateCorrector`, with its process recorded under
`docs/provenance/`. That native, Metal-capable implementation stays the default.

The plug-in should be named **External FMRIB FASTR** everywhere. Its first role
is reference comparison and compatibility on test/fixture data. It must not be
presented as the implementation behind EVA's existing FASTR control.

The upstream [FMRIB EEGLAB repository](https://github.com/sccn/fMRIb) is no
longer maintained according to its README, so pinning, environment capture, and
defensive validation are especially important.

### Inputs

- EEG signal and explicit channel roles, including channels excluded from
  correction;
- sampling rate and units;
- volume or slice event sample indices and event codes;
- slice count, TR/epoch geometry, trigger position, and all FASTR parameters;
- optional ECG/reference channel information required by selected options; and
- a declared mapping from EVA settings to upstream arguments.

### Outputs

- corrected signal, same channel/sample geometry as input;
- optional artifact estimate equal to input minus corrected signal;
- alignment shifts, OBS component counts/bases where available, ANC status, and
  warning list;
- exact upstream arguments after adapter translation; and
- MATLAB, EEGLAB, FMRIB, adapter, and dependency versions.

### FASTR proof-of-concept gates

- Pin and license-audit a specific upstream release/commit, including MEX files.
- Run only against fixtures and simulations at 64, 128, and 256 channels until
  accepted for ordinary data.
- Compare external FMRIB output, EVA native FASTR-family output, and clean truth
  using residual artifact RMS, signal preservation, spectral distortion,
  event-locked residuals, runtime, and memory.
- Exercise volume and slice triggers, OBS on/off and component counts, ANC,
  boundary epochs, flat/reference channels, jitter, missing triggers, and
  cancellation.
- Never call the external implementation as a silent fallback when native EVA
  FASTR fails, or vice versa.
- Keep the external result labeled with its own provenance through export and
  campaign reports.

## What moving MAAC to a plug-in would look like

### First decide what "move MAAC" means

EVA's MAAC support is not one isolated function. The ordered procedure currently
spans:

1. native adaptive line-noise removal;
2. preliminary blink and saccadic-spike detection;
3. saccadic-spike spatial filtering;
4. corneo-retinal dipole regression;
5. native ICA plus component classification/review for blinks;
6. temporal PCA/Promax for movement;
7. BSS-CCA plus component review for muscle; and
8. native trial/channel health, rejection, and interpolation.

The MAAC-specific implementation is already substantial. A rough 2026-09-17
inventory finds about 3,100 lines in the five dedicated compute/detection files,
2,700 lines in their dedicated SwiftUI views, and 1,160 focused test lines. That
does not count shared `ArtifactCleaner` paths, help, view models, ICA, filtering,
pipeline, replay, simulator, or health infrastructure. The extraction should
therefore be treated as an architectural migration, not as moving a few source
files to another target.

There are three possible scopes:

| Scope | External code | Native EVA code | Assessment |
| --- | --- | --- | --- |
| A. External MAAC-specific engines | Preliminary blink/SP, SP filtering, CRD, movement PCA/Promax, muscle BSS-CCA | Mains, ICA/blink review, health, orchestration, all UI | **Recommended if optionality is the goal** |
| B. External ordered MAAC engine | All MAAC-specific engines plus their ordering and intermediate state | Mains/ICA/health are invoked as separate native steps around it | Feasible, but host/plug-in hand-offs are awkward |
| C. Entire end-to-end MAAC procedure | Mains through health, including ICA and all decisions | EVA supplies input, review UI, validation, and history only | Highest duplication and validation cost; not recommended initially |

Scope A is the useful plug-in boundary. It externalizes the specialized
algorithms while keeping the mature, shared functions where they already live.
Scope C would require the plug-in to duplicate or remotely control EVA's filter,
ICA, ICLabel/MARA, bad-channel, epoch, and interpolation behavior. That would
make the plug-in a second processing application and create two implementations
that could drift.

### Licensing effect

Moving MAAC out of the app is not presently required merely because it follows
the MAAC paper. EVA's implementations are Government-authored, literature-based
implementations; algorithms described in a paper are not made GPL simply by an
available GPL reference implementation. The migration would mainly buy modular
distribution, replaceability, and a smaller app surface.

There is one narrower licensing reason to consider it: EVA currently records
GPL provenance for the transformed canonical saccadic-spike topography derived
from EP Toolkit. Putting that asset in a separately distributed plug-in would
make its notices and any applicable redistribution duties easier to scope, but
it would not erase them. A cleaner long-term alternative may be a separately
licensed canonical template, a template derived from a cleared corpus, or
session-only auto-templating. Counsel should decide whether the existing numeric
asset is GPL-covered and which remedy is actually necessary.

If EVA moves its Government-authored MAAC engines to a separate repository,
that repository need not become GPL unless it incorporates GPL-covered material.
Its manifest should state the mixed provenance accurately rather than labeling
the whole plug-in GPL by convenience.

### Recommended hybrid boundary

Create one external plug-in with capability `maac-specific-correction` and five
named operations:

```text
maac.preliminary-ocular-analysis
maac.saccadic-spike
maac.corneo-retinal
maac.movement-pca
maac.muscle-bss-cca
```

EVA remains the pipeline conductor:

```text
EVA CleanLine
    -> plug-in preliminary ocular/SP analysis
    -> EVA review/adjust masks
    -> plug-in SP correction
    -> plug-in CRD analysis
    -> EVA review/adjust blink masks and maps
    -> plug-in CRD correction
    -> EVA ICA + ICLabel/MARA + component review/reconstruction
    -> plug-in movement analysis
    -> EVA review/adjust factors/ranges
    -> plug-in movement correction
    -> plug-in muscle analysis
    -> EVA review/adjust components/ranges
    -> plug-in muscle correction
    -> EVA channel/trial health and interpolation
```

This is more calls than a monolithic runner, but it preserves the scientific
review points that the current UI already exposes and makes every accepted
decision explicit in history. The plug-in owns numerical analysis and
correction. EVA owns menus, waveform/topography/spectrum rendering, user
decisions, ordering, undo/redo, replay, data validation, and final export.

### Protocol additions needed for MAAC

The generic `componentScores` and `correctedSignal` results cover only part of
MAAC. Add the following typed protocol objects rather than a MAAC-specific blob:

- `artifactCandidates`: sample ranges/anchors, kind, confidence, measurements,
  and display text for preliminary blinks, saccadic spikes, movement, and EMG;
- `spatialMap`: channel-ID keyed weights, normalization, polarity convention,
  coordinate provenance, and an optional time course;
- `latentComponents`: per-range mixing/unmixing or back-projection descriptors,
  component diagnostics, automatic choice, and reviewed overrides;
- `stageCorrection`: full corrected signal, optional removed-signal estimate,
  diagnostics, and an exact link to the analysis and decision hashes; and
- `maacCheckpoint`: stage ID, prior-stage output hash, resolved configuration,
  reviewed decisions, warnings, and versions, permitting a run to pause and
  resume without recomputing every earlier stage.

Each analysis/correction pair is two-phase:

1. `analyze` returns candidates, maps/components, diagnostics, and an immutable
   analysis hash without changing samples.
2. EVA collects edits and sends `apply` with that analysis hash and a compact
   decision document. The plug-in rejects stale decisions if the input,
   configuration, or analysis hash changed.

For deterministic replay, store the reviewed decision document and input hash,
not merely "automatic." Movement and muscle configuration/overrides already
have this character in EVA and should map directly to the new sidecar schema.

### Data-transfer and storage cost

A channel-major Float32 signal costs:

```text
bytes = channels * samples-per-second * seconds * 4
```

At 500 Hz for ten minutes, one copy is approximately 77 MB at 64 channels,
154 MB at 128 channels, and 307 MB at 256 channels. Eight full stage snapshots
would be about 0.61, 1.23, and 2.46 GB respectively. At 256 channels for 30
minutes, one copy is about 0.92 GB and eight copies are about 7.4 GB before
diagnostics or artifact estimates.

The runner should therefore not retain a full output for every analysis phase.
It should:

- stream or memory-map the immutable current input where practical;
- write one transactional next-stage signal and atomically promote it after
  validation;
- keep compact candidates/maps/components separately;
- preserve full intermediate signals only when the user requests an end-to-end
  QC bundle;
- generate downsampled display traces for the summary figure; and
- enforce a preflight disk-space budget before a full MAAC run.

When an end-to-end QC export needs every removed stage, storing Float32
**deltas** costs essentially the same as signals unless compressed. Lossless
chunk compression may help on smooth/low-rank artifacts, but the protocol must
not depend on an assumed compression ratio.

### UI consequences

The existing separate MAAC sheets can remain visually almost unchanged. Their
view models would call `PluginRunner` rather than the in-process correctors and
decode protocol DTOs into EVA review models. The future **Run MAAC…** sheet
would add:

- a vertical stage list with Ready, Running, Needs Review, Applied, Failed, and
  Skipped states;
- per-stage elapsed time, progress, input/output hashes, and plug-in version;
- pause-on-review behavior for SP, CRD, ICA/blink, movement, and muscle;
- invalidation of all downstream checkpoints when an upstream setting or
  decision changes;
- one before/after/removed summary row per stage; and
- **Resume**, **Restart from this stage**, **Skip optional stage**, **Cancel**,
  and **Export QC report** controls.

The existing individual menu entries should remain available for research and
troubleshooting. They would be backed by the same operation IDs as the ordered
run, so the one-stage and full-pipeline paths cannot diverge.

### Migration sequence

1. **Freeze native behavior.** Expand golden fixtures for each current MAAC
   engine, including diagnostics and reviewed overrides, at 64/128/256 channels.
2. **Define DTOs.** Add candidate, map, latent-component, decision, checkpoint,
   and stage-correction schemas to protocol v1 before extraction.
3. **Build a Government-authored MAAC runner.** Initially compile the same
   numerical sources into a separate command target or source repository. Do
   not delete the native path yet.
4. **Parity mode.** On fixtures, run native and external engines from identical
   inputs and compare candidates, selected factors/components, maps, corrected
   samples, and diagnostics within explicit tolerances.
5. **Move one low-coupling stage first.** Movement PCA/Promax is the best first
   extraction because it already has rectangular inputs, bounded independent
   ranges, deterministic settings, rich progress, and a corrected-signal
   result. Muscle BSS-CCA is next.
6. **Move coupled ocular stages.** Extract SP and CRD only after candidate/map
   review DTOs are proven. Keep the canonical template asset out of EVA if
   counsel recommends that distribution boundary.
7. **Add checkpoint orchestration.** Build the full ordered sheet around native
   CleanLine, external MAAC-specific stages, native ICA/classification, and
   native health.
8. **Deprecate, then remove duplicate compute.** Keep native fallback only for a
   declared transition release. Never choose native versus external silently;
   the provenance must identify the engine.

### Effort estimate

These are engineering ranges for one engineer familiar with EVA, not calendar
commitments. Legal review, scientific review, and MATLAB/runtime procurement are
outside the ranges.

| Work | After generic plug-in host exists | Including Phases 1–3 of generic host |
| --- | ---: | ---: |
| Extract movement PCA as the first parity-tested stage | 2–4 engineer-weeks | 8–14 engineer-weeks |
| Scope A: all MAAC-specific engines, current individual review flows | 8–13 engineer-weeks | 14–23 engineer-weeks |
| Scope A plus full ordered/checkpointed MAAC-7 UI and QC report | 12–18 engineer-weeks | 18–28 engineer-weeks |
| Scope C: entire procedure, duplicating filter/ICA/health behavior externally | 20–32+ engineer-weeks | 26–42+ engineer-weeks |

The Scope A plus MAAC-7 range roughly allocates:

- 2–3 weeks for protocol types, checkpoint/invalidation behavior, and host DTOs;
- 3–5 weeks to extract and parity-test the four correction families and
  preliminary detector;
- 2–3 weeks to adapt current review sheets and sidecars;
- 2–3 weeks for ordered orchestration, resume, batch, and progress;
- 2–4 weeks for 64/128/256-channel campaigns, adversarial tests, QC export,
  documentation, and release hardening.

Some work overlaps, but scientific parity and replay tests should not be
compressed to meet the optimistic end of the estimate.

### Recommendation on MAAC

Do not move MAAC solely because MARA is GPL; the two license questions are
independent. First build the generic host for MARA with the non-destructive
component-score result. If the host proves stable and optional installation is
still desirable, extract movement PCA as the MAAC protocol pilot. Then decide
whether the operational benefits justify moving the remaining engines.

If the goal is a one-click MAAC experience soon, complete native MAAC-7 first.
It is substantially less work and supplies the exact orchestration, checkpoint,
QC, and golden-behavior specification needed for a later safe extraction. If
the goal is to shrink EVA and make specialized methods independently
installable, use Scope A and retain native CleanLine, ICA/classification, and
health as host stages.

## Security and privacy model

An external plug-in is executable code with the user's privileges. A manifest
is a claim, not a sandbox. EVA should therefore:

- never auto-run a downloaded plug-in;
- require explicit registration and first-run approval;
- show code-signing, notarization, hash, and modification status;
- pass only a per-job directory and a reduced environment;
- use random non-guessable job paths and restrictive filesystem permissions;
- reject symlinks, hard-link tricks, device files, absolute output paths, and
  `..` traversal;
- set output, log, process-count, duration, and memory expectations where macOS
  APIs permit;
- capture stdout/stderr without allowing unbounded memory growth;
- deny network use by policy unless a future remote capability explicitly asks
  for it and the user approves;
- scrub subject names and original source paths from the job bundle by default;
- make retained logs visible and deletable; and
- document that local executable isolation is fault containment, not a complete
  security sandbox.

For stronger isolation later, run adapters in a dedicated sandbox profile,
container, or signed broker service. That is a phase-two security project; do
not claim it in v1 until tested on the supported macOS release.

## Testing strategy

### Protocol and host tests

- manifest/schema forward and backward compatibility;
- static/live identity mismatch;
- normal progress, malformed progress, progress flood, and non-monotonic values;
- cancellation during launch, compute, and result writing;
- timeout, crash, signal termination, and nonzero exit;
- missing, truncated, oversized, wrong-endian, and wrong-hash files;
- NaN/Inf samples and scores;
- wrong dimensions, sample rate, units, or channel order;
- path traversal, symlink escape, unexpected file types, and log flooding;
- executable modified after registration;
- recording closed or changed while a job is running;
- plug-in unavailable during replay or batch;
- deterministic cache hit and invalidation; and
- cleanup after success, failure, cancellation, and EVA relaunch.

### Scientific tests

- adapter output against a direct upstream run on identical inputs;
- sensitivity to channel coordinate conventions and unit scaling;
- invariance/expected sensitivity to ICA sign, order, rank, and algorithm;
- preservation metrics against clean simulated truth;
- agreement and disagreement matrices between MARA, ICLabel, expert/simulated
  labels, W-ICA policies, and component rejection;
- 64-, 128-, and 256-channel recordings at representative durations;
- repeated runs for determinism; and
- version-to-version regression reports.

### Release tests

- fresh macOS account with no developer tools;
- Developer ID/notarized EVA with separately signed, ad-hoc-signed, unsigned,
  modified, and quarantined adapters;
- MATLAB/runtime missing, moved, updated, or unlicensed;
- offline execution;
- batch restart after failure; and
- export/reopen/replay with complete provenance.

## Phased implementation plan

### Phase 0 — decisions and review

- Approve the out-of-process/file-protocol direction.
- Decide direct-notarized distribution versus Mac App Store requirements.
- Obtain preliminary NIH legal/security review of the proposed boundary.
- Decide whether NIH will only document adapters or also maintain/distribute
  them in separate repositories.
- Define raw-data retention and diagnostic-log policy.

Exit criterion: written decision record covering distribution, ownership,
security assumptions, and who approves a new plug-in.

### Phase 1 — protocol RFC and conformance fixture

- Write JSON Schemas for manifest, request, progress, result, signal metadata,
  montage, events, ICA, and provenance.
- Specify byte order, array order, units, coordinate system, numeric bounds,
  error codes, cancellation, and version negotiation.
- Build `EVAPluginFixture`, a tiny Government-authored executable that copies a
  signal or returns deterministic component scores.
- Publish example job bundles and expected hashes.

Exit criterion: the fixture can be invoked manually without EVA, and a second
small implementation can consume/produce the same files from the specification.

### Phase 2 — host, registry, and safety

- Implement strict Codable models in `EVACore/Plugins`.
- Implement registration, bookmarks, runtime self-test, process runner,
  progress, cancellation, timeout, logging, and cleanup in `EVA/Plugins`.
- Implement result validation and adversarial tests before any scientific
  plug-in is used.
- Add Settings > Plug-ins with no network catalog.

Exit criterion: the conformance fixture passes normal and malicious-result
tests in interactive and automated runs without changing recording data on any
failure.

### Phase 3 — pipeline, history, replay, and batch

- Add `externalPlugin` to `EVAProcessingStep.Operation`.
- Add sidecar persistence, payload identity hashing, snapshots, invalidation,
  history/audit summaries, replay classification, export, and batch handling.
- Add a generic run sheet and result review.

Exit criterion: apply/undo/redo, export/reopen, Copy Processing, and headless or
windowed batch behave consistently for the fixture plug-in.

### Phase 4 — MARA research adapter

- Create a separate adapter repository and license inventory.
- Implement `eva-ica-v1` to EEGLAB/MARA translation and component-score output.
- Add MARA columns/details to ICA review, with advisory behavior by default.
- Validate against direct MARA and the 64/128/256-channel evaluation corpus.

Exit criterion: parity report, reproducible environment, legal approval for the
chosen installation/distribution model, and no unexplained component mapping or
score discrepancies.

### Phase 5 — external FMRIB FASTR reference adapter

- Create a separate pinned adapter/environment.
- Implement trigger/config translation and corrected-signal result.
- Integrate it only in fixture/test builds at first.
- Extend the existing FASTR campaign to compare native clean-room EVA and
  external upstream outputs.

Exit criterion: reference comparison report across the required channel counts
and edge cases, with the external method never confused with native EVA FASTR.

### Phase 6 — controlled ecosystem

- Add signed catalog metadata, checksums, revocation, and compatibility ranges;
  retain manual approval and separate installation.
- Define a plug-in review checklist and support policy.
- Consider a local container or remote/HPC runner using the same job protocol.
- Add further result types only when a concrete plug-in needs them.

Exit criterion: a new plug-in can be reviewed, tested, registered, run, replayed,
and removed without changes to the host beyond a deliberately versioned
protocol extension.

## Acceptance checklist for every plug-in

### License and provenance

- [ ] Exact upstream release/commit pinned.
- [ ] SPDX expression verified against every relevant file and asset.
- [ ] Dependency and runtime licenses inventoried.
- [ ] Source availability plan recorded for any distributed GPL binary.
- [ ] NIH legal/software-release approval recorded.
- [ ] Citations and notices shown in EVA and exports.

### Security and operations

- [ ] Executable identity and update behavior defined.
- [ ] Data exposure documented in plain language.
- [ ] Network behavior declared and tested.
- [ ] Cancellation, timeout, crash, cleanup, and disk exhaustion tested.
- [ ] Malformed/adversarial outputs cannot mutate a recording.

### Scientific behavior

- [ ] Inputs, units, coordinate systems, and transformations documented.
- [ ] Direct-upstream parity established where applicable.
- [ ] 64/128/256-channel fixtures covered.
- [ ] Determinism and seed behavior measured.
- [ ] Review/default policy justified by evaluation, not convenience.
- [ ] Versioned regression report retained.

### EVA integration

- [ ] Interactive run and review complete.
- [ ] History, undo/redo, invalidation, and snapshots complete.
- [ ] `eva.xml`, sidecar, audit log, and export complete.
- [ ] Reopen and replay dependency failures are explicit.
- [ ] Headless/windowed batch behavior complete.
- [ ] User can disable and forget the plug-in without deleting external files.

## Recommended first milestone

Build Phases 1–3 with only `EVAPluginFixture`; do not start by wiring MATLAB
straight into the Artifacts menu. Once the boundary has survived hostile-output,
replay, and batch tests, implement MARA first because its `componentScores`
result is non-destructive and fits EVA's existing ICA review. Use external
FMRIB FASTR second as a fixture-only/reference runner, while retaining EVA's
native clean-room, Metal-capable FASTR-family implementation as the production
method.

That sequence tests the architectural and licensing premise with the smallest
scientific risk, then exercises full corrected-signal interchange only after
the host has proven it can validate and transact external results safely.

## References

- [GNU GPL FAQ: separate programs, plug-ins, and communication](https://www.gnu.org/licenses/gpl-faq.html#GPLPlugins)
- [GNU GPLv3: aggregation and corresponding source](https://www.gnu.org/licenses/gpl-3.0.html)
- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple: Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [MARA repository and requirements](https://github.com/irenne/MARA)
- [EEGLAB extension model](https://eeglab.org/tutorials/contribute/design_plugin.html)
- [FMRIB EEGLAB/FASTR repository](https://github.com/sccn/fMRIb)
- EVA `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `docs/provenance/README.md`
- EVA `docs/provenance/fastr-functional-spec.md` and
  `docs/provenance/fastr-audit-log.md`
