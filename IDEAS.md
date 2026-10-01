# Ideas

Features and code changes that aren't planned yet. Nothing here is decided.

## Steady rotation far from a locked note

Behind a flag, in locked mode only. Tuning up a new string with the note locked to low E, the string
starts far below the note and wobbles on the way up. The strobe has nothing steady to show there, and
it's hard to tell how far there is to go.

Far out, show a simulated rotation at a steady rate in the right direction, and blend it into the
real strobe as the string comes within about 50 to 100 cents.

- The band's window is 25 cents a bin, so the lock-in hears the string about 20 dB down at 50 cents
  and not at all past 75. The direction and distance out there have to come from the pitch detection,
  like the arrows next to the note.
- The blend could follow the band's SNR, which rises as the string comes into the window.
- A constant rate reads as "keep going", a rate that follows the distance would jump around with the
  wobble it is meant to hide.
- The handover is the hard part, the simulated stripes and the real ones have to meet without a
  jump in phase or speed. May not be worth it if it can't be made seamless.

## In-tune cues

One setting, all optional.

- Green note name within the tolerance, the strobe itself stays unchanged.
- A short beep once the note holds in the window for about 300 ms. The detection ignores the input
  briefly so the mic doesn't read the beep.
- A haptic tap as a quieter alternative to the beep.

## Audible beating mode

A tone or click through headphones whose rate follows the pitch error and stops when in tune. Also the
path to real VoiceOver support later.

## Piano stretch tuning

## SDL only

Drop raylib, SDL3 GPU becomes the one renderer. It also brings what the desktop is missing: text
input, dropped files, open dialogs and a resizable window.

- The shaders are written twice by hand, Metal for macOS and iOS, Vulkan GLSL compiled to SPIR-V
  with `glslc` for Linux. No generator, the two files keep the same structure and point at each other.
- The raylib GLSL isn't Vulkan GLSL, the uniforms move into blocks on SDL's binding slots and the
  sprite shader is new.
- macOS goes first with raylib kept as the Linux fallback, raylib goes once Linux runs on Vulkan on
  real hardware.

## Pitch detection

The pitch detection only names the note, the strobe's lock-in measures it. NSDF stays, it finds the
period of the whole wave so a missing fundamental reads right, and its normalization holds up with
about 2 periods in the window where YIN wants more. YIN, aubio's yinfft and zero crossings would be
a sideways step, SWIPE′ and the neural ones (CREPE, PESTO) are better at noise than the strobe needs.
What falls short is around it, in this order:

1. Mains hum lights a note. The 60 Hz high-pass takes only about 5 dB off 50 Hz, and a higher
   cutoff wouldn't help, the harmonics alone repeat every 20 ms, the missing fundamental again.
   A steady hum passes clarity 0.98 and `is_tonal` keeps the noise floor from learning it.
   Replayed, 50 Hz with harmonics up to 350 Hz and a little hiss at -45 dBFS RMS:
   - Alone after silence, G1 +35 ¢, strong and lit for good, the floor rises 1 dB a second.
   - Alone from the start, lit for about 10 s until the warmup's tonal limit lets the floor learn it.
   - Under the Strat's A2, the pitch detection reads the decaying note sharp, +2 ¢ to +24 ¢, clarity
     drops from 0.99 to 0.78, the note goes dark at 4.4 s instead of 8.4 s.
   - Under the bass's A1, the hum 29 dB down, strong ends at 6.3 s instead of 8.4 s, and the decay
     reads A0 and D0, 50 and 55 Hz only repeat together every 5 Hz. E1 barely moves.

   The fix:
   - Always on, detections within about 8 ¢ of 50 or 60 Hz don't name a note, the grid holds mains
     to a few cents. No string is tuned there, 50 Hz is G1 +35 ¢, 60 Hz is A♯1 +50 ¢ and the low B1
     of a seven string or baritone -49 ¢, but a string tuned up or down passes through. Locked or on
     a string the strobe keeps its note. No exception for an onset, plugging a cable in is one too.
   - A "Mains hum" setting, off, 50 Hz or 60 Hz, off by default everywhere. Narrow notches, 1 to
     2 Hz, adaptive to follow the grid's drift, on the mains and its harmonics up to about 8, after
     the high-pass and before both the pitch detection and the strobe. No tempered note is within
     about 19 ¢ of them, higher ones hit partials, 660 Hz is 11 × 60 and E5 is 2 ¢ off it. The one
     fix for a note pulled sharp or lost early, which costs bass the most.
   - Not a steady tone taken for background, a bowed or held note is one too.
