# Known issues

Problems that are seen and understood but not fixed yet.

## A soft re-pluck isn't an onset

A string plucked again at twice the level it rang down to, or 0.15 s after a mute, doesn't count as a new pluck,
so the readout's fit carries on across both. A pluck is the track's level jumping `ONSET_RATIO` (1.5) over its
envelope, which follows over `ONSET_ENVELOPE_TIME_S` (0.3 s), and the level comes through the track's window,
0.22 s at A2: the new pluck rises through it while the envelope follows, the ratio peaks near 1.4. Four times the
level, or half a second after a mute, is one. The same before and after the stripes moved to the slots'
level, see `test_onset_on_a_replucked_string`; the slots light the first pluck's onset about 50 ms later.

## A B0 with a weak fundamental stepping half a semitone holds a wrong note

The pitch detection reads the harmonic stack since 2026-11-05 (`PitchMethod.HARMONICS`), its peaks weighed by
how steady their phase is since 2026-11-06 (`HARMONICS_PHASE_STEADY`). On the generated tones it fails 3 of
4,371 cases where the whole wave fails none, a B0 with a weak fundamental stepping 50 or 55¢ with its phase
restarted. Before the steadiness 6 failed, B0 and E1 sines too.

Traced with `-define:SHOW_CASE` in sandbox/accuracy: for about 50 ms after the step the window holds both the old
tone and the new. Low down they share a bin and come apart, up high they don't, and the stack reads a note from
the high harmonics, B♭6. Four of those in a row confirm it. The real pitch, 30.0 Hz, is exactly halfway and
alternates B♭0 and B0, so no note confirms against it and B♭6 stays, six octaves off a strong pitch. Without
the steadiness the same high notes came, broken by one B6, and three weren't enough.

The B♭6 wins because a note under `HARMONICS_BASS_HZ` only comes from the bass window when it scores
`HARMONICS_HIGH_DB` (65). Without that, all three passed: the B0's own stack was in the bass window through the
step, under 65. Dropped for a ukulele's fade that then lit its room's rumble, see IDEAS.md, Pitch detection 6.

Real bass strings have harmonics and don't restart their phase, and all the bass recordings pass. A strong pitch
far from the note shown could take over even while it alternates between two neighbours.

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
