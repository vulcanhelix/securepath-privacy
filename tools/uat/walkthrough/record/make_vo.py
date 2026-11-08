#!/usr/bin/env python3
"""Generate Kokoro VO segments aligned to record.mjs markers, then mix."""
import json, subprocess, sys
import soundfile as sf
from kokoro_onnx import Kokoro

DIR = '/root/securepath-privacy/tools/uat/walkthrough/record/'
MODEL = '/root/.cache/hyperframes/tts/models/kokoro-v1.0.onnx'
VOICES = '/root/.cache/hyperframes/tts/voices/voices-v1.0.bin'

# (start_sec, text) — timed to the markers in markers.json
SEGMENTS = [
    (3.0,  "This is Linear — the app you'll use to report anything that looks off in SecurePath."),
    (14.5, "Click New Issue."),
    (22.0, "Click Apply template, and choose UAT report."),
    (32.0, "The template gives you a ready-made form. Start with a short title that says what's wrong."),
    (42.0, "Then answer the questions in your own words — what happened, what you expected, and which page you were on."),
    (63.0, "If you can, attach a screenshot — a picture really helps."),
    (72.5, "Happy with it? Click Create issue."),
    (84.0, "That's it — your report is filed. The team picks it up from here."),
    (96.0, "When a fix is ready, a comment lands on your ticket with a short video showing it working."),
    (110.5,"Watch the video, take a quick look yourself, then reply on the ticket to say it looks right."),
    (124.0,"Type your reply and send — that's all there is to it. Thanks for testing!"),
]

k = Kokoro(MODEL, VOICES)
inputs, delays = [], []
for i, (t, text) in enumerate(SEGMENTS):
    samples, sr = k.create(text, voice='af_sarah', speed=1.0, lang='en-us')
    fn = f'{DIR}seg{i:02d}.wav'
    sf.write(fn, samples, sr)
    dur = len(samples) / sr
    inputs += ['-i', fn]
    delays += [f'[{i+1}:a]adelay={int(t*1000)}|{int(t*1000)}[a{i}]']
    print(f'seg{i:02d} @{t:5.1f}s  {dur:5.1f}s  "{text[:50]}"')

# mix all delayed segments, then mux with the webm
mix = ';'.join(delays) + ';' + ''.join(f'[a{i}]' for i in range(len(SEGMENTS))) + \
      f'amix=inputs={len(SEGMENTS)}:normalize=0[aout]'
webm = sys.argv[1] if len(sys.argv) > 1 else DIR + 'video/page@24cf818c9aabf7d71eb669b4b0ffae20.webm'
cmd = ['ffmpeg', '-y', '-i', webm, *inputs,
       '-filter_complex', mix,
       '-map', '0:v', '-map', '[aout]',
       '-c:v', 'libx264', '-preset', 'fast', '-crf', '21',
       '-c:a', 'aac', '-b:a', '160k', '-shortest',
       DIR + 'uat-walkthrough.mp4']
subprocess.run(cmd, check=True)
print('DONE -> uat-walkthrough.mp4')
