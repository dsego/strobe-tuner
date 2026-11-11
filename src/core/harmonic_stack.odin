// Copyright (C) 2026  Davorin Šego

// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version.

// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
// more details.

// You should have received a copy of the GNU General Public License along
// with this program.  If not, see <http://www.gnu.org/licenses/>.


package core

import "core:math"
import "core:math/cmplx"
import "core:slice"


// The pitch as the best stack of harmonics in the spectrum, the other way to the NSDF's period of the whole
// wave, see PitchMethod. Each peak counts by how far it stands over the sound around it, not by its level,
// and only where a candidate's harmonics fall. The whole wave weighs everything by its power: a hum's six to
// eight harmonics a few dB over a song read clarity 0.7, the song's loud bass and drums are most of the wave,
// and a loud hum read a third of its pitch where the song's bass shares the period. Here they add up, the
// song's broad bass and drums sink into the background and don't line up on the hum's spacing.

// The background around a bin, a quarter of the bins this far either side: a low note's partials and their
// lobes take up more than half of them, the quarter falls between. A noise's bins are spread exponentially,
// their quarter is 0.288 of their mean, HARMONICS_QUARTER_DB under it. Worked out every few Hz and drawn
// straight between, like the spectrum display's.
HARMONICS_BACKGROUND_HZ :: 190
HARMONICS_BACKGROUND_STEP_HZ :: 47
HARMONICS_QUARTER_DB :: 5.41

// Over the top, see HARMONICS_SECOND_REACH, the background is worked out this many steps apart, as far apart as
// the bins either side of it reach: only the top notes' 2nd harmonics are looked for there, and every 47 Hz up
// to 10 kHz doubled the stack's time. With this and the peaks only up to C8's 2nd harmonic it takes 15 to 25%
// longer than without the reach, the recordings and the generated tones read the same.
HARMONICS_BACKGROUND_STEPS_OVER_TOP :: 4

// The background no lower than this under the loudest peak, a microphone's own noise is closer under a note.
// Over a generated tone's digital silence a partial 90 dB down stood out as far as a loud one: a triangle wave's
// aliases made up a stack of their own and read Bb4 for A2. Over HARMONICS_HIGH_DB, a sine stays strong.
// E.g. -define:HARMONICS_RANGE_DB=n
HARMONICS_RANGE_DB :: #config(HARMONICS_RANGE_DB, 70)

// A peak this far over its background is one, the rest is the background's own ripple
HARMONICS_PEAK_DB :: 6

// A loud partial's sidelobes under the Hann window, 31 dB down 2.5 of the window's bins away and falling 18 dB
// an octave, about -10 - 60 log10(bins) dB, stand over the noise close to it: as peaks of their own they made up
// stacks, a 110 Hz sine read A0 and a 329.63 Hz one E2. A peak less than this over a louder one's sidelobes
// is left out, and one within its main lobe, 2 bins either side.
HARMONICS_SIDELOBE_MARGIN_DB :: 6
HARMONICS_MAIN_LOBE_BINS :: 2

// The most prominent peaks taken in each octave from the lowest note up, a candidate is one of them as one of
// its first HARMONICS_COUNT harmonics. The 40 most prominent of all were a low saw's harmonics from anywhere,
// each stands about as far over its background: an A1 saw kept its first three and its 16th up, its first ten
// scored as much as its 10th's, and it read C#5 on 59 of 137 detections. A note's first harmonics are in its
// lowest octaves, a few to each. E.g. -define:HARMONICS_PEAKS_PER_OCTAVE=n
HARMONICS_PEAKS_PER_OCTAVE :: #config(HARMONICS_PEAKS_PER_OCTAVE, 8)

// The harmonics a candidate counts, each this much of the one under it, a candidate an octave down has only
// every other one and its first ones are missing (Hermes' subharmonic summation). Each counts its whole dB, a
// sine is one harmonic and a note like any other.
HARMONICS_COUNT :: 10
HARMONICS_WEIGHT :: 0.84

// A peak is the harmonic this close to it, the more so the higher, a string's partials run sharp: a piano's
// low strings' 10th about 35 cents. It counts less the further off, nothing out there: counted whole, a low
// square's odd harmonics, 110 Hz apart at A1, each fell within 10 to 44 cents of a 378 Hz candidate's, 8 of its
// first ten to A1's own 5, and it outscored A1 164 to 125.
HARMONICS_TOLERANCE_CENTS :: 30
HARMONICS_STRETCH_CENTS :: 3

