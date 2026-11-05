# Known issues

Problems that are seen and understood but not fixed yet.

## The harmonic stack misses low sines stepping half a semitone

The pitch detection reads the harmonic stack since 2026-11-05 (`PitchMethod.HARMONICS`). On the generated
tones it fails 6 of 4,371 cases where the whole wave fails none: a sine at B0 or E1 that steps 50 to 55¢
shows the wrong note or none within 60 detections, and so does a B0 with a weak fundamental. A B0 sine in
20 dB noise fails more under stress (report only). Why isn't worked out yet. Real bass strings have
harmonics, and all the bass recordings pass.

## A ukulele's attack reads a third or a half of the note with the whole wave

The reason the default moved to the harmonic stack. With the whole wave's period (the NSDF,
`PitchMethod.WAVE`, H in a debug build), a ukulele's E5 first reads A3 and F5 reads B♭3 for 0.1 to 0.2 s,
and B♭4 reads B♭3. Held over `NOTE_SWITCH_S`, the wrong note is confirmed and shown, and the right one, a
harmonic of it, then waits `NOTE_HARMONIC_SWITCH_S` more. The strobe and the scope follow the confirmed note,
so they came 0.3 to 0.4 s after the pluck instead of about 0.15 s.

The cause is the body. Every pluck thumps it: a resonance near 215 Hz and a broad band from 250 to 400 Hz,
as loud as the note or louder for the first 0.15 to 0.2 s, at the same frequency whatever note is played.
The whole wave weighs everything by its power, and the note with the thump repeats about every three of the
note's periods (665 Hz / 3 ≈ 222 Hz) or every two (466 / 2 = 233). When the thump dies away, the note's own
period wins.

- Filtered above 400 Hz, the wrong reads mostly went and E5 showed 0.12 to 0.15 s sooner.
- The harmonic stack read the note on the first or second detection on most plucks, 0.1 to 0.2 s sooner,
  and felt faster live. It was fooled once, an E♭5 read as A♭3 for 0.13 s.
- The harness with the stack, 2026-11-05: recordings 0 of 1,946 runs failed, as with the whole wave, 9 at
  ±49¢ against 38, and the ukulele G3 and G♯3 files no longer read an octave up.
- A fridge's 300 Hz hum (D4 +37¢) is about half of a D5. The whole wave read a fading D5 as D4, G3 and D5 by
  turns, the stack held D5.
