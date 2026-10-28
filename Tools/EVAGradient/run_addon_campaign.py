#!/usr/bin/env python3
"""Reproducible P3 + drifting gradient fixture and real-MFF add-on comparison.
Requires numpy, scipy, matplotlib. Run --help for explicit inputs; never edits source.
"""
from pathlib import Path
import argparse, os, sys, json, struct, shutil, subprocess, datetime as dt
import xml.etree.ElementTree as ET

def read_mff(path):
    chunks=[]
    with (Path(path)/'signal1.bin').open('rb') as f:
        while v:=f.read(4):
            if struct.unpack('<I',v)[0]:
                hs,ds,n=struct.unpack('<3I',f.read(12)); h=f.read(hs-16)
                off=list(struct.unpack_from('<%dI'%n,h)); enc=struct.unpack_from('<%dI'%n,h,n*4)
                if not all(e&255==32 for e in enc): raise ValueError('Expected float32 EEG')
            data=f.read(ds); end=off[1:]+[ds]
            chunks.append(np.stack([np.frombuffer(data[off[i]:end[i]],dtype='<f4') for i in range(n)]))
    return np.concatenate(chunks,axis=1)

def replace_signal(source,destination,data):
    shutil.copytree(source,destination)
    # Simulation has no peripheral recording. Remove its binary and descriptor.
    for name in ['signal2.bin','info2.xml']: (destination/name).unlink(missing_ok=True)
    offset=0
    with (source/'signal1.bin').open('rb') as f, (destination/'signal1.bin').open('wb') as out:
        while v:=f.read(4):
            out.write(v)
            if struct.unpack('<I',v)[0]:
                header=f.read(12); out.write(header); hs,ds,n=struct.unpack('<3I',header)
                h=f.read(hs-16); out.write(h); starts=list(struct.unpack_from('<%dI'%n,h))
            block=bytearray(f.read(ds)); ends=starts[1:]+[ds]
            counts=[(b-a)//4 for a,b in zip(starts,ends)]
            assert len(set(counts))==1 and n==data.shape[0]
            for c,(a,b) in enumerate(zip(starts,ends)): block[a:b]=data[c,offset:offset+counts[c]].astype('<f4').tobytes()
            out.write(block); offset+=counts[0]
    assert offset==data.shape[1]

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--input',type=Path,required=True);ap.add_argument('--manifest',type=Path,required=True)
    ap.add_argument('--binary',type=Path,required=True);ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--seed',type=int,default=20261028)
    args=ap.parse_args(); root=args.output.resolve();root.mkdir(parents=True,exist_ok=False)
    os.environ['MPLCONFIGDIR']=str(root/'mpl-cache')
    global np
    import numpy as np
    manifest=json.loads(args.manifest.read_text());fs=manifest['sampleRate'];n=manifest['samples']
    source=args.input.resolve();c=read_mff(source).shape[0];t=np.arange(n)/fs
    base=dt.datetime.fromisoformat(ET.parse(source/'info.xml').getroot().find('{*}recordTime').text)
    onsets=[]
    for path in source.glob('Events*.xml'):
        for event in ET.parse(path).iter():
            if event.tag.split('}')[-1]=='event' and event.find('{*}code').text.lower()=='stim':
                onsets.append((dt.datetime.fromisoformat(event.find('{*}beginTime').text)-base).total_seconds())
    onsets=np.array(sorted(onsets));rng=np.random.default_rng(args.seed)
    erp=np.zeros((c,n),dtype=np.float32);background=np.zeros_like(erp);artifact=np.zeros_like(erp)
    gains=np.linspace(1,2,c);trial_amplitudes=10*(1+.15*rng.standard_normal(len(onsets)))
    latencies=.300+.015*rng.standard_normal(len(onsets))
    for onset,amp,latency in zip(onsets,trial_amplitudes,latencies):
        ix=np.arange(round(onset*fs),min(n,round((onset+.8)*fs))); lag=(ix-round(onset*fs))/fs
        erp[:,ix]+= (gains[:,None]*amp*np.exp(-.5*((lag[None,:]-latency)/.060)**2)).astype(np.float32)
    # Known ongoing EEG; independent phases, broadband noise, slow component.
    for ch in range(c):
        background[ch]=(2*np.sin(2*np.pi*(8+.07*ch)*t+rng.uniform(0,2*np.pi))
          +1.5*np.sin(2*np.pi*1.3*t+rng.uniform(0,2*np.pi))+.5*rng.standard_normal(n)).astype(np.float32)
    volumes=np.rint(np.array(manifest['volumeTriggers'])*fs).astype(int)
    offsets=np.rint(np.array(manifest['offsetsSeconds'])*fs).astype(int);tr=round(np.median(np.diff(volumes)))
    for v,start in enumerate(volumes):
        bounds=np.r_[start+offsets,start+tr]
        for group,(lo,hi) in enumerate(zip(bounds[:-1],bounds[1:])):
            hi=min(hi,n);ix=np.arange(lo,hi);phase=np.arange(hi-lo)/len(ix)
            for ch in range(c):
                shift=.003*np.sin(2*np.pi*t[ix]/91+ch*.05)
                shape=np.sin(2*np.pi*(phase+shift))+.35*np.sin(14*np.pi*(phase+shift)+.08*group)
                drift=1+.08*np.sin(2*np.pi*t[ix]/73+ch*.05)
                artifact[ch,ix]=1200*gains[ch]*drift*shape
    truth=erp+background;synthetic=truth+artifact
    simpath=root/'p3-synthetic.mff';replace_signal(source,simpath,synthetic)
    np.savez_compressed(root/'simulation-truth.npz',erp=erp,clean=truth,trial_amplitudes=trial_amplitudes,latencies=latencies)
    methods=[f'{engine}{suffix}' for engine in ['allen','farm'] for suffix in ['', '-exclude','-iterative','-joint']]
    common=['--events','Stim','--tr-code','TREV','--slices',str(manifest['slices']),'--multiband',str(manifest['multiband']),
       '--group-offsets',','.join(map(str,manifest['offsetsSeconds'])),'--methods',','.join(methods),'--iterations','10','--joint-block-seconds','30']
    commands=[]
    for name,path in [('simulation',simpath),('gilmore',source)]:
        cmd=[str(args.binary.resolve()),'compare',str(path),*common,'--output-dir',str(root/name)]
        commands.append(cmd);(root/'commands.json').write_text(json.dumps(commands,indent=2))
        with (root/f'{name}.log').open('w') as log:
            subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
        print('Completed',name,flush=True)
    metadata={'seed':args.seed,'source':str(source),'manifest':manifest,'methods':methods,
      'simulation':'Known P3: 10–20 native-unit nominal peaks, 300ms latency, 60ms width; trial amplitude SD15%, latency SD15ms. Ongoing EEG + noise, gradient1200–2400 with smooth 8% gain drift, phase drift and modest group shape variation. Same Stim/TR timing as Gilmore; not an independent timing design.',
      'limitations':'First20 channels, full recording. No motion transients or BCG in simulation. One seed. Real ERP truth unknown. No trial rejection or rereferencing.'}
    (root/'campaign.json').write_text(json.dumps(metadata,indent=2))
    plot_campaign(root,source,simpath,truth,erp,onsets,methods,manifest)

def plot_campaign(root,source,simpath,truth,true_erp,onsets,methods,manifest):
    import matplotlib;matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from scipy.signal import butter,sosfiltfilt,welch
    fs=manifest['sampleRate'];start=round(manifest['plotWindowSeconds'][0]*fs);stop=start+30*fs
    lag=np.arange(-round(.2*fs),round(.8*fs)+1);ix=np.rint(onsets*fs).astype(int)[:,None]+lag
    filt=butter(4,[.5,30],fs=fs,btype='bandpass',output='sos');scan=slice(round(manifest['volumeTriggers'][0]*fs),round((manifest['volumeTriggers'][-1]+2.15)*fs))
    def avg(data):
        epochs=sosfiltfilt(filt,data.astype(float),axis=1)[:,ix]
        epochs-=epochs[:,:,:round(.2*fs)].mean(axis=2,keepdims=True)
        return epochs.mean(axis=1)
    truth_avg=avg(truth);p3_avg=avg(true_erp);rows=[]
    colors=['#636363','#0072B2','#009E73','#CC79A7']
    plt.rcParams.update({'font.size':9,'axes.spines.top':False,'axes.spines.right':False})
    for case,rawpath in [('simulation',simpath),('gilmore',source)]:
        waves={};erps={}
        report=json.loads((root/case/'report.json').read_text())
        successful={r['method']:r for r in report['results'] if r['status']=='ok'}
        for method in ['raw',*methods]:
            if method!='raw' and method not in successful:continue
            data=read_mff(rawpath if method=='raw' else root/case/f'{method}.mff')
            waves[method]=data[:,start:stop].astype(float);erps[method]=avg(data)
            f,power=welch(waves[method],fs=fs,nperseg=8192,axis=1)
            bands=np.zeros_like(f,dtype=bool)
            for h in range(1,21): bands|=abs(f-h*21/2.15)<.2
            metric={'case':case,'method':method,'scannerHarmonicPowerMedian':float(np.median(np.sum(power[:,bands],axis=1)*(f[1]-f[0]))),
              'waveformCenteredRMS':float(np.sqrt(np.mean((waves[method]-np.median(waves[method],axis=1,keepdims=True))**2)))}
            if case=='simulation':
                metric['cleanTruthScanRMSE']=float(np.sqrt(np.mean((data[:,scan]-truth[:,scan])**2)))
                metric['filteredERPTruthRMSE']=float(np.sqrt(np.mean((erps[method]-truth_avg)**2)))
                window=(lag/fs>=.25)&(lag/fs<=.4)
                metric['P3WindowMeanRatioToCleanTruth']=float(np.mean(erps[method][:,window])/np.mean(truth_avg[:,window]))
            if method!='raw':
                metric['injectionAmplitudeRatio']=successful[method]['injectedERPAmplitudeRatio']
                metric['details']=successful[method].get('details',{})
            rows.append(metric)
        # All 20 channels: native 30 seconds, min/max envelope preserves spikes.
        for engine in ['allen','farm']:
            names=['raw',engine,engine+'-exclude',engine+'-iterative',engine+'-joint'];names=[k for k in names if k in waves]
            fig,axes=plt.subplots(20,len(names),figsize=(20,27),sharex=True,squeeze=False)
            time=np.arange(start,stop)/fs
            for ch in range(20):
                centered={k:v[ch]-np.median(v[ch]) for k,v in waves.items()}
                limit=max(np.max(np.abs(centered[k])) for k in names[1:])*1.02
                for j,k in enumerate(names):
                    y=centered[k];n=len(y)//20*20;blocks=y[:n].reshape(-1,20);tb=time[:n].reshape(-1,20)
                    order=np.sort(np.stack([blocks.argmin(1),blocks.argmax(1)],axis=1),axis=1);rr=np.arange(len(blocks))[:,None]
                    ax=axes[ch,j];ax.plot(tb[rr,order].ravel(),blocks[rr,order].ravel(),lw=.45,color='#888' if j==0 else colors[j-1])
                    lim=np.max(np.abs(y))*1.02 if j==0 else limit;ax.set_ylim(-max(1,lim),max(1,lim));ax.tick_params(labelsize=6)
                    if ch==0:ax.set_title(k)
                    if j==0:ax.set_ylabel(f'E{ch+1}')
            fig.suptitle(f'{case}: {engine.upper()} + ERP protection | native signal, middle 30s\nMedian centered for display; corrected methods share each channel scale; RAW has its own scale. Native amplitude units.',y=.995)
            fig.tight_layout(rect=[0,0,1,.98]);fig.savefig(root/f'{case}-{engine}-waveforms.png',dpi=120);plt.close(fig)
            fig,axes=plt.subplots(5,4,figsize=(16,14),sharex=True)
            for ch,ax in enumerate(axes.flat):
                for j,k in enumerate(names[1:]):ax.plot(lag/fs*1000,erps[k][ch],label=k,color=colors[j],lw=1)
                if case=='simulation':ax.plot(lag/fs*1000,truth_avg[ch],label='Clean truth',color='black',ls='--',lw=1.5)
                ax.axvline(0,color='#aaa',lw=.5);ax.set_title(f'E{ch+1}');ax.set_xlabel('ms');ax.set_ylabel('Native units')
            axes.flat[0].legend(fontsize=7)
            fig.suptitle(f'{case}: {engine.upper()} Stim ERP | 50 trials | 0.5–30Hz, baseline −200–0ms\nSame filtering for every method and truth; no rejection/rereferencing.',y=.995)
            fig.tight_layout(rect=[0,0,1,.96]);fig.savefig(root/f'{case}-{engine}-erp.png',dpi=140);plt.close(fig)
        np.savez_compressed(root/f'{case}-plot-data.npz',**{f'erp_{k}':v for k,v in erps.items()},truth_erp=truth_avg,p3_only=p3_avg,lag_ms=lag/fs*1000)
    (root/'metrics.json').write_text(json.dumps(rows,indent=2))
    print('Plots and metrics:',root,flush=True)

if __name__=='__main__':main()