// A candidate's 2nd harmonic counts up to this many times the top, the others up to the top: from E♭7 up a
// note's 2nd harmonic is over the detector's low-pass and the note was a single peak, a note under it with faint
// peaks for its other harmonics outscored it, a sped-up sample's B7 and C8 read A4 and B♭4. The low-pass is a
// gentle slope, a peak over it stands as far over its background. Only the 2nd: counting every harmonic up to
// 10 kHz took a square's E♭4 to B5, its 3rd harmonic's odd harmonics reaching higher than its own ten. The
// sample's B7 and C8 read right, the Salamander piano's A7 lit long enough to be measured and passed, the rest
// of it, the recordings and the generated tones as before. E.g. -define:HARMONICS_SECOND_REACH=1 for none
HARMONICS_SECOND_REACH :: #config(HARMONICS_SECOND_REACH, 2)

// A low string's loud 3rd harmonic outscored its own stack at the attack, the fundamental and the 2nd still weak
// there: A1 read E3 and G2 read D4. A third or a half of the best is the note when its own harmonics, the ones the
// best doesn't have, add up to this percentage of the best's score. A note's own third or half finds only noise
// there. At 50 and 70 a few of the guitar's frames still read the 3rd or the 4th harmonic, the hum under a song
// lit the same at 30. A fifth and a seventh too took a low square from its 7th harmonic to the note, and the
// ukulele's G3 and G#3 a few detections under theirs. E.g. -define:HARMONICS_OWN_PERCENT=n
HARMONICS_OWN_PERCENT :: #config(HARMONICS_OWN_PERCENT, 30)
HARMONICS_DIVISORS :: [2]int{3, 2}

// The spectrum's loudest peak is the note when it's one of the best note's harmonics over the fundamental and
// each of the others is this far under it: one loud partial and faint peaks for the rest. A piano's E♭7 has one
// partial under the low-pass, and B4 took it as its 5th harmonic and the faint peaks of other strings ringing
// along, 30 to 50 dB under it, as its 2nd, 3rd and 6th, and outscored it. On a Salamander piano from A0 to A7,
// 51 of 392 runs failed instead of 63 and E♭7 none of its 12, the other recordings and the generated tones as
// before. At 15 its A1 read A2, its 2nd harmonic 15 to 20 dB over the others, at 30 E♭7 failed 6 runs again.
// The others' power together 10 or 13 dB under it took a ukulele's B♭4 and a bass's A♭1 an octave up, their
// fundamental weak and the rest weaker. E.g. -define:HARMONICS_STEP_UP_DB=n
HARMONICS_STEP_UP_DB :: #config(HARMONICS_STEP_UP_DB, 20)

// A note under this has its harmonics closer together than the detector's window can part: 41 Hz apart at E1,
// and a peak under the Hann taper is 4 of the window's 11.7 Hz bins wide at 48 kHz. Saws at B0 and E1 stood so
// little over their background they had no stack. These candidates come from a window HARMONICS_BASS_WINDOWS
// times as long, the others from the detector's: a longer window sees a new note later and stands every peak
// further over its background, twice as long for every note lit a pluck 17 ms later on average and a song
// alone half the time instead of a tenth. E.g. -define:HARMONICS_BASS_HZ=n, under A0 for none.
HARMONICS_BASS_HZ :: #config(HARMONICS_BASS_HZ, 50)
HARMONICS_BASS_WINDOWS :: 2

// The pitch the tuner follows keeps its stack against a harmonic or an undertone of it while it scores this
// much of the best, a steady octave beats one that flips, even the wrong one. For a few detections after a low
// note stepped the lower spectrum spans both and its stack comes apart, the upper spectrum's 3rd or 5th harmonic
// won and was taken for the note. A note an octave up scores about two thirds of its own over the followed one's
// even harmonics and gets through. E.g. -define:HARMONICS_HOLD_RATIO=n
HARMONICS_HOLD_RATIO :: #config(HARMONICS_HOLD_RATIO, 0.8)

// Each peak counts as far as its phase went on from the detection before as its frequency says, a steady partial
// all of it, see phase_steadiness. Like the strobe's stripes by how sure their phase is, and MP3's psychoacoustic
// model telling tones from noise by how predictable each bin is. A detection 800 samples on shares 80% of the
// window with the one before, noise's phase barely wanders between them: 0.73 on average. What it mostly leaves
// out is a window's side peaks, their phase goes on at the partial's frequency and not their own: on the generated
// tones 45 of 172 cases stopped failing, 43 of them sines, 135 of 139 recordings lit their note on the same frame,
// 4 a frame later. -define:HARMONICS_PHASE_STEADY=false to leave it out.
HARMONICS_PHASE_STEADY :: #config(HARMONICS_PHASE_STEADY, true)