2. The detection rate is a throttle, not a cost. The 8192-point FFT takes tens of µs, 20 detections
   a second with 3 confirmations is about 150 ms before a switch. Run it at 50 to 100 a second and
   confirm by time, about 100 ms, not by count, the frames overlap and aren't independent.
3. The window is a fixed 4096 samples, 85 ms. That's 2.3 periods at A0 and 2.6 at a five string
   bass's low B, the far lags rest on few samples. High notes don't need it, and a long window
   keeps the attack's sharp glide in view longer. About 4 periods of the candidate, clamped.
4. Skip the pitch frames for 30 to 50 ms after a pluck, `update_onset` in `phase.odin` already
   finds it. The attack's glide doesn't become a candidate.
5. Low-pass or decimate the input while the candidate is under about 1 kHz. Pick noise and hiss
   go, the NSDF gets cheaper, the precision it loses isn't used.
6. The SNR gate is on the broadband RMS, a fan or rumble pulls it down while the partials stand
   well clear in their own bands. Clarity does most of the rejection anyway (0.98 is about 17 dB
   periodic to aperiodic, 0.9 about 10 dB), the 2 dB gate rarely decides. The bands' SNR is the
   better signal.
7. One candidate a frame. `nsdf_find_peak` keeps the first peak over 0.95 of the highest, and the
   tuner rebuilds the reasoning over time by hand: `candidate_count`, `steady_count`,
   `shortest_period`, `prevent_octave_jumps`. pYIN's part worth taking is the HMM, not YIN: keep 2
   or 3 peaks a frame with their clarity as a likelihood, and pick the note path over time with
   Viterbi, continuity settles the octave on a low string. Reshapes the tuner, discuss first, and
   only if the octave rules keep growing.

To try, no promises: compressed spectrum before the inverse FFT, |X|^0.67 instead of |X|²
(Tolonen and Karjalainen). Sharper peaks, a dominant partial pulls less, but it no longer matches
the time domain normalization in `nsdf_run_nsdf`, the clarity thresholds would move.

## Temperaments

A temperament is how the 12 notes of the octave are spaced, 12 offsets in cents from equal
temperament, one per note name and the same in every octave. It's a layer of its own, not a tuning
and not a preset:

    target = equal temperament note at concert A
           + temperament offset of the note name
           + the preset's offset of the exact note or string

- Loaded from a `.scl` file, nothing to edit. Equal temperament plus a few built in (Pythagorean,
  1/4-comma meantone, Werckmeister III, Vallotti, just).
- Saved with the setup, so a harpsichord preset and a guitar keep their own. On a guitar it tunes
  the open strings, a chromatic setup gets every note.
- The main screen shows the temperament's name, the note's offset under the letter stays the
  preset's own offset only.
- The readout and the strobe measure from the tempered target, 0 is in tune.
- The note names, the ruler and the detection stay on the equal tempered grid in `core/note.odin`,
  the offsets are all under 50 cents so the nearest note is still the right one. The temperament
  is one more term in `tuner_target_freq`, next to `note_offset_cents`.
- Only 12-note scales with a 2/1 octave load, anything else is turned away with a message.
- The file's contents are copied into the config, not its path, iOS doesn't keep access to a file
  and a file on the desktop moves.

Open:

- A `.scl` file has no root and no tie to A. Normalize so A has no offset and concert A stays
  concert A, and pick the root key (which note is the scale's 1/1) on the setup?
- `pitch.odin` measures `err_cents` from the untempered note, check that nothing shown reads it
  once a temperament is set.
