#!/usr/bin/env python3
"""Controlled follow-up to run_addon_campaign. Same truth, separate artifact factors.
Usage: python run_controlled_p3.py PREVIOUS_CAMPAIGN NEW_OUTPUT
Requires numpy/scipy/matplotlib. Uses the saved executable for fair comparisons.
"""
from pathlib import Path
import os,sys,json,subprocess,hashlib,shutil
import numpy as np
import run_addon_campaign as campaign
campaign.np=np
from scipy.signal import butter,sosfiltfilt
previous=Path(sys.argv[1]).resolve();root=Path(sys.argv[2]).resolve();root.mkdir(parents=True,exist_ok=False)
os.environ['MPLCONFIGDIR']=str(root/'mpl-cache');os.environ['XDG_CACHE_HOME']=str(root/'cache')
import matplotlib;matplotlib.use('Agg')
import matplotlib.pyplot as plt
meta=json.loads((previous/'campaign.json').read_text());m=meta['manifest'];fs=m['sampleRate'];n=m['samples'];c=20
source=Path(meta['source']);truthfile=np.load(previous/'simulation-truth.npz');truth=truthfile['clean'];erp=truthfile['erp']
methods=['farm','farm-iterative','farm-joint'];labels=['FARM','FARM + Iterative','FARM + Joint'];colors=['#666666','#009E73','#CC79A7']
basecommand=json.loads((previous/'commands.json').read_text())[0]
options=basecommand[3:basecommand.index('--output-dir')];options[options.index('--methods')+1]=','.join(methods)
shutil.copy2(previous/'eva-gradient-used',root/'eva-gradient-used')
basecommand=[str(root/'eva-gradient-used'),'compare']
# Retain identical epochs and filtering, including ongoing EEG in the reference.
import datetime as dt,xml.etree.ElementTree as ET
base=dt.datetime.fromisoformat(ET.parse(source/'info.xml').getroot().find('{*}recordTime').text)
onsets=[]
for path in source.glob('Events*.xml'):
 for e in ET.parse(path).iter():
  if e.tag.split('}')[-1]=='event' and e.find('{*}code').text.lower()=='stim':
   onsets.append((dt.datetime.fromisoformat(e.find('{*}beginTime').text)-base).total_seconds())
lag=np.arange(-200,801);ix=np.rint(np.array(sorted(onsets))*fs).astype(int)[:,None]+lag
filt=butter(4,[.5,30],fs=fs,btype='bandpass',output='sos')
def average(data):
 epochs=sosfiltfilt(filt,data.astype(float),axis=1)[:,ix]
 epochs-=epochs[:,:,:200].mean(2,keepdims=True)
 return epochs.mean(1)
truth_avg=average(truth)
plt.rcParams.update({'font.size':9,'axes.spines.top':False,'axes.spines.right':False})
def erpfigure(erps,title,path,reference=None):
 fig,axes=plt.subplots(5,4,figsize=(16,14),sharex=True)
 for ch,ax in enumerate(axes.flat):
  for method,label,color in zip(methods,labels,colors):ax.plot(lag,erps[method][ch],label=label,color=color,lw=1.2)
  if reference is not None:ax.plot(lag,reference[ch],color='black',ls='--',lw=1.5,label='Clean truth')
  ax.axvline(0,color='#bbb',lw=.6);ax.set_title(f'E{ch+1}');ax.set_xlabel('Time from Stim (ms)');ax.set_ylabel('Native units')
 axes.flat[0].legend(fontsize=7)
 fig.suptitle(title+'\n50 Stim trials; 0.5–30 Hz; baseline −200–0 ms; no trial rejection or rereferencing',y=.995)
 fig.tight_layout(rect=[0,0,1,.96]);fig.savefig(path,dpi=140);plt.close(fig)

def waveformfigure(directory,path,title):
 start=round(m['plotWindowSeconds'][0]*fs);stop=start+30000;t=np.arange(start,stop)/fs
 waves={method:campaign.read_mff(directory/f'{method}.mff')[:,start:stop].astype(float) for method in methods}
 fig,axes=plt.subplots(20,3,figsize=(17,27),sharex=True)
 for ch in range(c):
  centered={k:v[ch]-np.median(v[ch]) for k,v in waves.items()};lim=max(np.max(abs(v)) for v in centered.values())*1.02
  for j,method in enumerate(methods):
   y=centered[method];a=y.reshape(-1,20);b=t.reshape(-1,20);order=np.sort(np.stack([a.argmin(1),a.argmax(1)],axis=1),axis=1);rows=np.arange(len(a))[:,None]
   ax=axes[ch,j];ax.plot(b[rows,order].ravel(),a[rows,order].ravel(),color=colors[j],lw=.5);ax.set_ylim(-lim,lim)
   if ch==0:ax.set_title(labels[j])
   if j==0:ax.set_ylabel(f'E{ch+1}')
 for ax in axes[-1]:ax.set_xlabel('Recording time (s)')
 fig.suptitle(title+'\n267.5435–297.5435 s; native signal; display median removed; identical scale across methods for each channel',y=.995)
 fig.tight_layout(rect=[0,0,1,.975]);fig.savefig(path,dpi=120);plt.close(fig)

