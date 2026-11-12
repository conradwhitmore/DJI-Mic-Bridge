#!/usr/bin/env python3
"""Offline band-power comparison of a mono PCM16 WAV; no audio playback.

Frequency energy alone cannot establish native ADC rate or receiver parity.
Regions must be chosen explicitly; they are approximate, not microphone markers.
"""
import argparse
from array import array
import cmath
import json
import math
from pathlib import Path
import sys
import wave


def fft(values):
    out = [complex(v) for v in values]
    n = len(out)
    j = 0
    for i in range(1, n):
        bit = n >> 1
        while j & bit:
            j ^= bit
            bit >>= 1
        j ^= bit
        if i < j:
            out[i], out[j] = out[j], out[i]
    size = 2
    while size <= n:
        half = size // 2
        weights = [cmath.exp(-2j * math.pi * k / size) for k in range(half)]
        for start in range(0, n, size):
            for k, weight in enumerate(weights):
                a, b = out[start+k], weight*out[start+k+half]
                out[start+k], out[start+k+half] = a+b, a-b
        size *= 2
    return out


def db(value):
    return 10 * math.log10(value) if value > 0 else None


def region(samples, rate, start, end, n=2048):
    values = samples[round(start*rate):round(end*rate)]
    window = [0.5-0.5*math.cos(2*math.pi*k/(n-1)) for k in range(n)]
    norm = n * sum(v*v for v in window)
    power = [0.0] * (n//2+1)
    windows = 0
    for i in range(0, len(values)-n+1, n):
        chunk = values[i:i+n]
        mean = sum(chunk)/n
        spectrum = fft([(v-mean)*w for v, w in zip(chunk, window)])
        for k in range(n//2+1):
            power[k] += abs(spectrum[k])**2 * (1 if k in (0,n//2) else 2) / norm
        windows += 1
    if not windows:
        raise ValueError('region too short')
    power = [p/windows for p in power]
    bands = []
    for lo, hi in [(0,4000),(4000,8000),(8000,12000),(12000,16000),(16000,20000),(20000,24001)]:
        total = sum(p for k,p in enumerate(power) if lo <= k*rate/n < hi)
        bands.append({'hz_low': lo, 'hz_high_exclusive': hi, 'mean_square': total, 'power_dbfs': db(total)})
    return {'start_seconds':start, 'end_seconds':end, 'windows':windows,
            'bands':bands, 'spectrum_mean_square':power}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wav',type=Path,required=True)
    parser.add_argument('--active',type=float,nargs=2,required=True)
    parser.add_argument('--baseline',type=float,nargs=2,required=True)
    args=parser.parse_args()
    with wave.open(str(args.wav),'rb') as wav:
        if wav.getnchannels()!=1 or wav.getsampwidth()!=2:
            parser.error('requires mono PCM16')
        rate=wav.getframerate()
        pcm=array('h',wav.readframes(wav.getnframes()))
    if sys.byteorder!='little': pcm.byteswap()
    length=len(pcm)/rate
    for start,end in (args.active,args.baseline):
        if not 0 <= start < end <= length: parser.error('region outside recording')
    values=[v/32768 for v in pcm]
    active=region(values,rate,*args.active)
    baseline=region(values,rate,*args.baseline)
    comparison=[]
    for a,b in zip(active['bands'],baseline['bands']):
        comparison.append({'hz_low':a['hz_low'],'hz_high_exclusive':a['hz_high_exclusive'],
                           'active_dbfs':a['power_dbfs'],'baseline_dbfs':b['power_dbfs'],
                           'active_over_baseline_db':db(a['mean_square']/b['mean_square']) if b['mean_square'] else None})
    print(json.dumps({'mode':'offline_spectral_comparison','sample_rate':rate,
                      'method':'2048-point radix-2 FFT; Hann window; per-window DC removal; nonoverlapping mean periodogram',
                      'active':active,'baseline':baseline,'comparison':comparison,
                      'limitation':'No calibrated test signal or receiver reference. Energy can include codec noise, artifacts or background; does not by itself establish native ADC rate.'},indent=2))


if __name__=='__main__': main()