// The stack in two spectra of the latest samples, the better of the two, see run_harmonic_stack
HarmonicStack :: struct {
    upper_spectrum: StackTransform, // the detector's window, the candidates from HARMONICS_BASS_HZ up
    lower_spectrum: StackTransform, // HARMONICS_BASS_WINDOWS of it, the candidates under, up to lower_top_hz
    harmonics:      [HARMONICS_COUNT]StackPeak, // the note's stack, each harmonic's peak, 0 Hz for none
    score_db:       f32, // the latest detection's, see run_harmonic_stack
}

// A window's spectrum, the peaks in it and the best stack of them the detection before
StackTransform :: struct {
    spectrum:    WindowedSpectrum, // the latest samples under a Hann taper
    bin_hz:      f32,
    top_bin:     int, // the highest one looked at, the levels and the background are the latest up to it
    levels:      []f32, // dB of each bin from a full scale sine's
    background:  []f32, // dB around each bin, see HARMONICS_BACKGROUND_HZ
    around:      []f32, // the bins around one, sorted for the quarter
    peaks:       [dynamic]StackPeak, // the most prominent ones, low to high
    previous_hz: f32, // the best stack's fundamental the detection before, see best_stack

    // The latest bins with their phases and the detection before's, with HARMONICS_PHASE_STEADY
    bins:          []complex64,
    previous_bins: []complex64,
    has_previous:  bool,
}

StackPeak :: struct {
    freq:    f32,
    level:   f32, // dB
    over_db: f32, // over the background
}

// The detector's window, the lower spectrum's is HARMONICS_BASS_WINDOWS of it
init_harmonic_stack :: proc(window: int, sample_rate: f32) -> (self: HarmonicStack) {
    self.upper_spectrum = init_stack_transform(window, sample_rate)
    self.lower_spectrum = init_stack_transform(HARMONICS_BASS_WINDOWS * window, sample_rate)
    return
}

init_stack_transform :: proc(window: int, sample_rate: f32) -> (self: StackTransform) {
    self.spectrum = init_windowed_spectrum(window)
    self.bin_hz = sample_rate / f32(self.spectrum.fft_size)
    self.levels = make([]f32, len(self.spectrum.spectrum))
    self.background = make([]f32, len(self.spectrum.spectrum))
    self.around = make([]f32, 2 * int(HARMONICS_BACKGROUND_HZ / self.bin_hz) + 1)
    when HARMONICS_PHASE_STEADY {
        self.bins = make([]complex64, len(self.spectrum.spectrum))
        self.previous_bins = make([]complex64, len(self.spectrum.spectrum))
    }
    return
}

destroy_harmonic_stack :: proc(self: ^HarmonicStack) {
    destroy_stack_transform(&self.upper_spectrum)
    destroy_stack_transform(&self.lower_spectrum)
}

destroy_stack_transform :: proc(self: ^StackTransform) {
    destroy_windowed_spectrum(&self.spectrum)
    delete(self.levels)
    delete(self.background)
    delete(self.around)
    delete(self.peaks)
    delete(self.bins)
    delete(self.previous_bins)
}

