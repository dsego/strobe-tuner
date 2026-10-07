# Ideas

Features and code changes that aren't planned yet. Nothing here is decided.

## Steady rotation far from a locked note

Behind a flag, in locked mode only. Tuning up a new string with the note locked to low E, the string
starts far below the note and wobbles on the way up. The strobe has nothing steady to show there, and
it's hard to tell how far there is to go.

Far out, show a simulated rotation at a steady rate in the right direction, and blend it into the
real strobe as the string comes within about 50 to 100 cents.

- The band's window is a semitone wide now (`DFT_RESOLUTION_CENTS`), so the lock-in hears the string
  further out than it used to, but the readout only follows a track within 30 cents
  (`READOUT_RANGE_CENTS`). How far down the band hears a string 50 or 100 cents off needs measuring
  again. Past that the direction and distance have to come from the pitch detection, like the
  readout's cents.
- The blend could follow the band's SNR, which rises as the string comes into the window.
- A constant rate reads as "keep going", a rate that follows the distance would jump around with the
  wobble it is meant to hide.
- The handover is the hard part, the simulated stripes and the real ones have to meet without a
  jump in phase or speed. May not be worth it if it can't be made seamless.

## Partial next to the readout

When the fundamental dies down under a partial, the strobe moves up to that partial and the note shown is
named after it, e.g. D#2 for a bass's D#1. The tracks then count from the partial, 1× is D#2. As an
alternative to moving the strobe, it could stay on the note played with a small "×2" next to the readout,
saying which track the note and the Hz come from. No restart of the stripes mid-note, but the track labels
don't count from the note shown.

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

## Desktop on SDL

SDL3 is the one renderer now, it brings what the desktop is missing: text input, dropped files, open
dialogs and a resizable window. Linux hasn't run it on real hardware yet.

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
   - Done, always on, detections within about 8 ¢ of 50 or 60 Hz don't name a note, the grid holds mains
     to a few cents. No string is tuned there, 50 Hz is G1 +35 ¢, 60 Hz is A♯1 +50 ¢ and the low B1
     of a seven string or baritone -49 ¢, but a string tuned up or down passes through. Locked or on
     a string the strobe keeps its note. No exception for an onset, plugging a cable in is one too.
   - Tried and dropped, a "Mains hum" setting, notches on the mains and its harmonics up to the
     8th, each 0.6 Hz wider than the one below, before the pitch detection and the strobe. The
     7th of 50 Hz, 350 Hz, is F4 +4 ¢ at A 440, and at A 444 250 Hz is B3 +5 ¢, so the notches
     skipped harmonics within 15 ¢ of a note. With the rest gone the 7th is the cleanest thing
     left of a buzz, after the ukulele's A4 died the tuner lit F3 and F4, where the hum alone
     reads G1 and the rule above keeps it dark. With the rule and the strobe's hold the note
     shown under hum was already right throughout, the notches only raised the clarity.
   - Not a steady tone taken for background, a bowed or held note is one too.
2. Done, the pitch detection hears up to 5 kHz, a low-pass on its own samples. With white hiss
   40 dB down the Strat's A2 reads strong 14 times instead of 2, the acoustic's at 35 dB down
   stays lit to 12 s instead of 2.8 s, the clean recordings don't change.
3. Done, 60 detections a second and the tuner confirms by time, `NOTE_SWITCH_S` instead of a
   count, the readout smoothing a time constant, a steady run held to its first detection
   instead of each previous one. At the old 0.1 s a note shows about 70 ms sooner, 0.20 s
   instead of 0.27 s, at 0.05 s from 0.12 to 0.15 s, the same notes right everywhere. At 0 the
   ukulele under hum shows a wrong note 12% of the time.
4. The window is a fixed 4096 samples, 85 ms. That's 2.3 periods at A0 and 2.6 at a five string
   bass's low B, the far lags rest on few samples. Measured and it holds, in
   `test_nsdf_accuracy` A0 and B0 read within 0.05 ¢ as sines and 0.2 ¢ with a weak fundamental
   under louder partials, the window stays.
5. Octaves by continuity. The decay of a string can repeat at half its period, the bass's E1
   reads E2 from about 4 s and the ukulele's A4 reads A5, and the tuner shows the octave. Both
   peaks are in `NSDF.peaks`. `sandbox/hmm` picks the note with an HMM over all of them, like
   pYIN, a causal forward pass, clarity^8 as the likelihood, later peaks counting half, a note
   staying 0.97. Against the tuner on the recordings:
   - E1 between 4 and 8 s, right 100% instead of 58%, the ukulele's A4 never shown as A5.
   - It loses notes the tuner keeps, the last A2 of a sequence in hiss or hum 71 to 75% instead
     of 100%, the A1 under hum after 8 s 47% instead of 100%. The tuner has the strobe's settled
     track to hold a note, the HMM doesn't.
   - After 8 s the E1 really repeats at E2, both show E2.

   The HMM as a whole isn't a win, its continuity on the octave is.
