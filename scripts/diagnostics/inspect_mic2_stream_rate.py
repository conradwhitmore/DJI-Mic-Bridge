#!/usr/bin/env python3
"""Offline measured byte/frame rate. Codec rate is not an ADC-rate measurement."""
import argparse
from bisect import bisect_right
from datetime import datetime
import hashlib
import json
from pathlib import Path

from analyze_mic2_spp import envelopes, callback_summary


def slope(times, values):
    if len(times)<2: raise ValueError('too few callbacks')
    mx=sum(times)/len(times);my=sum(values)/len(values)
    divisor=sum((x-mx)**2 for x in times)
    if divisor<=0: raise ValueError('no callback time span')
    return sum((x-mx)*(y-my) for x,y in zip(times,values))/divisor


def analyze(raw, events):
    coverage=callback_summary(events,len(raw))
    parsed=list(envelopes(raw))
    ends=[];frames=[0]
    for offset, block, control in parsed:
        ends.append(offset+3+len(block)+len(control)+1)
        frames.append(frames[-1]+len(block)//125)
    rx=[e for e in events if e.get('kind')=='rx']
    times=[datetime.fromisoformat(e['source_time'].replace('Z','+00:00')).timestamp() for e in rx]
    first=times[0];times=[t-first for t in times]
    byte_counts=[e['offset']+e['count'] for e in rx]
    frame_counts=[frames[bisect_right(ends,n)] for n in byte_counts]
    trim=int(len(rx)*0.05);last=len(rx)-trim
    t=times[trim:last]
    frame_rate=slope(t,frame_counts[trim:last])
    return {'mode':'offline_rate_estimation','raw_sha256':hashlib.sha256(raw).hexdigest(),
            'callback_coverage':coverage,'estimator':'Least-squares cumulative complete frames/received bytes against source wall-clock; outer 5% of callbacks trimmed on each side.',
            'measured_frames_per_second':frame_rate,
            'measured_total_rfcomm_bytes_per_second':slope(t,byte_counts[trim:last]),
            'measured_audio_payload_bytes_per_second':frame_rate*111,
            'measured_audio_payload_bits_per_second':frame_rate*111*8,
            'codec_assumptions':{'payload_bytes_per_frame':111,'frame_duration_us':5000,
                                 'nominal_frames_per_second':200,'encoded_bits_per_second':177600,
                                 'configured_pcm_samples_per_frame':240,'configured_pcm_rate':48000},
            'limitation':'Compressed payload size does not uniquely determine source/ADC sample rate. Configured samples per frame are not independent proof; combine wall-clock cadence, known-tone frequency and acoustic bandwidth.'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw',type=Path,required=True)
    parser.add_argument('--events',type=Path,required=True)
    args=parser.parse_args()
    print(json.dumps(analyze(args.raw.read_bytes(),[json.loads(s) for s in args.events.read_text().splitlines()]),indent=2))


if __name__=='__main__':main()