// The best stack's fundamental from lowest_hz up, 0 for none, and its harmonics' dB over their background
// summed, weighted down the stack: the lower spectrum's under HARMONICS_BASS_HZ or the upper one's over it,
// whichever scores more. The samples are the lower spectrum's window, the upper one's is the latest of them.
// The peaks are looked for up to top_hz, the detector's low-pass, and a stack's fundamental may be up there
// too: the detector tells a pitch over its notes from a note, a D8 sine taken only as far as C8 read D7, its
// 2nd harmonic. followed_hz is the pitch the tuner follows, 0 for none, see HARMONICS_HOLD_RATIO. hop is the
// new samples since the detection before, 0 if not known, see HARMONICS_PHASE_STEADY. highest_hz is the highest
// note's, the peaks over top_hz go up to its 2nd harmonic, 0 for as far as HARMONICS_SECOND_REACH goes.
run_harmonic_stack :: proc(
    self: ^HarmonicStack,
    samples: []f32,
    lowest_hz, top_hz: f32,
    followed_hz: f32 = 0,
    hop := 0,
    highest_hz: f32 = 0,
) -> (
    freq, score_db: f32,
) {
    // C8's 2nd harmonic, 8.8 kHz at A4 = 440 Hz with the tuner's half a semitone over it, not 10 kHz
    peaks_top := harmonic_top(2, top_hz)
    if highest_hz > 0 do peaks_top = min(peaks_top, freq_at_cents(2 * highest_hz, harmonic_tolerance(2)))

    lower_top := min(lower_top_hz(), top_hz)
    upper_freq, upper_db := best_note(&self.upper_spectrum, samples, max(lowest_hz, HARMONICS_BASS_HZ), max(f32), top_hz, peaks_top, hop)
    lower_freq, lower_db := best_note(&self.lower_spectrum, samples, lowest_hz, HARMONICS_BASS_HZ, lower_top, lower_top, hop)

    // The lower note only over the upper one's in the lower spectrum too, its peaks stand further over their
    // background there: a bass's C2 read C1 and a ukulele's Bb2 a third of it now and then, a stack with every
    // other or every third harmonic outscoring the whole one in the upper spectrum. And only a strong one: a
    // song's chords made up stacks under them, an F#1 under F#2 and C#3 and a B0 under B1, at up to 58 dB, a bass
    // guitar's E1 to G1 scored 160 and more. Without it a ukulele's Bb4 let go into the room's rumble, the lower
    // spectrum's Bb0, Eb1, B0 and D1 at 20 to 40 dB outscored its fade and lit the tuner with nothing playing.
    upper_in_lower, _ := score_stack(self.lower_spectrum.peaks[:], upper_freq, lower_top)
    lower_wins := lower_db >= HARMONICS_HIGH_DB && lower_db > upper_db && lower_db > upper_in_lower

    // The upper note stepped down in the lower spectrum, to a third or a half of it under HARMONICS_BASS_HZ: the
    // upper one can't go there, and a low note's harmonics are too close together in it to step from. A B0 with a
    // weak fundamental in noise read B1 in every other detection, its B1 scoring as much as the B0 in the lower
    // spectrum, and the upper spectrum's own B1 15 to 30 dB. Only a strong one, like the lower note. Only from
    // an upper note under lower_top: over it the lower spectrum has none of its harmonics, it scores nothing there
    // and any lower peaks under it passed as its own.
    under: f32
    if upper_freq < lower_top {
        under = step_down_to_note(self.lower_spectrum.peaks[:], upper_freq, upper_in_lower, lowest_hz, lower_top)
    }
    under_db, _ := score_stack(self.lower_spectrum.peaks[:], under, lower_top)
    upper_steps_under := under > 0 && under < HARMONICS_BASS_HZ && under_db >= HARMONICS_HIGH_DB

    note := &self.upper_spectrum
    freq, score_db = upper_freq, upper_db
    if lower_wins {
        note, freq, score_db = &self.lower_spectrum, lower_freq, lower_db
    }
    if upper_steps_under {
        note, freq, score_db = &self.lower_spectrum, under, under_db
    }

    // A harmonic or an undertone of the followed pitch, the stack is tried at the followed pitch too and kept
    // there when it scores nearly as well: the followed octave holds. From the best's own pitch, the followed
    // one may be the note before a step.
    held_hz, related := followed_pitch_from(freq, followed_hz)
    if related {
        held := stack_transform_at(self, held_hz)
        held_top := lower_top if held == &self.lower_spectrum else top_hz
        held_db, held_freq := score_stack(held.peaks[:], held_hz, held_top)
        if held_freq > 0 && held_db >= HARMONICS_HOLD_RATIO * score_db {
            note, freq, score_db = held, held_freq, held_db
        }
    }

    // One loud partial is its own note, not one of a note's under it, the held one too. The score stays, like
    // the step down's.
    if note == &self.upper_spectrum {
        freq = step_up_to_loudest(note.peaks[:], freq, top_hz)
    }

    self.harmonics = stack_harmonics(note.peaks[:], freq, top_hz)
    self.score_db = score_db
    return
}

// The best stack in the transform of the latest samples, a candidate from from_hz to under below_hz, its
// harmonics up to top_hz and its peaks up to peaks_top_hz, see HARMONICS_SECOND_REACH, and the note under it, see
// step_down_to_note. hop is the new samples since the detection before.
best_note :: proc(self: ^StackTransform, samples: []f32, from_hz, below_hz, top_hz, peaks_top_hz: f32, hop := 0) -> (freq, score_db: f32) {
    window := len(self.spectrum.samples)
    copy(self.spectrum.samples, samples[len(samples) - window:])
    run_windowed_spectrum(&self.spectrum, self.bins)

    self.top_bin = min(int(peaks_top_hz / self.bin_hz), len(self.levels) - 2)
    measure_stack_background(self, top_hz)
    find_stack_peaks(self, from_hz, hop)
    when HARMONICS_PHASE_STEADY {
        copy(self.previous_bins, self.bins)
        self.has_previous = true
    }

    // The score stays the best stack's, how sure it is a note
    freq, score_db = best_stack(self, from_hz, below_hz, top_hz)
    freq = step_down_to_note(self.peaks[:], freq, score_db, from_hz, top_hz)
    return
}

// The lower spectrum's peaks go as far as a candidate's 10th harmonic under HARMONICS_BASS_HZ
lower_top_hz :: proc() -> f32 {
    return freq_at_cents(HARMONICS_COUNT * HARMONICS_BASS_HZ, harmonic_tolerance(HARMONICS_COUNT))
}

