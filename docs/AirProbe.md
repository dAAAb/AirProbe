# AirProbe — an AirPod as an IMU inside an object

`AirProbe.app` treats one AirPod as a motion sensor mounted inside an object (demo: the
活萃力 effervescent-tablet tube, 14.25 cm × Ø3.3 cm). It shows the tube in 3D, classifies its
state (upright / tilted / lying / moving / free fall) and auto-scores pick-and-place trials.

```
./scripts/build-probe.sh && open dist/AirProbe.app
python3 scripts/probe_receiver.py        # optional: UDP JSON → Python / LeRobot
```

## Test procedure

1. Connect AirPods to this Mac as the sound output. Allow **Motion & Fitness** when prompted.
2. **Experiment 0: does it keep streaming out of the ear?** With one bud in the ear, check
   that 資料流 shows ~25 Hz. Take it out and lay it on the table. If 中斷次數 goes up and the
   badge reads 資料中斷, turn off System Settings → Bluetooth → AirPods ⓘ →
   **Automatic Ear Detection** (自動耳朵偵測) and try again.
3. Put one bud inside the tube (leave the other one in the case), stand the tube upright, keep
   it still, and press **歸零**.
4. Pick it up → move it → put it down. After 0.6 s of stillness a trial is scored.
5. **錄製 CSV** writes `~/Documents/AirProbe/session-*.csv` (raw samples) and `*-trials.jsonl`.

## Sound sensor (opt-in)

聲音感測 → pick an input (the AirPod in the tube, or the Mac's mic to compare) → 啟用收音.
- Level (dBFS) is computed every ~16 ms, with an adaptive noise floor. A sound event (onset) is
  a frame more than 15 dB above the floor that is rising fast.
- Audio timestamps use the same host clock as the motion samples. Tapping the tube pairs IMU
  impacts with sound onsets and shows the median audio-vs-IMU offset.
- Trials get `placeSoundDB` (loudest sound around the placement) and `carrySoundEvents`.
  These are informational and do not affect the score.
- While recording, a mono WAV is saved next to the CSV. UDP adds `audio` (~20 Hz level) and `sound` (onset) messages.
- Caveat: an AirPods mic switches Bluetooth to the hands-free (HFP) profile. Watch 中斷次數 to
  see whether the motion stream survives that. AirPods also apply their own voice processing.
- Self-checks: `AirProbe --list-inputs`, `AirProbe --audio-selftest`.

## Voice reactions & recorder

- 語音反應: when a pose holds for 0.6 s, the tube speaks through the system output (the
  AirPod itself, if the AirPods are the output). The voice is zh-TW Meijia.
  ≤20° 「我站起來了！」, ≥150° 「我顛倒了！」, 60–120° 「唉呀！我跌倒了！」,
  sustained spin (gyro > 2.5 rad/s for 0.5 s) 「哇！好暈！」. The pose it starts in stays silent.
  Sound-onset detection is muted while speaking or playing back.
- 增強音量 (on by default): speech is rendered to PCM (`AVSpeechSynthesizer.write`), then run
  through a 180 Hz high-pass, a +5 dB presence boost at 3 kHz, a 4:1 compressor with 4 ms
  lookahead and makeup gain (強度, default 20 dB), a soft clipper and a peak normalize to −0.3 dBFS.
  It plays through `AVAudioEngine` (`LoudSpeech.swift`). Measured average loudness gain: about +7 dB
  at 20 dB and +9–10 dB at 24 dB, with peaks unchanged at full scale.
  Check: `AirProbe --loud-selftest <dir> [--drive 20]` writes raw/loud WAVs and prints the stats.
- 錄音: a standalone WAV recorder (it turns the mic on if needed) that saves to
  `~/Documents/AirProbe/recordings/`, with play, reveal and trash buttons.
- Self-checks: `AirProbe --voice-selftest`, `AirProbe --mic-test <sec> <out.txt>` (also writes `<out>.wav`).

## How it works

- Tilt = angle between measured gravity and the gravity captured at zero, so it has no yaw and no drift.
- The 3D orientation uses Apple's fused attitude. The quaternion convention is checked against
  gravity at runtime, and the bud's mounting offset inside the tube is removed by the zero step.
- Score: 100, minus penalties for max carry tilt above 15°, place impact above 0.3 g, free fall,
  and gyro RMS above 1.5 rad/s. If the tube does not end upright it fails, capped at 30.
  The constants live in `ProbeConfig` / `ProbeAnalyzer.finishTrial` (`Sources/AirPoiseCore/Probe.swift`).

## Limits

~25–50 Hz fused data (50 Hz observed on AirPods Pro, macOS 27), one bud at a time, no raw accelerometer, Bluetooth is weakened inside
metal, and lithium battery limits apply (no heat). Use it to judge the outcome, not to close
a control loop.
