# SPEC — "Reporting a problem" tester walkthrough

GOAL:    a non-technical tester watches once and can file a Linear UAT report
         without help; feels "this is easy, I can't get it wrong"
OUTPUT:  HyperFrames, 1920x1080, 30fps, ~84s
LOOK:    ground = warm light studio #ECEAE6 (subtle 2% grain feel via flat
         colour, no texture file); hero = mocked Linear UI in dark browser
         chrome (chrome #26272B, address pill #1A1B1E; app bg #0F1013,
         sidebar #191A1E, borders rgba(255,255,255,0.08), text #F7F8F8,
         muted #8A8F98, ONE accent Linear-purple #5E6AD2 — only on primary
         buttons, active highlights, the cursor-attention elements).
         Stage occupies 1600x900 centred (83% frame width).
         Captions on the light ground: Inter 800, 34px, ink #1A1A1A.
         Cursor: oversized-cursor light variant (white arrow) over dark UI.
MOTION:  enters power3.out 24f; stage settle = rise 40px + scale .97→1 over
         36f; typing = --p var 0→1 steps(chars) ~3 chars/frame at 30fps;
         clicks = oversized-cursor / press-ripple envelopes; no repeat:-1,
         no autoAlpha on .clip
AUDIO:   Kokoro TTS voiceover, 8 lines, warm female (af_heart), ~150wpm;
         SFX: soft click on every press, key ticks during typing, pop on
         toast, single warm chime at the end card. No BGM (no provider on
         box — flagged in delivery note).
SCENES (local time; boundaries set to TTS durations):
  title   0–4.5    "Reporting a problem" word-rise + sub "takes about a minute"
  invite  4.5–13   email card "invited to GrowthstrategyHQ" → cursor clicks
                   Accept → card lifts away, "you're in" chip
  linear  13–60    browser stage + Linear mock: annotate-circle "New issue",
                   click → composer; template dropdown → "UAT report";
                   4 fields type in; screenshot chip; press-ripple Create
                   issue → toast "Report sent"
  reply   60–75    ticket comment w/ video thumb → cursor presses play →
                   reply field types "Yes, that's fixed!" → send chip
  recap   75–84    3 steps: File a report / Watch the video / Say yes;
                   end line "That's the whole job."
BANNED:  glow/neon/gradients as decoration; bullets; logo corners; >8 words
         on any caption; anything not the mocked product UI or the 3-step recap
QA:      snapshot at 3, 10, 17, 24, 33, 47, 55, 66, 71, 80 — each must read
         the beat named above; no clip ends mid-motion; every field fully
         typed before Create-issue press