// The spectrum the stack looks at freq in, the lower one up to lower_top_hz
stack_transform_at :: proc(self: ^HarmonicStack, freq: f32) -> ^StackTransform {
    return &self.lower_spectrum if freq < lower_top_hz() else &self.upper_spectrum
}

// Each of the fundamental's first harmonics up to top_hz, the peak score_stack counts for it, 0 Hz for none
stack_harmonics :: proc(peaks: []StackPeak, fundamental, top_hz: f32) -> (harmonics: [HARMONICS_COUNT]StackPeak) {
    if fundamental <= 0 do return

    for &peak, index in harmonics {
        harmonic := index + 1
        target := f32(harmonic) * fundamental
        if target > harmonic_top(harmonic, top_hz) do break

        peak, _ = matching_peak(peaks, target, harmonic_tolerance(harmonic))
    }
    return
}

// How high the harmonic counts, see HARMONICS_SECOND_REACH. Over the detector's low-pass only: the lower
// spectrum's top is where its candidates' 10th harmonics end, and an A4 held there took A5 as its 2nd harmonic
// and kept a piano's A5 an octave down.
harmonic_top :: proc(harmonic: int, top_hz: f32) -> f32 {
    if harmonic != 2 || top_hz <= lower_top_hz() do return top_hz

    return HARMONICS_SECOND_REACH * top_hz
}

// How far a harmonic's peak may be from it, see HARMONICS_TOLERANCE_CENTS
harmonic_tolerance :: proc(harmonic: int) -> f32 {
    return HARMONICS_TOLERANCE_CENTS + HARMONICS_STRETCH_CENTS * f32(harmonic)
}

// The followed pitch as freq has it when freq is one of its harmonics or undertones: freq divided by the
// harmonic, or times the undertone. related is false when it's neither, or nothing is followed.
followed_pitch_from :: proc(freq, followed_hz: f32) -> (pitch_hz: f32, related: bool) {
    multiple := harmonic_multiple(freq, followed_hz)
    if multiple == 0 do return 0, false

    if freq > followed_hz do return freq / f32(multiple), true

    return freq * f32(multiple), true
}

is_harmonic_or_undertone :: proc(freq, of_hz: f32) -> bool {
    return harmonic_multiple(freq, of_hz) != 0
}

// How many times the higher of freq and of_hz is the lower, 2 to HARMONICS_COUNT, 0 for neither or no pitch.
// Within the harmonic's tolerance and NOTE_HOLD_CENTS more, the note stepped as far as that and stayed the same
// note: a low square stepped 55 cents and its new 5th harmonic was 49 cents off the followed one's.
harmonic_multiple :: proc(freq, of_hz: f32) -> int {
    if freq <= 0 || of_hz <= 0 do return 0

    ratio := max(freq, of_hz) / min(freq, of_hz)
    nearest := int(math.round(ratio))
    if nearest < 2 || nearest > HARMONICS_COUNT do return 0

    off_cents := abs(1200 * math.log2(ratio / f32(nearest)))
    if off_cents > harmonic_tolerance(nearest) + NOTE_HOLD_CENTS do return 0

    return nearest
}

// Every peak as each of a candidate's first harmonics, from from_hz to under below_hz, the stack that scores
// best: its fundamental, 0 for none, and its score. The one nearest the detection before's goes first: through a
// held note it's the best again, and the others are given up on as soon as they can't beat it, see score_stack.
// A strummed chord's took a quarter less time, and every pitch and score came out the same.
best_stack :: proc(self: ^StackTransform, from_hz, below_hz, top_hz: f32) -> (freq, score_db: f32) {
    peaks := self.peaks[:]
    most_db: f32
    for peak in peaks {
        most_db = max(most_db, peak.over_db)
    }

    nearest := nearest_candidate(peaks, self.previous_hz, from_hz, below_hz)
    if nearest > 0 {
        score_db, freq = score_stack(peaks, nearest, top_hz)
    }

    for peak in peaks {
        for harmonic in 1 ..= HARMONICS_COUNT {
            candidate := peak.freq / f32(harmonic)
            if candidate < from_hz do break
            if candidate >= below_hz do continue

            score, fundamental := score_stack(peaks, candidate, top_hz, score_to_beat = score_db, most_db = most_db)
            if score > score_db {
                freq, score_db = fundamental, score
            }
        }
    }

    self.previous_hz = freq
    return
}