6. A pure sine under the 60 Hz high-pass needs more level than a string. B0's 31 Hz loses about 9 dB
   in it, under white noise 10 dB down the NSDF finds the period at clarity 0.75, under 0.9, the floor
   learns the tone and no note shows. Live with a tone generator and white noise B0 shows at 10% and
   not at 4%. Strings, saw and square read from their harmonics, it's sub-bass synths and organ pedal
   flutes. A cutoff nearer A0 (27.5 Hz) would help them and let more rumble in, `sandbox/accuracy`
   reports these cases as stress.

   Tried and dropped, the smaller version: a detection an octave or two above the followed note
   left out while the wave repeats better at the followed period and nothing was plucked for
   half a second. The E1 read right to 12 s, but nothing tells a ringing string from a slur on a
   trumpet or violin, and the clarities across lags aren't comparable for high notes. A steady
   sawtooth slurred from A3 to A5 never showed A5, the NSDF read 0.993 at A5's period of 54.5
   samples and 0.996 at A3's, the parabola misses the sharp peak more at a short lag. A string
   that reads its octave as it rings out is left as it is.

Dropped: skipping the pitch frames after a pluck, the readout near the note comes from the strobe
now and it would hold back the first detection. Replacing the broadband SNR gate, clarity does the
rejection (0.98 is about 17 dB periodic to aperiodic, 0.9 about 10 dB) and the low-pass took the
hiss out of the level too.

Tried and dropped: compressed magnitudes (Tolonen and Karjalainen), the samples rebuilt with |X|^k
and their phases so the normalization still matches. It flattens the hiss along with the partials,
with white hiss 40 dB down the Strat's A2 reads right 13% of the time at k = 0.5 and 83% at 0.75,
against 100%. Only the bass E1's decay gains, 77% to 90%, fewer octave errors.

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
- The note names, the ruler and the detection stay on the equal tempered grid in `src/core/note.odin`,
  the offsets are all under 50 cents so the nearest note is still the right one. The temperament
  is one more term in `note_offset_cents`, `tuner_target_freq` and `tuner_cents` both go through it.
- Only 12-note scales with a 2/1 octave load, anything else is turned away with a message.
- The file's contents are copied into the config, not its path, iOS doesn't keep access to a file
  and a file on the desktop moves.

Open:

- A `.scl` file has no root and no tie to A. Normalize so A has no offset and concert A stays
  concert A, and pick the root key (which note is the scale's 1/1) on the setup?
- `pitch.odin` measures `err_cents` from the untempered note, the readout's comes from `tuner_cents`
  with the offset taken off. Check that nothing shown reads the pitch detection's once a temperament
  is set.

## Sharper fonts

The text is baked at its exact pixel size and drawn texel for pixel, but stb_truetype doesn't hint. A stem
of Inter Medium at 14 pt is about 2.4 px wide on a 2× screen and lands wherever the outline falls, so
most stems carry a grey column, small grey labels on the grey sheets look soft.

- A per-glyph shift: bake each glyph at the fraction of a pixel, of 8 tried, that leaves the most pixels
  solid (`MakeCodepointBitmapSubpixel`), its stems as close to the grid as its shape allows. No new
  dependency, at most half a pixel more or less between letters. A heuristic, an "m" can only line up
  one of its stems. Try it behind a `-define` first.
- Tried and dropped, FreeType's auto-hinter through SDL3_ttf (`vendor:sdl3/ttf`), the glyphs from
  `RenderGlyph_Blended` into the same atlas. On the 2× Mac normal hinting gave solid stems up close but
  was barely noticeable in use, not worth building SDL3_ttf for every platform. Worth another look for
  a 1× screen. Its rounded advances were the part that showed, those are in.
- Tried and dropped, a curve on the glyphs' coverage pushing the edges towards solid, today's look stays.
- The labels' 1 pt letter spacing is a fraction of a pixel at a fractional scale, Android's 2.625 or
  Windows' 1.25 and 1.5, every letter after the first lands between pixels. Rounded to whole pixels in
  `draw_label` it stays as it is at 2× and 3×.
- Not sharpness but close: kerning isn't applied (`GetCodepointKernAdvance`), pairs like "Te", "AV" and
  "7." keep their unkerned gaps. Rounded to whole pixels per pair, in `draw_text` and `measure_text`.

## Gamma window as a recursive filter

Every hop runs a whole window's DFT, about 4 × the note's frequency of them a second per track
(`HOPS_PER_PERIOD`), roughly 70 multiply-adds per sample whatever the note. The window, age² · e^(−age),
is a third order gamma, the gammatone filter's shape: the samples mixed down by the reference oscillator
and through three one-pole low-passes in a row give the same window, the comb's box a running sum on the
input. A phase at every sample for about 10 to 15 operations, the hops cost nothing and the lock-in
rotation goes away.

- The window stops at 10.9 τ (`GAMMA_WINDOW_TAU`), about 0.13% of the gamma's weight is past it, so the
  filter's endless tail barely differs.
- The state in f64, the pole is very close to 1 on a 20k sample window.
- A retune now measures straight from the ring buffer. The filters would run over the buffer once on a
  retune to keep that, about one window's pass.
- Only worth it if the hops get in the way, more of them a period, or the DFT shows up on the phone's
  profile. With the SIMD DFT five tracks take under 1% of a desktop core.
