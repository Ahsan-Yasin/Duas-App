"""Generate android/app/src/main/res/raw/alarm_tone.wav (original, stdlib only).

A gentle two-tone bell chime ("ding-dong", struck twice) that loops cleanly:
22050 Hz, mono, 16-bit PCM, ~3.6 s (< 200 KB). Run: python tools/gen_alarm_tone.py
"""
import math
import os
import struct
import wave

SR = 22050
DURATION = 3.6
PEAK = 0.85
OUT = os.path.join(os.path.dirname(__file__), "..", "android", "app", "src", "main", "res", "raw", "alarm_tone.wav")

# (multiple of the fundamental, relative amplitude, relative decay speed) - a soft bell spectrum.
PARTIALS = [(1.0, 1.0, 1.0), (2.0, 0.42, 1.7), (3.0, 0.2, 2.5), (4.16, 0.1, 3.3), (5.43, 0.05, 4.2)]
# (start s, fundamental Hz, amplitude, decay per second): G5 then C6, repeated a little softer.
STRIKES = [(0.00, 783.99, 1.0, 2.2), (0.55, 1046.50, 0.9, 2.2), (1.70, 783.99, 0.75, 2.4), (2.25, 1046.50, 0.7, 2.4)]
ATTACK = 0.004
FADE_OUT = 0.35


def sample(t: float) -> float:
    s = 0.0
    for start, freq, amp, decay in STRIKES:
        dt = t - start
        if dt < 0:
            continue
        env = min(1.0, dt / ATTACK) * math.exp(-decay * dt)
        if env < 1e-4:
            continue
        for mult, rel, dk in PARTIALS:
            s += amp * rel * env ** dk * math.sin(2 * math.pi * freq * mult * dt)
    return s


def main() -> None:
    n = int(SR * DURATION)
    raw = [sample(i / SR) for i in range(n)]
    fade_n = int(SR * FADE_OUT)
    for i in range(fade_n):  # guarantee a silent loop seam
        raw[n - fade_n + i] *= 0.5 * (1 + math.cos(math.pi * i / fade_n))
    scale = PEAK / max(abs(x) for x in raw)
    frames = b"".join(struct.pack("<h", int(round(x * scale * 32767))) for x in raw)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with wave.open(OUT, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(frames)
    print(f"wrote {os.path.abspath(OUT)} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    main()