// The candidate nearest freq, one of the peaks over one of its first HARMONICS_COUNT harmonics from from_hz to
// under below_hz, 0 for none
nearest_candidate :: proc(peaks: []StackPeak, freq, from_hz, below_hz: f32) -> (nearest: f32) {
    if freq <= 0 do return

    closest := max(f32)
    for peak in peaks {
        harmonic := clamp(math.round(peak.freq / freq), 1, HARMONICS_COUNT)
        candidate := peak.freq / harmonic
        if candidate < from_hz || candidate >= below_hz do continue

        cents := abs(cents_deviation(candidate, freq))
        if cents < closest {
            nearest, closest = candidate, cents
        }
    }
    return
}

// Down from freq to a third or a half of it while that's the note, see note_under
step_down_to_note :: proc(peaks: []StackPeak, freq, score_db, lowest_hz, top_hz: f32) -> f32 {
    freq := freq
    for freq > 0 {
        lower, found := note_under(peaks, freq, score_db, lowest_hz, top_hz)
        if !found do break

        freq = lower
    }
    return freq
}

// The note at the loudest of the peaks when it's one of freq's harmonics over the fundamental and each of freq's
// others is HARMONICS_STEP_UP_DB under it, freq when not. The loudest of the peaks, not the one freq's harmonic
// counts: a piano's unison strings put a weaker peak beside the partial, and B4 took that one as its 5th.
step_up_to_loudest :: proc(peaks: []StackPeak, freq, top_hz: f32) -> f32 {
    if freq <= 0 do return freq

    // Of the peaks up to the top, the ones over it count only as 2nd harmonics
    loudest: StackPeak
    for peak in peaks {
        if peak.freq <= top_hz && (loudest.freq == 0 || peak.level > loudest.level) do loudest = peak
    }
    if loudest.freq == 0 do return freq

    harmonic := int(math.round(loudest.freq / freq))
    if harmonic < 2 || harmonic > HARMONICS_COUNT do return freq
    if abs(cents_deviation(loudest.freq, f32(harmonic) * freq)) > harmonic_tolerance(harmonic) do return freq

    for other in 1 ..= HARMONICS_COUNT {
        target := f32(other) * freq
        if target > harmonic_top(other, top_hz) do break
        if other == harmonic do continue

        peak, _ := matching_peak(peaks, target, harmonic_tolerance(other))
        if peak.freq > 0 && loudest.level - peak.level < HARMONICS_STEP_UP_DB do return freq
    }

    _, partial := score_stack(peaks, loudest.freq, top_hz)
    return partial
}

// A third or a half of freq that's the note: its own harmonics, the ones freq doesn't have, add up to
// HARMONICS_OWN_PERCENT of the best stack's score
note_under :: proc(peaks: []StackPeak, freq, score_db, lowest_hz, top_hz: f32) -> (lower: f32, found: bool) {
    for divisor in HARMONICS_DIVISORS {
        candidate := freq / f32(divisor)
        if candidate < lowest_hz do continue

        own, _ := score_stack(peaks, candidate, top_hz, skip_multiples_of = divisor)
        if own < f32(HARMONICS_OWN_PERCENT) / 100 * score_db do continue

        _, lower = score_stack(peaks, candidate, top_hz)
        return lower, true
    }
    return 0, false
}

// The levels up to the top bin and the background around each, see HARMONICS_BACKGROUND_HZ, further apart over
// top_hz. From a full scale sine's, a longer window's bins are larger, the two transforms' levels read alike.
measure_stack_background :: proc(self: ^StackTransform, top_hz: f32) {
    top_bin := self.top_bin
    span := len(self.around) / 2
    used := min(top_bin + span + 1, len(self.levels))

    // The first bin packs DC and Nyquist, see square_spectrum, it's under the highpass anyway
    full_scale_db := 20 * math.log10(self.spectrum.full_scale)
    self.levels[0] = -200
    for bin in 1 ..< used {
        self.levels[bin] = 10 * math.log10(max(real(self.spectrum.spectrum[bin]), 1e-20)) - full_scale_db
    }

    // The span held in at the ends, see select_nth
    background_at :: proc(levels, around: []f32, bin: int) -> f32 {
        start := clamp(bin - len(around) / 2, 0, len(levels) - len(around))
        copy(around, levels[start:])
        return select_nth(around, len(around) / 4) + HARMONICS_QUARTER_DB
    }

    levels := self.levels[:used]
    range_floor := slice.max(levels[1:top_bin]) - HARMONICS_RANGE_DB
    step := max(int(HARMONICS_BACKGROUND_STEP_HZ / self.bin_hz), 1)
    wide_from := int(top_hz / self.bin_hz)
    below_bin := 0
    below := max(background_at(levels, self.around, 0), range_floor)
    for below_bin < top_bin {
        bin_step := step if below_bin < wide_from else HARMONICS_BACKGROUND_STEPS_OVER_TOP * step
        above_bin := min(below_bin + bin_step, top_bin)
        above := max(background_at(levels, self.around, above_bin), range_floor)
        for bin in below_bin ..= above_bin {
            self.background[bin] = math.lerp(below, above, f32(bin - below_bin) / f32(above_bin - below_bin))
        }
        below_bin, below = above_bin, above
    }
}

