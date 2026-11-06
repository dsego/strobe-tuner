# Ideas

Features and code changes that aren't planned yet. Nothing here is decided.

## Stripe fade from the samples

Built on the `slat-strobe` branch on 2026-11-06, see `src/core/strobe_slats.odin` and the README's Stripe
fade. It replaced the SNR fade with the bands' noise floors and the noise between partials, and the readout,
the note hold and the trace go by it too. What's still open:

- The hard cases: a noisy room, hiss, mains hum, a soft note, a long fade lit to the end, a string tuned
  quickly through two notes (a retune starts the measurements over, a dip of a few periods), and a hummed or
  sung note: a phase coherence fade tried on 2026-10-05 took a voice's waver for noise and grayed a hum's 4×
  (it compared windows apart without following the drift, the measurements here turn with the frame's advance).
- Gone with the SNR fade and not missed so far: the fade of stripes moving too fast for the screen (on a fast
  drift they could seem to turn backwards) and the off-note fade of the brightness (the edges still soften by
  the shader's amp).
- Tried and dropped on the way: a strobe drawn from the slots alone (it vibrated on bass at the lock-in's
  speed), the noise from the positive and negative halves of 64 slots a period (it doesn't average down and
  let fading partials go early), and measurements one period long (a box lets a 2nd partial a few cents off
  into the 1× track 40 dB under it, louder than a low string's fundamental).

## Steady rotation far from a locked note

Behind a flag, in locked mode only. Tuning up a new string with the note locked to low E, the string
starts far below the note and wobbles on the way up. The strobe has nothing steady to show there, and
it's hard to tell how far there is to go.

Far out, show a simulated rotation at a steady rate in the right direction, and blend it into the
real strobe as the string comes within about 50 to 100 cents.

- The band's window is a semitone wide now (`DFT_RESOLUTION_CENTS`), so the lock-in hears the string
  further out than it used to, but the readout only follows a track within 50 cents
  (`READOUT_RANGE_CENTS`). How far down the band hears a string 50 or 100 cents off needs measuring
  again. Past that the direction and distance have to come from the pitch detection, like the
  readout's cents.
- The blend could follow how sure the track's partial is, `slat_level`, which rises as the string comes into
  the window.
- A constant rate reads as "keep going", a rate that follows the distance would jump around with the
  wobble it is meant to hide.
- The handover is the hard part, the simulated stripes and the real ones have to meet without a
  jump in phase or speed. May not be worth it if it can't be made seamless.

## Cent triangles on the strobe's tracks

Each track keeps its spinning stripes and gets a small cyan triangle like the spectrum's, standing off its
middle by the track's cents. The stripes steady the note, the triangle says how far there is to go. A
stripe's speed is the strobe's only cue for distance, and it takes practice to read.

- From the track's own reading, never the pitch detection's cents. It shows once the track settles after
  a pluck and within 50 cents, about where the stripes show anyway, so it can't reach far off where the
  strobe is weakest, that stays the gauge's. Near the note it barely moves. It helps most from about 5 to
  30 cents.
- The Needle display drew the same readings as lines on a scale and was removed 2026-10-31 as too twitchy
  to read: spread out near in tune, the readout's half-cent wobble jumped, weak partials read all over
  and every pluck started over. A triangle has the same readings, it would need a plain scale.
- A triangle needs a zero to read against, a track only has the lamp's hotspot. A zero tick on every
  track, a small scale each.
- The gap between tracks is 4 points (`STROBE_TRACK_GAP`), a partial's triangle 9 wide. It hangs from
  the track's top edge over the stripes, drawn after the bloom so it stays sharp.
- Flat across the track, curved along its arc with the zero at the top. A wheel's ring has no left and
  right, it would go without.
- Track cents already prints each track's number. If it's built, a third option on the Track cents row
  (Off, Numbers, Triangles), not both on the tracks. Tried first behind a `-define` on the flat and
  curved tracks, live on the Paramount sample.

## Partial next to the readout

When the fundamental dies down under a partial, the readout gives way to that partial's track for its
cents, the note and the strobe stay on the note played. A small "×2" next to the readout could say which
track the cents come from.

Tried from 2026-10-07 to 10-09 and dropped: the strobe moved up to the partial so its tracks counted from
it, 1× the partial, and a pluck brought it back. A ukulele's C4 walked up to C8: a beat null in the
fundamental's track lasts one frame, the readout gave way to a partial's track still reading over 16 dB,
and the target followed it in that frame. The fresh tracks did the same from there, C4 to C6 to C8 inside
a second. On C8 nothing hears the string between plucks, so no pluck brought it back, and the pitch
detection's C4 couldn't, the target only changes when the detected note does. The way back was noise too,
a tail's level wobbling counted as a pluck. The readout's own 20 dB "faded" rule flips on the same
one-frame null, it still does.

## In-tune cues

A visual cue once the readout holds within a cent for 0.3 s, left for later. A haptic tap on the phone
was built and removed 2026-11-02: even the strongest of UIKit's was barely felt in the hand, and while
tuning the phone lies on a desk or a stand. Candidates:

- The strobe itself flashes green or brighter for a moment, the way some strobe tuners do.
- The cent triangles above standing in the middle of the tracks as a "locked on" sign.
- Green note name within the tolerance, the strobe itself stays unchanged.
- A short buzz or ping with it, other tuners have one. The microphone hears it, the strobe may twitch.

## Audible beating mode

A tone or click through headphones whose rate follows the pitch error and stops when in tune. Also the
path to real VoiceOver support later.

## Piano stretch tuning

- A note's offset stops at ±25 cents, a stretched treble runs to +30 cents and more at the top. The
  tracks' offsets reach ±50 but are the same for every note.
- The curve depends on the piano, its strings' inharmonicity measured on a few notes.

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
6. A pure sine under 50 Hz in noise shows no note: B0 and E1 with white noise 20 or 10 dB down, all 92
   of their cases in `sandbox/accuracy`'s stress. The harmonic stack takes a note under
   `HARMONICS_BASS_HZ` from the bass window only when it scores `HARMONICS_HIGH_DB` (65), and a sine is
   one harmonic, its score is how far that one peak stands over the noise. It reads noise stacks in the
   short window instead, weak. Moved into the short window, under `HARMONICS_BASS_HZ=35`, the E1 sine
   showed on 143 of 150 detections. Strings, saw and square read from their harmonics, it's sub-bass
   synths and organ pedal flutes.

   Tried and dropped, 2026-11-06, the bass note without the 65: the generated tones all passed, the 3 B0
   cases in KNOWN_ISSUES.md too, and the lowest two octaves showed about 17 ms sooner. But the ukulele's
   Bb4 (`ukulele_A#3.wav`) let go into the room's rumble: from 4.4 s the bass window's stacks, Bb0, Eb1,
   B0 and D1 at 20 to 40 dB, outscored its fade, and from 5.4 to 5.9 s the tuner lit again with nothing
   playing, 927 wrong detections over its 14 runs instead of none. In summed dB one peak far over the
   noise and a few peaks a little over it can score the same, the 65 is what tells them apart.

   Tried and dropped, 2026-11-06, the stack scored like a likelihood (Shi et al., "Robust Bayesian Pitch
   Tracking Based on the Harmonic Model", 2019): each harmonic its peak's power over the background less
   ln 4096, a sinusoid's charge in BIC, a harmonic without a peak costing as much, and a candidate's stack
   only as far up as it adds the most. The gates at 30 and 40 dB of that. 72 of the 92 low sines in noise
   read right, but 500 of the 4,371 generated tones failed and 1,440 of the 1,946 recording runs showed
   another note instead of 110, the Strat's E2 read E3, the bass's E1 E2 and `paramount_A1.wav` A2 all the
   way through. As a power a few loud peaks outweigh the rest, and an octave up's 10 harmonics reach twice
   as high, so a string's loud upper partials would outvote its fundamental and odd harmonics, not traced
   score by score. The fading ukulele scored 27,
   its room's rumble 15 to 29. The paper's speech, 70 to 400 Hz in 25 ms, doesn't meet this. Summed in dB
   the stack trusts a peak far over the background less than a Gaussian likelihood does, and a room makes
   10 to 15 dB peaks far more often than Gaussian noise.

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

## Handpans on a custom instrument

The custom instrument is built since 2026-11-06, a preset of up to 10 notes picked by hand. What's left for
a handpan or a pan:

- The larger handpans and a kalimba have 17 notes, the sheet shows 10 rows without scrolling
  (`MAX_NOTE_OFFSETS`). A D Kurd's 9 fit.
- A handpan's note is tuned on three partials at once, the fundamental, the octave and the compound fifth:
  tracks at 1×, 2×, 3× instead of the default 1×, 2×, 4×, the octave's offset for a maker who tunes it a
  few cents sharp. A steel pan the same, timpani 1×, 1½×, 2×, a xylophone bar's 3×, a marimba's 4×. Does
  a preset keep its own tracks, a handpan's beside a guitar's? Today they're the display's, see Looks for a
  purpose.
- While it's hammered a partial can be 100 cents off, past its track's band, and the track goes dark when
  the maker most needs a direction. The spectrum shows where it is against the track's mark. A marimba
  bar's overtone starts near 2.76× before it's tuned to 4×.

## Instruments the setup doesn't fit

Looked at on 2026-11-06, besides Polyphonic tuning, Piano stretch tuning and Temperaments.

- Courses and unisons, a 12-string's pairs, a mandolin, a piano's two or three strings, an accordion's
  reeds: two strings inside one track's band can't be parted, the stripes pulse at the beat rate and stop
  in unison. Tuned one at a time with the others muted. An accordion's tremolo is a beat rate in hertz,
  fewer cents for the same beat up high, so a preset's offsets note by note.
- Other grids than 12 notes: a maqam's quarter tones on an oud or a qanun sit at ±50 cents, past the note
  offsets' ±25 and halfway to the next note. A 7/4 seventh is -31 cents, and every gamelan has its own
  tuning. Temperaments above loads only 12-note scales.
- Bells, gongs and singing bowls aren't harmonic. A bell rings a hum at 0.5× and a minor third at 1.2×, no
  track goes under 1× or to 1.2×, and the harmonic stack may name the wrong note for the strike. Locking
  the note helps.
- Drums: a tap rings for 0.1 to 0.5 s and isn't harmonic, the readout's 0.6 s settling doesn't finish.
  Tuning a head compares the taps at each tension rod with each other, where a hold of the last reading
  fits, unlike a ringing string. A drum tuner is a product of its own.

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

## Input name under the level meter

With no sound coming in, it isn't obvious why until the input sheet is open: the wrong device may be
picked, BlackHole or an interface with nothing plugged in. The input's name under the level meter,
desktop only, iOS and Android only have "Microphone".

- No short names from the system, CoreAudio and miniaudio give the full "MacBook Pro Microphone". Cut
  to the meter's width with an ellipsis rather than shortening by rules. CoreAudio's transport type
  (built-in, USB, Bluetooth, virtual) could give "USB", but can't tell two interfaces apart.
- Always shown and dim, or only on digital silence, under about -90 dBFS for a second or two. A real
  microphone never gets there, room noise keeps it around -70 to -50 dBFS. Silence only keeps the
  screen clear, but misses the wrong microphone that works, the laptop's instead of the interface's.
- Or both, always dim and in the warning color on silence.
- Only where there's room: the panel beside the strobe and a wide desktop window, never a phone's panel.

## Piano keys under the spectrum

Tapping the spectrum flips it to a bar per piano key, A0 to C8, like the scope's circle and the lamp's
split. A bar is the spectrum's level over its semitone, the note named by where it stands.

- A bar per key, not the 12 note names folded over the octaves. Folded, an A's partials land on A, E
  and C♯, a chord finder's view. Unfolded E2 and E4 stay apart and a string's partials climb the keys.
- What it shows at a glance: which strings of a strummed chord ring, and what a hum is, the kitchen
  fridge's 300 Hz a D4 bar without reading a label.
- Below about 100 Hz a semitone is narrower than the 170 ms window's 6 Hz bins, the low keys share
  bins and blur. The 340 ms window helps, or the bottom octave stays soft.
- Not a way to tune, like the spectrum it shows what's there. After the reference tones and the
  temperaments, which buyers ask for.

## Level per string

For a luthier balancing a pickup string to string, a piezo under the saddle most of all. Asked for in
a review of Peterson's app. With a stringed preset, a row of bars, one per string, each the level of
its last pluck, in dB from the loudest.

- A pluck varies more than the pickup does. Take the level at a fixed time after the onset, about
  100 to 200 ms, past the attack, and average the last 3 to 5 plucks of each string.
- The string is the one the tuner names, a pluck of another string or a chord doesn't count.
- From the string's own track, at its fundamental, or broadband? The track leaves out hum and the
  other strings ringing, broadband is what an amp hears. The pitch detection's band is filtered,
  60 Hz to 5 kHz, a bass E1 reads weaker than it is.
- A reset, and the spread shown, e.g. "B −4.5 dB".

## Spectrogram

The spectrum over time, scrolling, its level as brightness. Another display type, or a tap on the
spectrum flips it, like the scope's circle. Asked for in the same review, as a waterfall.

- What it shows: partials dying away at their own rates, a wolf note or a dead spot as a partial
  that drops out fast, two partials beating.
- The spectrum's own transform already runs, the spectrogram keeps its frames in a texture, a column
  a frame, on the same log axis. SNR or dBFS as the spectrum's scale says.
- The 170 ms window blurs fast changes, the 340 ms one more so. Fine for decays, not attacks.

## Polyphonic tuning

Strum all the strings and see which one is out, a separate product or later. The harmonic stack can take the
best stack, drop its peaks and take the next, a stack per string.

- The tuning's notes are known, each string is looked for near its own note, easier than naming any chord.
- Strings a fourth apart share partials, E2's 4th sits on A2's 3rd. A shared peak counts for one string or
  both.
- The 85 ms window parts peaks 23 Hz apart and more, a low string's partials crowd its neighbour's up high.
- The cents per string want the strobe's tracks on six notes at once, it has 5 tracks.
- The tracks can't part them either: E2's 3rd is 2 cents from the B3 string, A2's 3rd and E2's 4th sit on
  E4, so a track on B3 or E4 beats in a strum. A strum can say which string is out, the strobe tunes them
  one at a time.

## Phone landscape

The phone is portrait only, decided against on 2026-10-11 when the panel beside the strobe needed two
halves of `PANEL_MIN_WIDTH`. Looked at again on 2026-10-21, the main screen is cheap: a column the
phone's width beside the turned strobe is the portrait panel's box, 367 by 372 on a 16 Pro against
393 by 380 upright, so its rows lay out unchanged.

- The rule: beside when wider than tall, the halves equal with the panel at least `STROBE_MIN_WIDTH`.
  367 each on a 15 or 16 Pro, 416 on a Pro Max, an SE's panel 360 with a 307 strobe. A desktop window
  720 to 848 wide and wider than tall goes beside too.
- The strobe shows about the same share of its arcs as upright, 58% against 65%.
- The sheets are the work, 393 tall and they don't scroll. The settings, a track's and the input's
  fit, the Strobe options' 8 rows are about 40 over and fit with rows shrunk to 38.
- The instrument sheet with a preset's note offsets runs about 100 past the bottom for a guitar's six,
  more for ten. Across the whole window in two columns, as it covers the window upright: the
  instrument, tuning and capo on the left, the offsets on the right with their header level with the
  title, ten of them at about 30 points.
- Scrolling would fit any sheet but fights the swipe down that closes it and the offset bars' sideways
  slide, and hides offsets below the fold.
- The plist's phone key adds the two landscapes, upside down stays off.
- Checked in the simulator or on the phone, the desktop window doesn't go under 620 tall.

## Looks for a purpose

Some combinations of the display settings suit a job, e.g. the wheel with one track in By note colors
for naming a note at a glance. A look sets them together with one tap. It sets the display and strobe
rows only, never the tuning: the instrument is what's tuned, the look is how it's shown. Tapping one sets the rows, changing a row afterwards leaves no look picked.

Needs first, a look only where one is real. Three kinds of use:

- Tuning an instrument: the instrument is off and a turn or a slide fixes it. A fast way in, a still
  strobe at the end.
- Playing in tune: the player is off and there's nothing to turn. Their pitch over a note and a phrase,
  how it starts, wavers and drifts, and which way they lean on each note.
- Making or setting up an instrument: the partials too, how they sit against the fundamental and each
  other, on a held note.

Candidates, the settings a first guess to try live:

- Guitar and bass, string by string: the curved strobe with 1×, 2×, 4× and Readout 0.15 s. Today's
  defaults, maybe no look needed.
- Long tones on brass and woodwinds, a trumpet or a sax held for seconds to settle and stay: the trace
  at 5 s and 25 cents, Readout 0.4 s, or the circle scope as a target that should stand still. A Bb
  trumpet's transpose is the instrument's, not the look's.
- Singing: vibrato, the mean pitch through it, slides into a note. The trace at 5 s and 50 cents,
  Readout 0.4 s, By note to know which note it is.
- Fretless strings, a violin or a fretless bass playing scales: notes change fast, finger placement.
  A short trace, Readout 0.15 s, By note.
- Naming a note by ear, sight singing or picking a riff off a record: the wheel, one track, By note,
  the color before the name.
- Guitar intonation at the saddles, the 12th fret's harmonic against the fretted note, a held note to a
  fraction of a cent: the flat strobe with every track, Amber, Spin rate 200%, Readout 0.4 s, each
  track's cents shown.
- Piano, harpsichord, pans and bells, where the partials are tuned too: tracks at 1×, 2×, 3×, 4× labeled
  with their notes and cents, the spectrum to see what rings.
  Temperaments above would go with it.
- Teaching and showing sound, a classroom or a video: the circle scope in By note, the lamp, the
  spectrum with its notes labeled.
- On stage between songs, dark and read from a step away: one big flat track, Mono or red. Maybe.

Open:

- Playing in tune may want more than a look: which notes a player leans sharp or flat on over a
  session, a trumpet's 5th partial flat for one. A feature of its own, not settings.
- Purpose names, "Note finder", "Long tones", against the mechanism names of the settings. A look is a
  purpose, a setting isn't.
- On the display sheet, as small pictures like the colors' swatches, nothing on the main screen.
- Built-in looks first, the musician's own saved ones later if they catch on.

## Which preset is on

Two guitars in the same tuning, each with its own note offsets, look the same on the main screen: only
the corner's "P1 - GUITAR" tells them apart, and one tuned on the other's preset reads the wrong offsets
with nothing looking wrong. Something to notice from a step away, not a name that changes. A strobe pedal
shown in 2026 lights its whole display in a color picked for each preset, ten to pick from.

- The preset's own colors: each preset remembers a colorway like its tuning and capo, the Colors row sets
  the selected preset's and the built-in instruments share the app's. Said in the row, e.g. "Colors · P1",
  or a change made on a preset looks lost on Guitar. By note already colors the note, a preset on it says
  nothing about the preset.
- Something other than the strobe's colors, so it keeps the look picked: a pill around the corner's preset
  name, or a mark in a color of each preset's own. The main screen's controls are their labels alone so far,
  dots on the display button were dropped as too much.