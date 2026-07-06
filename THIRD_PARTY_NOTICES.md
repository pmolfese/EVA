# Third-Party Notices

EVA is licensed under the GNU General Public License version 3.0 only. Some
source files include or were implemented with reference to third-party software,
models, or publications. Those files keep local source-header attribution, and
the related notices are collected here.

This file is not a substitute for legal review. Entries marked "no known
license" should be treated as attribution-only until the upstream copyright
holder grants explicit redistribution terms or the EVA code is replaced.

## MNE-Python

- EVA files:
  - `EVA/ICAArtifactDetector.swift`
  - `EVA/SignalImportReader.swift`
- Upstream project: https://github.com/mne-tools/mne-python
- Upstream license: BSD 3-Clause
- Compatibility: BSD 3-Clause is compatible with GPL-3.0-only distribution.

EVA's ICA implementation and native readers for BrainVision, EDF/EDF+, EEGLAB,
Persyst, BESA, and montage helpers were implemented with reference to the
corresponding MNE-Python implementations.

Copyright 2011-2025 MNE-Python authors

Redistribution and use in source and binary forms, with or without modification,
are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.
3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## mffpy

- EVA file: `EVA/MFFWriter.swift`
- Redistributed fixtures: `EVATests/Fixtures/example_1.mff`,
  `EVATests/Fixtures/example_1.mfz`, `EVATests/Fixtures/example_2.mff`,
  `EVATests/Fixtures/example_2.json`, `EVATests/Fixtures/example_3.mff`,
  `EVATests/Fixtures/example_4.mff`, `EVATests/Fixtures/example_5.mff`
- Upstream project: https://github.com/BEL-Public/mffpy
- Upstream license: Apache License 2.0
- Compatibility: Apache-2.0 is compatible with GPL-3.0-only distribution.

EVA's MFF signal block and epoch XML writer structure follows the public mffpy
writer implementation, especially `mffpy/bin_writer.py`,
`mffpy/header_block/header_block.py`, and `mffpy/epoch.py`.

The example recordings under `Fixtures/` are redistributed unmodified from the
mffpy `examples/` directory and are used by EVA solely as read-only test
fixtures. A copy of the Apache License 2.0, together with the upstream copyright
notice, is included at `EVATests/Fixtures/LICENSE-mffpy.txt`.

Copyright 2019 Brain Electrophysiology Laboratory Company LLC

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this module or the code within it except in compliance with the License.

You may obtain a copy of the License at:

https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software distributed
under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.

## ICLabel

- EVA files:
  - `EVA/ICLabelClassifier.swift`
  - `EVA/Models/ICLabel.mlpackage/`
  - `Tools/convert_iclabel_to_coreml.py`
- Upstream project: https://github.com/sccn/ICLabel
- Upstream authorship: SCCN; Luca Pion-Tonachini, Ken Kreutz-Delgado, and Scott
  Makeig
- Upstream license: no repository-level license was found
- Compatibility: not confirmed. Treat as attribution-only until explicit
  GPL-compatible redistribution terms are obtained.

EVA bundles a Core ML conversion of the official ICLabel default MatConvNet
network and implements the corresponding feature preparation path.

Suggested citation:

Pion-Tonachini, L., Kreutz-Delgado, K., and Makeig, S. ICLabel: An automated
electroencephalographic independent component classifier, dataset, and website.
NeuroImage, 198, 181-197 (2019).

## nimh-sfim/gradient_remover

- EVA file: `EVA/GradientRemover.swift`
- Upstream project: https://github.com/nimh-sfim/gradient_remover
- Upstream source: `src/gradient_remover/GradientRemover.py`
- Upstream author: Joshua Teves
- Upstream license: no repository-level license or source-file license was found
- Compatibility: not confirmed. Treat as attribution-only until explicit
  GPL-compatible redistribution terms are obtained or this code is replaced.

EVA's MR gradient artifact removal implementation is a Swift translation of the
upstream template-based gradient remover, with a documented correction to the
neighboring-TR "after" window.

## CWL-Webinar / CWRegrTool (carbon-wire-loop regression)

- EVA file: `EVA/Cardiac/CWLCorrector.swift`
- Reference project: https://github.com/brain-products/CWL-Webinar
  (`CWRegrTool/`)
- Reference literature: Masterton, R. A. J., Abbott, D. F., Fleming, S. W., &
  Jackson, G. D. (2007). Measurement and reduction of motion and
  ballistocardiogram artefacts from simultaneous EEG and fMRI recordings.
  NeuroImage, 37(1), 202-211.
- Upstream license (`CWRegrTool/LICENSE.txt`): MIT
- Compatibility: MIT is compatible with GPL-3.0-only distribution.

No code was copied from CWRegrTool (a MATLAB/EEGLAB plugin); EVA's CWL
correction is an original Swift implementation of the adaptive regression
concept — a sliding-window, multi-lag linear regression of each EEG channel
against the selected CWL reference channels, cross-faded (overlap-add) across
windows to let the coupling drift over the recording. The rest of the
CWL-Webinar repository (slides, talk recording, sample data) carries no
license and is not redistributed with EVA.

## Advanced MRI (AMRI), NINDS, NIH MATLAB toolbox — MAS/MAR/wAAS/wAAR

- EVA files:
  - `EVA/Gradient/GradientRemover.swift` (MAS/MAR gradient-artifact template
    reducer/fit options)
  - `EVA/Artifacts/ArtifactCleaner.swift` (MAS/MAR/wAAS/wAAR local-template
    artifact cleaning methods)
- Reference project: https://amri.ninds.nih.gov/software.html
  (`amri_eeg_gac.m`, `amri_eeg_cbc.m`)
- Reference literature: Liu Z, de Zwart JA, van Gelderen P, Kuo L-W, Duyn JH.
  Statistical feature extraction for artifact removal from concurrent
  fMRI-EEG recordings. NeuroImage (2012), 59(3): 2073-2087.
- wAAS/wAAR weighting additionally cites: Goldman RI, Stern JM, Engel J Jr,
  Cohen MS. Acquiring simultaneous EEG and functional MRI. Clinical
  Neurophysiology (2000), 111(11): 1974-1980.
- Upstream license (`amri_eeg_gac.m`, `amri_eeg_cbc.m` file headers): GNU
  General Public License v3.
- Compatibility: same license as EVA (GPL-3.0-only).

No code was copied from the AMRI toolbox (MATLAB/EEGLAB functions); EVA's
MAS/MAR (gradient and BCG) and wAAS/wAAR (BCG) are original Swift
implementations of the same concepts — a median- or exponentially-weighted
local template built from a moving window of neighboring TRs/events, optionally
scaled by a least-squares fit (`k = dot(y, template) / dot(y, y)`, matching the
AMRI toolbox's fit direction) before subtracting.

## Perrin et al. Spherical Spline Method

- EVA file: `EVA/SphericalSpline.swift`
- Reference: Perrin et al., "Spherical splines for scalp potential and current
  density mapping", Electroencephalography and Clinical Neurophysiology, 1989
- License: literature citation only; no software license applies unless code is
  copied from a separate implementation.

EVA implements the published spherical-spline interpolation method directly.
