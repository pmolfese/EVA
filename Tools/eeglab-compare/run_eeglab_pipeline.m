% run_eeglab_pipeline.m
%
% Runs the same full preprocessing-to-average pipeline as
% Tools/mne-compare/make_full_pipeline_reference.py, but with real EEGLAB
% (via MATLAB) instead of MNE-Python, on the same real flanker recording —
% and separately checks EEGLAB's spherical-spline interpolation and
% pop_eegfiltnew's FIR band-pass filter against EVA's own output.
%
% Input: EVATests/Fixtures/Compare/local/eeglab/full.set — the real
% recording, exported from MNE (Tools/eeglab-compare/export_eeglab_set.py)
% because EEGLAB has no MFF-import plugin installed here; the export
% carries over real channel positions and real annotations/events, verified
% by hand before this script was written.
%
% Usage (from the repo root):
%   /Applications/MATLAB_R2026a.app/bin/matlab -batch "run('Tools/eeglab-compare/run_eeglab_pipeline.m')"
%
% Writes EVATests/Fixtures/Compare/local/eeglab/eeglab_full_pipeline_erp.json
% and .../eeglab_filter_and_interp.json.

eeglabRoot = '/Users/molfesepj/Applications/eeglab2026.0.0';
repoRoot = fileparts(fileparts(fileparts(mfilename('fullpath'))));
dataDir = fullfile(repoRoot, 'EVATests', 'Fixtures', 'Compare', 'local', 'eeglab');

addpath(eeglabRoot);
evalc('eeglab nogui;'); % evalc swallows EEGLAB's banner/plugin-update chatter

EEG = pop_loadset('filename', 'full.set', 'filepath', dataDir);
EEG = eeg_checkset(EEG);
chanNames = {EEG.chanlocs.labels};

badNames = {'E82', 'E66'};
badIdx = find(ismember(chanNames, badNames));
assert(numel(badIdx) == numel(badNames));

% ---------------------------------------------------------------- filter-only check
% Same 20 s / 12-channel window Tools/mne-compare/make_real_reference.py
% uses, so this can sit next to the MNE filter comparison directly. Cropped
% from the *unfiltered* full set so both the crop and the filter transient
% context match make_real_reference.py's own crop-then-filter order... but
% pop_eegfiltnew has no notion of "filter first, then crop" vs the reverse
% the way this script's full-pipeline section does; for the filter-only
% check we crop first (matching make_real_reference.py exactly) since that
% script also filters only the already-cropped window, not the full
% recording.
filterCheckChannels = {'E1','E10','E20','E30','E40','E50','E60','E70','E80','E90','E100','E110'};
EEG_filtcheck = pop_select(EEG, 'channel', filterCheckChannels, 'time', [15 35]);
EEG_filtcheck = pop_eegfiltnew(EEG_filtcheck, 1, 40);
filtered_uv = EEG_filtcheck.data; % already µV in EEGLAB's convention

% ---------------------------------------------------------------- interpolation-only check
% EEGLAB's default 'spherical' method uses lambda=0 and only 7 Legendre
% terms (see eeg_interp.m's header) — quite different from EVA's
% SphericalSpline defaults (lambda=1e-5, 40 terms) and MNE's
% (alpha=1e-5, 50 terms). Interpolate on the SAME window/channels as the
% filter check, before filtering, to isolate the interpolation algorithm
% itself from any filter-design difference.
EEG_interpcheck = pop_select(EEG, 'channel', filterCheckChannels, 'time', [15 35]);
targetLabel = 'E50';
targetIdx = find(strcmp({EEG_interpcheck.chanlocs.labels}, targetLabel));
EEG_interpDefault = eeg_interp(EEG_interpcheck, targetIdx, 'spherical');
% Also compute with EVA's own (lambda, terms) so the two are cross-checked
% under identical parameters, isolating "different algorithm" from
% "different default parameters".
EEG_interpEvaParams = eeg_interp(EEG_interpcheck, targetIdx, 'spherical', [1e-5 4 40]);
interpolated_default_uv = EEG_interpDefault.data(targetIdx, :);
interpolated_evaparams_uv = EEG_interpEvaParams.data(targetIdx, :);

interpResult = struct();
interpResult.channels = {EEG_interpcheck.chanlocs.labels};
interpResult.target = targetLabel;
interpResult.samplingRate = EEG_interpcheck.srate;
interpResult.raw_uv = EEG_interpcheck.data;
interpResult.interpolated_default_uv = interpolated_default_uv;
interpResult.interpolated_eva_params_uv = interpolated_evaparams_uv;

filterResult = struct();
filterResult.channels = filterCheckChannels;
filterResult.samplingRate = EEG_filtcheck.srate;
filterResult.filtered_uv = filtered_uv;

fid = fopen(fullfile(dataDir, 'eeglab_filter_and_interp.json'), 'w');
fwrite(fid, jsonencode(struct('filter', filterResult, 'interpolation', interpResult)));
fclose(fid);
fprintf('wrote eeglab_filter_and_interp.json\n');

% ---------------------------------------------------------------- full pipeline
EEG_full = EEG;
EEG_full = pop_eegfiltnew(EEG_full, 1, 40);
EEG_full = eeg_interp(EEG_full, badIdx, 'spherical');
EEG_full = pop_reref(EEG_full, []); % average reference, all channels

preStimulusMs = 200;
postStimulusMs = 800;
congruentCodes = {'LC++', 'RC++'};
incongruentCodes = {'LI++', 'RI++'};

% Baseline window excludes the event sample itself (EVA's convention —
% see MNEReferenceTests / README): [-200, -1] ms at 1000 Hz is exactly the
% pre-stimulus window, one sample short of 0.
baselineMs = [-preStimulusMs, -1];

EEG_congruent = pop_epoch(EEG_full, congruentCodes, [-preStimulusMs postStimulusMs] / 1000, 'epochinfo', 'yes');
EEG_congruent = pop_rmbase(EEG_congruent, baselineMs);
EEG_incongruent = pop_epoch(EEG_full, incongruentCodes, [-preStimulusMs postStimulusMs] / 1000, 'epochinfo', 'yes');
EEG_incongruent = pop_rmbase(EEG_incongruent, baselineMs);

evoked_congruent = mean(EEG_congruent.data, 3);
evoked_incongruent = mean(EEG_incongruent.data, 3);

pipelineResult = struct();
pipelineResult.channelNames = {EEG_full.chanlocs.labels};
pipelineResult.samplingRate = EEG_full.srate;
pipelineResult.nTimesPerEpoch = size(EEG_congruent.data, 2);
pipelineResult.congruentTrialCount = size(EEG_congruent.data, 3);
pipelineResult.incongruentTrialCount = size(EEG_incongruent.data, 3);
pipelineResult.evoked_congruent_uv = evoked_congruent;
pipelineResult.evoked_incongruent_uv = evoked_incongruent;

fid = fopen(fullfile(dataDir, 'eeglab_full_pipeline_erp.json'), 'w');
fwrite(fid, jsonencode(pipelineResult));
fclose(fid);
fprintf('wrote eeglab_full_pipeline_erp.json: congruent=%d incongruent=%d, nTimes=%d\n', ...
    pipelineResult.congruentTrialCount, pipelineResult.incongruentTrialCount, pipelineResult.nTimesPerEpoch);