// The value at nth were the values sorted, they're left partly sorted (Hoare's selection): each round splits the
// part nth is in around its middle value and keeps the side nth is on. Sorting the 65 bins around each background
// point took four fifths of the HARMONICS method's time.
select_nth :: proc(values: []f32, nth: int) -> f32 {
    low, high := 0, len(values) - 1
    for low < high {
        lower_end, upper_start := partition_around(values, low, high, values[(low + high) / 2])

        if nth <= lower_end {
            high = lower_end
        } else if nth >= upper_start {
            low = upper_start
        } else {
            break // between the two, on the pivot's own value
        }
    }
    return values[nth]
}

// The values from low to high swapped so the ones no higher than the pivot come first, up to lower_end, and the
// ones no lower than it last, from upper_start, the pivot's own value between (Hoare's partition)
partition_around :: proc(values: []f32, low, high: int, pivot: f32) -> (lower_end, upper_start: int) {
    left, right := low, high
    for left <= right {
        for values[left] < pivot {
            left += 1
        }
        for values[right] > pivot {
            right -= 1
        }

        if left <= right {
            values[left], values[right] = values[right], values[left]
            left += 1
            right -= 1
        }
    }
    return right, left
}

// The peaks HARMONICS_PEAK_DB over their background from just under lowest_hz to the top bin and clear of louder
// ones' sidelobes, the most prominent of them in each octave, low to high
find_stack_peaks :: proc(self: ^StackTransform, lowest_hz: f32, hop := 0) {
    first := max(int(freq_at_cents(lowest_hz, -HARMONICS_TOLERANCE_CENTS) / self.bin_hz), 1)
    collect_stack_peaks(self, first, hop)

    // The transform is zero padded, a bin of the window is two of its
    drop_sidelobes(&self.peaks, 2 * self.bin_hz)
    keep_most_prominent(&self.peaks, lowest_hz)
}

// The local maxima from first to the top bin HARMONICS_PEAK_DB over their background, refined between the bins.
// With HARMONICS_PHASE_STEADY each counts as far over its background as its phase is steady, see phase_steadiness.
collect_stack_peaks :: proc(self: ^StackTransform, first: int, hop := 0) {
    clear(&self.peaks)

    levels := self.levels
    for bin in first ..< self.top_bin {
        level := levels[bin]
        if level <= levels[bin - 1] || level < levels[bin + 1] do continue
        if level - self.background[bin] < HARMONICS_PEAK_DB do continue

        offset, peak_level := parabolic(levels[bin - 1], level, levels[bin + 1])
        peak := StackPeak {
            freq    = (f32(bin) + offset) * self.bin_hz,
            level   = peak_level,
            over_db = peak_level - self.background[bin],
        }
        when HARMONICS_PHASE_STEADY do peak.over_db *= phase_steadiness(self, bin, peak.freq, hop)

        append(&self.peaks, peak)
    }
}

// How steady a peak's phase is, 1 where its frequency says it would be and 0 a quarter turn or more off. Over
// hop samples since the detection before, a partial at freq goes on by that many of its periods, noise wanders.
// 1 without a detection before to go by.
phase_steadiness :: proc(self: ^StackTransform, bin: int, freq: f32, hop: int) -> f32 {
    if !self.has_previous || hop <= 0 do return 1

    sample_rate := self.bin_hz * f32(self.spectrum.fft_size)
    expected := math.TAU * f64(freq) * f64(hop) / f64(sample_rate)
    turned := f64(cmplx.phase(self.bins[bin])) - f64(cmplx.phase(self.previous_bins[bin]))
    return max(f32(math.cos(turned - expected)), 0)
}

// Loudest first, each peak kept unless one kept before leaks over it, see under_sidelobes
drop_sidelobes :: proc(peaks: ^[dynamic]StackPeak, window_bin_hz: f32) {
    slice.sort_by(peaks[:], proc(first, second: StackPeak) -> bool {return first.level > second.level})

    kept := 0
    for peak in peaks {
        if under_sidelobes(peaks[:kept], peak, window_bin_hz) do continue

        peaks[kept] = peak
        kept += 1
    }
    resize(peaks, kept)
}

// Whether the peak is in a louder one's main lobe or not far enough over its sidelobes, see
// HARMONICS_SIDELOBE_MARGIN_DB
under_sidelobes :: proc(louder: []StackPeak, peak: StackPeak, window_bin_hz: f32) -> bool {
    for other in louder {
        bins := abs(peak.freq - other.freq) / window_bin_hz
        if bins < HARMONICS_MAIN_LOBE_BINS do return true

        sidelobe := other.level - 10 - 60 * math.log10(bins)
        if peak.level < sidelobe + HARMONICS_SIDELOBE_MARGIN_DB do return true
    }
    return false
}

