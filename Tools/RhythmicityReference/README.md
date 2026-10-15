# Python reference-fixture tools

These scripts run the external LAVI Python repository as a numerical oracle and
generate EVA's independent WTPL paper-equation oracle. They do not vendor,
patch, or translate upstream code.

From the EVA repository root:

```bash
python3 -m venv /private/tmp/eva-lavi-reference-venv
/private/tmp/eva-lavi-reference-venv/bin/python -m pip install numpy scipy matplotlib pytest
git clone https://github.com/laaanchic/LAVI.git /private/tmp/eva-lavi-reference
git -C /private/tmp/eva-lavi-reference checkout 78386879eeb8cf9be06a1edfa6917c91b2d0d2ba

PYTHONPATH=/private/tmp/eva-lavi-reference/python \
  /private/tmp/eva-lavi-reference-venv/bin/python -m pytest -q \
  /private/tmp/eva-lavi-reference/python/tests

python3 Tools/RhythmicityReference/generate_input.py \
  --output EVATests/Fixtures/Rhythmicity/reference-input.json

PYTHONPATH=/private/tmp/eva-lavi-reference/python MPLBACKEND=Agg \
  /private/tmp/eva-lavi-reference-venv/bin/python \
  Tools/RhythmicityReference/run_python_reference.py \
  --lavi-checkout /private/tmp/eva-lavi-reference \
  --expected-commit 78386879eeb8cf9be06a1edfa6917c91b2d0d2ba \
  --input EVATests/Fixtures/Rhythmicity/reference-input.json \
  --output EVATests/Fixtures/Rhythmicity/python-reference.json \
  --author-example-report EVATests/Fixtures/Rhythmicity/python-author-example-report.json

python3 Tools/RhythmicityReference/generate_wtpl_oracle.py \
  --output EVATests/Fixtures/Rhythmicity/wtpl-python-oracle.json

python3 Tools/RhythmicityReference/generate_burst_oracle.py
```

The WTPL generator uses only the Python standard library. It directly evaluates
the published within-trial signed-lag equation, including fractional complex
interpolation, and stores its deterministic inputs and expected outputs in the
fixture so Swift can validate complete maps without invoking Python at test
time.

The burst generator also uses only the Python standard library. It starts from
a fixed frequency × time power/WTPL map, independently applies P90 peaks, P75
boundaries, deterministic plateau consolidation and overlap pruning, and writes
the complete inputs and expected detections. The maintained upstream MATLAB
entry point is pinned as behavioral provenance because its called helper
functions are not distributed in the repository.

To refresh the deidentified manifest for a local folder containing large MFF
integration inputs:

```bash
python3 Tools/RhythmicityReference/inspect_mff.py \
  --root /path/to/LAVI_testing \
  --output EVATests/Fixtures/Rhythmicity/mff-integration-manifest.json
```

To run the external MFF loading gate:

```bash
printf '%s\n' /path/to/LAVI_testing > /private/tmp/eva-rhythmicity-mff-root.txt
xcodebuild test -project EVA.xcodeproj -scheme EVA \
  -destination 'platform=macOS' \
  -only-testing:EVATests/RhythmicityMFFIntegrationTests
rm /private/tmp/eva-rhythmicity-mff-root.txt
```

The temporary marker is supported because Xcode's macOS test host may strip
arbitrary shell environment variables. `EVA_RHYTHMICITY_MFF_ROOT` remains the
preferred route in runners that preserve it.

Do not add upstream checkouts, the authors' MAT data, or raw MFF samples to the
repository. Regenerated output must remain small, deterministic JSON.
