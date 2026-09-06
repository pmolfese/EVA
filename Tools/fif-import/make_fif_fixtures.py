#!/usr/bin/env python
"""Fixtures and reference values for EVA's native FIF reader.

    /Users/molfesepj/micromamba/envs/mne/bin/python Tools/fif-import/make_fif_fixtures.py

EVA reads continuous, epoched and averaged FIF natively (no MNE at run time), so
the Swift reader has to agree with MNE *exactly* — same samples, same scaling,
same events. This writes small recordings covering the shapes and encodings that
differ in the reader, and dumps MNE's own answer next to each one:

    sample_raw.fif        float32 buffers, EEG + EOG + STIM, annotations, montage
    sample_short_raw.fif  the same data written as int16 (`fmt='short'`), which
                          exercises the short/DAU-pack16 buffer path and the
                          range × cal scaling that makes it come out right
    sample_gz_raw.fif.gz  the same data gzipped
    sample-epo.fif        6 epochs, 2 named conditions
    sample-ave.fif        2 condition averages with different `nave`
    fif_reference.json    channel info, events, annotations, segment metadata
    *.f32                 the exact sample values MNE returns, in volts

The `.f32` sidecars are raw little-endian float32, channels-major, so the Swift
test can compare every sample rather than a summary statistic.
"""
import json, os
import numpy as np
import mne

OUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                   "EVATests", "Fixtures", "FIF"))
SFREQ = 200.0
N_EEG = 12
DURATION = 20.0


def build_raw():
    """A deterministic recording: EEG + EOG + a stim channel with real events."""
    rng = np.random.default_rng(20260906)
    n = int(SFREQ * DURATION)
    names = ["Fp1", "Fp2", "F3", "Fz", "F4", "C3", "Cz", "C4", "P3", "Pz", "P4", "Oz"]
    assert len(names) == N_EEG
    types = ["eeg"] * N_EEG + ["eog", "stim"]
    info = mne.create_info(names + ["EOG061", "STI 014"], SFREQ, types)
    info.set_montage(mne.channels.make_standard_montage("standard_1020"),
                     on_missing="ignore", match_case=False)

    # Structured signal, not noise: a per-channel sinusoid plus drift, so a
    # transposed or mis-scaled read is obvious rather than plausible.
    t = np.arange(n) / SFREQ
    eeg = np.stack([
        (20e-6 * (i + 1) / N_EEG) * np.sin(2 * np.pi * (5 + i) * t)
        + 3e-6 * rng.standard_normal(n)
        for i in range(N_EEG)
    ])
    eog = 80e-6 * np.sin(2 * np.pi * 0.4 * t)
    stim = np.zeros(n)
    event_samples = [400, 1200, 2000, 2800, 3200, 3600]
    codes = [1, 2, 1, 2, 1, 2]
    for s, c in zip(event_samples, codes):
        stim[s:s + 5] = c                      # 25 ms pulses, so edges are real
    raw = mne.io.RawArray(np.vstack([eeg, eog[None], stim[None]]), info, verbose="ERROR")
    raw.set_annotations(mne.Annotations(onset=[2.0, 11.5], duration=[0.5, 0.0],
                                        description=["bad_blink", "note"]))
    return raw, np.array([[s, 0, c] for s, c in zip(event_samples, codes)])


def dump_array(path, array):
    np.asarray(array, dtype="<f4").tofile(path)