// The most prominent HARMONICS_PEAKS_PER_OCTAVE in each octave from lowest_hz up, low to high
keep_most_prominent :: proc(peaks: ^[dynamic]StackPeak, lowest_hz: f32) {
    slice.sort_by(peaks[:], proc(first, second: StackPeak) -> bool {return first.over_db > second.over_db})

    // The upper spectrum's peaks go up to 10 kHz, 7.6 octaves over its lowest candidate's 50 Hz, the lower
    // spectrum's to 517 Hz, 4.3 octaves over A0's. The peaks past the last octave count in it.
    kept_in_octave: [8]int
    kept := 0
    for peak in peaks {
        octave := clamp(int(math.log2(peak.freq / lowest_hz)), 0, len(kept_in_octave) - 1)
        if kept_in_octave[octave] == HARMONICS_PEAKS_PER_OCTAVE do continue

        kept_in_octave[octave] += 1
        peaks[kept] = peak
        kept += 1
    }
    resize(peaks, kept)

    slice.sort_by(peaks[:], proc(first, second: StackPeak) -> bool {return first.freq < second.freq})
}

// A candidate's first harmonics up to top_hz, its 2nd further, see HARMONICS_SECOND_REACH, each the most
// prominent peak close enough to it, see HARMONICS_TOLERANCE_CENTS: their dB over the background summed,
// weighted down the stack, and the fundamental they agree on, each harmonic's peak over its number weighted by
// the peak's power times its number squared.
// That's how much each partial pulls the whole wave's period: the correlation's peak is where their slopes
// cancel, and a partial's slope there is its power times its frequency times how far off it is. So the Blend
// readout reads the same mix of a string's sharp partials either way, an electric guitar's and a bass's low
// strings within 0.2 cents of the whole wave, an acoustic's 1 to 3 flat, its partials past the stack's count
// pull the whole wave too. Weighted by the dB over the background they read 2 to 4 cents flat of it and a bass
// 3 sharp, by the power alone up to 6 flat. Given skip_multiples_of, the harmonics that are multiples of it are
// left out, the ones a note that many times higher shares, for the candidate's own, see note_under.
//
// Given a score to beat and the most prominent peak's dB, it gives up with none once the harmonics still to come
// couldn't beat it, each as prominent as that peak.
score_stack :: proc(
    peaks: []StackPeak,
    candidate, top_hz: f32,
    skip_multiples_of := 0,
    score_to_beat: f32 = 0,
    most_db: f32 = 0,
) -> (
    score_db, fundamental: f32,
) {
    weight: f32 = 1
    weighted_freq, fundamental_pulls: f32
    weights_left := (1 - math.pow(f32(HARMONICS_WEIGHT), HARMONICS_COUNT)) / (1 - HARMONICS_WEIGHT)
    for harmonic in 1 ..= HARMONICS_COUNT {
        if score_to_beat > 0 && score_db + weights_left * most_db <= score_to_beat do return 0, 0

        target := f32(harmonic) * candidate
        if target > harmonic_top(harmonic, top_hz) do break

        skipped := skip_multiples_of > 0 && harmonic % skip_multiples_of == 0
        if !skipped {
            peak, counted_db := matching_peak(peaks, target, harmonic_tolerance(harmonic))
            score_db += weight * counted_db

            if peak.freq > 0 {
                fundamental_pull := math.pow(10, peak.level / 10) * f32(harmonic * harmonic)
                weighted_freq += fundamental_pull * peak.freq / f32(harmonic)
                fundamental_pulls += fundamental_pull
            }
        }
        weights_left -= weight
        weight *= HARMONICS_WEIGHT
    }

    if fundamental_pulls > 0 {
        fundamental = weighted_freq / fundamental_pulls
    }
    return
}

// The peak, low to high, that counts the most as the harmonic at target: its dB over the background, less the
// further off it is, none from tolerance_cents. None counts 0 dB.
matching_peak :: proc(peaks: []StackPeak, target, tolerance_cents: f32) -> (match: StackPeak, counted_db: f32) {
    low := freq_at_cents(target, -tolerance_cents)
    high := freq_at_cents(target, tolerance_cents)
    for peak in peaks {
        if peak.freq < low do continue
        if peak.freq > high do break

        off := cents_deviation(peak.freq, target) / tolerance_cents
        counted := peak.over_db * (1 - off * off)
        if counted > counted_db {
            match, counted_db = peak, counted
        }
    }
    return
}