gilmore=np.load(previous/'gilmore-plot-data.npz');real_erps={k:gilmore['erp_'+k] for k in methods}
erpfigure(real_erps,'Gilmore: FARM, FARM + Iterative, FARM + Joint',root/'gilmore-three-erp.png')
waveformfigure(previous/'gilmore',root/'gilmore-three-waveforms.png','Gilmore: first20 channels, middle30 seconds')
print('Gilmore figures ready',flush=True)
profiles={'stationary':(0,0,0),'group-shape-only':(0,0,.08),'amplitude-drift-only':(.08,0,0),'timing-drift-only':(0,.003,0)}
volumes=np.rint(np.array(m['volumeTriggers'])*fs).astype(int);offsets=np.rint(np.array(m['offsetsSeconds'])*fs).astype(int);tr=round(np.median(np.diff(volumes)));gains=np.linspace(1,2,c)
scan=slice(volumes[0],volumes[-1]+tr);metrics=[];commands=[];all_erps={}
for name,(amplitude,shiftamp,groupdiff) in profiles.items():
 artifact=np.zeros_like(truth)
 for start in volumes:
  bounds=np.r_[start+offsets,start+tr]
  for group,(lo,hi) in enumerate(zip(bounds[:-1],bounds[1:])):
   hi=min(hi,n);ixs=np.arange(lo,hi);phase=np.arange(hi-lo)/(hi-lo);time=ixs/fs
   for ch in range(c):
    shift=shiftamp*np.sin(2*np.pi*time/91+ch*.05)
    shape=np.sin(2*np.pi*(phase+shift))+.35*np.sin(14*np.pi*(phase+shift)+groupdiff*group)
    drift=1+amplitude*np.sin(2*np.pi*time/73+ch*.05)
    artifact[ch,ixs]=1200*gains[ch]*drift*shape
 path=root/f'{name}.mff';campaign.replace_signal(source,path,truth+artifact)
 output=root/name;cmd=[*basecommand,str(path),*options,'--output-dir',str(output)];commands.append(cmd)
 (root/'commands.json').write_text(json.dumps(commands,indent=2))
 with (root/f'{name}.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
 report=json.loads((output/'report.json').read_text());success={x['method']:x for x in report['results'] if x['status']=='ok'}
 erps={}
 for method in methods:
  if method not in success:raise RuntimeError(f'{name}/{method} failed; inspect report')
  data=campaign.read_mff(output/f'{method}.mff');erps[method]=average(data)
  metrics.append({'case':name,'method':method,'cleanScanRMSE':float(np.sqrt(np.mean((data[:,scan]-truth[:,scan])**2))),
   'filteredERPTruthRMSE':float(np.sqrt(np.mean((erps[method]-truth_avg)**2))),
   'p3WindowMeanRatio':float(erps[method][:,450:601].mean()/truth_avg[:,450:601].mean()),
   'injectionRetention':success[method]['injectedERPAmplitudeRatio']})
 erpfigure(erps,'P3 simulation: '+name,root/f'{name}-erp.png',truth_avg);all_erps[name]=erps
 if name=='stationary':waveformfigure(output,root/'stationary-waveforms.png','Stationary P3 simulation: first20 channels, middle30 seconds')
 print('Completed',name,metrics[-3:],flush=True)
fig,axes=plt.subplots(2,2,figsize=(12,9),sharex=True,sharey=True)
for ax,(name,erps) in zip(axes.flat,all_erps.items()):
 for method,label,color in zip(methods,labels,colors):ax.plot(lag,erps[method][0],color=color,label=label,lw=1.2)
 ax.plot(lag,truth_avg[0],color='black',ls='--',label='Clean truth');ax.set_title(name);ax.set_xlabel('Time from Stim (ms)');ax.set_ylabel('Native units');ax.axvline(0,color='#bbb',lw=.5)
axes.flat[0].legend(fontsize=8)
fig.suptitle('Controlled P3 recovery: separate artifact factors, unchanged FARM settings\n0.5–30 Hz; baseline −200–0 ms; known clean truth in black',y=.995)
fig.tight_layout(rect=[0,0,1,.94]);fig.savefig(root/'controlled-overview.png',dpi=160);plt.close(fig)
(root/'metrics.json').write_text(json.dumps(metrics,indent=2))
np.savez_compressed(root/'erp-data.npz',truth=truth_avg,**{f'{case}_{k}':v for case,d in all_erps.items() for k,v in d.items()})
(root/'configuration.json').write_text(json.dumps({'priorCampaign':str(previous),'profiles':profiles,'profileParameters':['amplitudeFraction','phaseShiftCycles','groupHarmonicPhaseStepRadians'],'methods':methods,'truthSHA256':hashlib.sha256((previous/'simulation-truth.npz').read_bytes()).hexdigest(),'binarySHA256':hashlib.sha256((root/'eva-gradient-used').read_bytes()).hexdigest(),'note':'Custom fixture, not eva-simulate. Same truth and timing as prior campaign; no retuning of correction or visual filtering. All cases retained.'},indent=2))
shutil.copy2(__file__,root/Path(__file__).name)
print(root,flush=True)
