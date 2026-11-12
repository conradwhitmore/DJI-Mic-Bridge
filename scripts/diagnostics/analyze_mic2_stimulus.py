#!/usr/bin/env python3
"""Offline time-aligned analysis of the known speaker test; no device access."""
import argparse
from array import array
import hashlib
import json
import math
from pathlib import Path
from statistics import median
import sys
import wave

from inspect_pcm_bandwidth import region, db


def align(pcm, rate, timeline, wall_offset):
    n = round(rate * 0.05)
    weights = [complex(math.cos(2*math.pi*997*k/rate), -math.sin(2*math.pi*997*k/rate))
               * (0.5-0.5*math.cos(2*math.pi*k/(n-1))) for k in range(n)]
    times, powers = [], []
    for start in range(max(0, round((wall_offset+1)*rate)),
                       min(len(pcm)-n, round((wall_offset+11)*rate)), n):
        times.append((start+n/2)/rate)
        powers.append(abs(sum(v*w for v,w in zip(pcm[start:start+n],weights)))**2)
    refs = [e for e in timeline if e['frequency_hz']==997 and e['start_seconds']<8]
    scores=[]
    mean=sum(powers)/len(powers)
    variance=sum((v-mean)**2 for v in powers)
    if variance <= 0: raise ValueError('No alignment signal')
    for i in range(-200,301):
        offset=wall_offset+i/100
        template=[int(any(e['start_seconds']+offset <= t < e['end_seconds']+offset for e in refs)) for t in times]
        mt=sum(template)/len(template)
        vt=sum((v-mt)**2 for v in template)
        score=sum((a-mean)*(b-mt) for a,b in zip(powers,template))/math.sqrt(variance*vt) if vt else -1
        scores.append((score,offset))
    score,offset=max(scores)
    if score < 0.7: raise ValueError(f'Alignment too weak: correlation {score:.3f}')
    return {'offset_seconds':offset,'reference_envelope_correlation':score,
            'wall_offset_hint_seconds':wall_offset,'time_resolution_seconds':0.05,
            'method':'997 Hz Hann-window tone power, matched to three pulses and first reference tone'}


def tone(spectrum, rate, frequency):
    n=2*(len(spectrum)-1)
    chosen=[k for k in range(1,len(spectrum)) if abs(k*rate/n-frequency)<=24]
    search=[k for k in range(1,len(spectrum)) if abs(k*rate/n-frequency)<=70]
    nearby=[p for k,p in enumerate(spectrum) if 120<=abs(k*rate/n-frequency)<=500]
    power=sum(spectrum[k] for k in chosen)
    noise=median(nearby)*len(chosen)
    peak=max(search,key=lambda k:spectrum[k])
    return {'frequency_hz':frequency,'peak_hz':peak*rate/n,'band_power_dbfs':db(power),
            'power':power,'over_local_noise_db':db(power/noise) if noise else None}


def analyze(pcm, rate, metadata, wall_offset):
    alignment=align(pcm,rate,metadata['timeline'],wall_offset)
    offset=alignment['offset_seconds']
    measurements=[]
    for entry in metadata['timeline']:
        if entry['kind']!='test_tone': continue
        start,end=entry['start_seconds']+offset,entry['end_seconds']+offset
        on=region(pcm,rate,start+0.3,end-0.3,n=8192)['spectrum_mean_square']
        off=region(pcm,rate,end+0.2,end+0.6,n=8192)['spectrum_mean_square']
        f=entry['frequency_hz']
        target=tone(on,rate,f)
        background=tone(off,rate,f)
        alias=tone(on,rate,entry['alias_if_sampled_at_16khz'])
        measurements.append({'frequency_hz':f,'recorded_start_seconds':start,'recorded_end_seconds':end,
                             'target':target,'silent_gap':background,'alias_16k':alias,
                             'target_over_silent_gap_db':db(target['power']/background['power']) if background['power'] else None,
                             'target_over_alias_db':db(target['power']/alias['power']) if alias['power'] else None})
    return {'mode':'offline_known_stimulus_analysis','alignment':alignment,'measurements':measurements,
            'method':'Central 1.0 s of each tone vs following 0.4 s gap; 8192-point Hann periodogram, DC removed; target +/-24 Hz.',
            'limitations':['An uncalibrated built-in speaker cannot establish microphone frequency response.',
                           'A reproduced high tone supports useful bandwidth at that frequency, not a precise ADC sampling rate.',
                           'Check aliases, images and distortion; no HFP or receiver reference in this session.']}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wav',type=Path,required=True)
    parser.add_argument('--stimulus-json',type=Path,required=True)
    parser.add_argument('--wall-offset',type=float,required=True)
    args=parser.parse_args()
    with wave.open(str(args.wav),'rb') as w:
        if w.getnchannels()!=1 or w.getsampwidth()!=2:parser.error('requires mono PCM16')
        rate=w.getframerate();samples=array('h',w.readframes(w.getnframes()))
    if sys.byteorder!='little':samples.byteswap()
    result=analyze([v/32768 for v in samples],rate,json.loads(args.stimulus_json.read_text()),args.wall_offset)
    result['wav_sha256']=hashlib.sha256(args.wav.read_bytes()).hexdigest()
    result['stimulus_json_sha256']=hashlib.sha256(args.stimulus_json.read_bytes()).hexdigest()
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