def channel_reference(info):
    out = []
    for ch in info["chs"]:
        out.append({
            "name": ch["ch_name"],
            "kind": int(ch["kind"]),
            "range": float(ch["range"]),
            "cal": float(ch["cal"]),
            "unit": int(ch["unit"]),
            "unit_mul": int(ch["unit_mul"]),
            # Non-spatial channels (STIM, and MNE's own placeholder rows) carry
            # NaN here, which is not JSON; report them as null.
            "loc3": [float(v) if np.isfinite(v) else None for v in ch["loc"][:3]],
        })
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    raw, events = build_raw()
    reference = {
        "generator": "Tools/fif-import/make_fif_fixtures.py",
        "mne_version": mne.__version__,
        "note": "sample data in the .f32 sidecars is channels-major float32, in VOLTS (MNE's own units)",
        "files": {},
    }

    # --- continuous, three encodings ---------------------------------------
    for name, kwargs in [("sample_raw.fif", dict(fmt="single")),
                         ("sample_short_raw.fif", dict(fmt="short")),
                         ("sample_gz_raw.fif.gz", dict(fmt="single"))]:
        path = os.path.join(OUT, name)
        raw.save(path, overwrite=True, verbose="ERROR", **kwargs)
        back = mne.io.read_raw_fif(path, preload=True, verbose="ERROR")
        data = back.get_data()
        stem = name.replace(".fif.gz", "").replace(".fif", "")
        dump_array(os.path.join(OUT, f"{stem}.f32"), data)
        reference["files"][name] = {
            "content": "continuous",
            "samples_file": f"{stem}.f32",
            "n_channels": int(data.shape[0]),
            "n_samples": int(data.shape[1]),
            "sfreq": float(back.info["sfreq"]),
            "first_samp": int(back.first_samp),
            "highpass": float(back.info["highpass"]),
            "lowpass": float(back.info["lowpass"]),
            "channels": channel_reference(back.info),
            "annotations": [
                {"onset": float(a["onset"]), "duration": float(a["duration"]),
                 "description": str(a["description"])}
                for a in back.annotations
            ],
            "stim_events": [[int(v) for v in row] for row in
                            mne.find_events(back, stim_channel="STI 014", verbose="ERROR")],
        }
        print(f"  {name}: {data.shape}, |x|max = {np.abs(data).max():.3e} V")

    # --- epoched ------------------------------------------------------------
    epochs = mne.Epochs(raw, events, {"target": 1, "standard": 2}, tmin=-0.2, tmax=0.5,
                        baseline=None, preload=True, verbose="ERROR")
    epo_path = os.path.join(OUT, "sample-epo.fif")
    epochs.save(epo_path, overwrite=True, verbose="ERROR")
    back = mne.read_epochs(epo_path, preload=True, verbose="ERROR")
    dump_array(os.path.join(OUT, "sample-epo.f32"), back.get_data(copy=False))
    inverse = {v: k for k, v in back.event_id.items()}
    reference["files"]["sample-epo.fif"] = {
        "content": "epoched",
        "samples_file": "sample-epo.f32",
        "n_epochs": len(back),
        "n_channels": len(back.ch_names),
        "n_samples": len(back.times),
        "sfreq": float(back.info["sfreq"]),
        "tmin": float(back.times[0]),
        "channels": channel_reference(back.info),
        "event_id": {k: int(v) for k, v in back.event_id.items()},
        "segments": [{"code": int(e[2]), "name": inverse[int(e[2])], "sample": int(e[0])}
                     for e in back.events],
    }
    print(f"  sample-epo.fif: {back.get_data(copy=False).shape}")

    # --- averaged -----------------------------------------------------------
    evokeds = [back["target"].average(), back["standard"].average()]
    evokeds[0].comment, evokeds[1].comment = "target", "standard"
    ave_path = os.path.join(OUT, "sample-ave.fif")
    mne.write_evokeds(ave_path, evokeds, overwrite=True, verbose="ERROR")
    read_back = mne.read_evokeds(ave_path, verbose="ERROR")
    dump_array(os.path.join(OUT, "sample-ave.f32"),
               np.stack([e.data for e in read_back]))
    reference["files"]["sample-ave.fif"] = {
        "content": "averaged",
        "samples_file": "sample-ave.f32",
        "n_conditions": len(read_back),
        "n_channels": len(read_back[0].ch_names),
        "n_samples": len(read_back[0].times),
        "sfreq": float(read_back[0].info["sfreq"]),
        "tmin": float(read_back[0].times[0]),
        "channels": channel_reference(read_back[0].info),
        "segments": [{"name": e.comment, "nave": int(e.nave)} for e in read_back],
    }
    print(f"  sample-ave.fif: {len(read_back)} conditions × {read_back[0].data.shape}")

    # --- documents that are not recordings ----------------------------------
    # Quick Look has to classify a .fif by structure, not by name, so keep a
    # couple of the other things MNE writes into this extension around.
    cov = mne.compute_covariance(back, tmax=0.0, verbose="ERROR")
    cov_path = os.path.join(OUT, "sample-cov.fif")
    cov.save(cov_path, overwrite=True, verbose="ERROR")
    reference.setdefault("other_files", {})["sample-cov.fif"] = {
        "content": "covariance", "n_channels": int(cov.data.shape[0])}
    print(f"  sample-cov.fif: {cov.data.shape}")

    eve_path = os.path.join(OUT, "sample-eve.fif")
    mne.write_events(eve_path, events, overwrite=True, verbose="ERROR")
    reference["other_files"]["sample-eve.fif"] = {"content": "events", "n_events": int(len(events))}
    print(f"  sample-eve.fif: {len(events)} events")

    with open(os.path.join(OUT, "fif_reference.json"), "w") as f:
        json.dump(reference, f, indent=1)
    print("wrote", os.path.join(OUT, "fif_reference.json"))


if __name__ == "__main__":
    main()
