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

// The background no lower than this under the loudest peak, a microphone's own noise is closer under a note.
// Over a generated tone's digital silence a partial 90 dB down stood out as far as a loud one: a triangle wave's
// aliases made up a stack of their own and read Bb4 for A2. Over HARMONICS_HIGH_DB, a sine stays strong.
HARMONICS_RANGE_DB :: 70

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

// A low string's loud 3rd harmonic outscored its own stack at the attack, the fundamental and the 2nd still weak
// there: A1 read E3 and G2 read D4. A third or a half of the best is the note when its own harmonics, the ones the
// best doesn't have, add up to this percentage of the best's score. A note's own third or half finds only noise
// there. At 50 and 70 a few of the guitar's frames still read the 3rd or the 4th harmonic, the hum under a song
// lit the same at 30. A fifth and a seventh too took a low square from its 7th harmonic to the note, and the
// ukulele's G3 and G#3 a few detections under theirs. E.g. -define:HARMONICS_OWN_PERCENT=n
HARMONICS_OWN_PERCENT :: #config(HARMONICS_OWN_PERCENT, 30)
HARMONICS_DIVISORS :: [2]int{3, 2}


HarmonicStack :: struct {
    spectrum:   WindowedSpectrum, // the detector's window under a Hann taper
    levels:     []f32, // dB of each bin
    background: []f32, // dB around each bin, see HARMONICS_BACKGROUND_HZ
    around:      []f32, // the bins around one, sorted for the quarter
    peaks:       [dynamic]StackPeak, // the most prominent ones, low to high
    previous_hz: f32, // the best stack's fundamental the detection before, see best_stack
    harmonics:   [HARMONICS_COUNT]StackPeak, // the note's stack, each harmonic's peak, 0 Hz for none
    score_db:    f32, // the latest detection's, see run_harmonic_stack
}

StackPeak :: struct {
    freq:    f32,
    level:   f32, // dB
    over_db: f32, // over the background
}

init_harmonic_stack :: proc(window: int, sample_rate: f32) -> (self: HarmonicStack) {
    self.spectrum = init_windowed_spectrum(window)
    self.levels = make([]f32, len(self.spectrum.spectrum))
    self.background = make([]f32, len(self.spectrum.spectrum))

    bin_hz := sample_rate / f32(self.spectrum.fft_size)
    self.around = make([]f32, 2 * int(HARMONICS_BACKGROUND_HZ / bin_hz) + 1)
    return
}

destroy_harmonic_stack :: proc(self: ^HarmonicStack) {
    destroy_windowed_spectrum(&self.spectrum)
    delete(self.levels)
    delete(self.background)
    delete(self.around)
    delete(self.peaks)
}

// The best stack's fundamental from lowest_hz up, 0 for none, and its harmonics' dB over their background
// summed, weighted down the stack. The peaks are looked for up to top_hz, the detector's low-pass, and a
// stack's fundamental may be up there too: the detector tells a pitch over its notes from a note, a D8 sine
// taken only as far as C8 read D7, its 2nd harmonic.
run_harmonic_stack :: proc(
    self: ^HarmonicStack,
    samples: []f32,
    sample_rate, lowest_hz, top_hz: f32,
) -> (
    freq, score_db: f32,
) {
    copy(self.spectrum.samples, samples)
    run_windowed_spectrum(&self.spectrum)

    bin_hz := sample_rate / f32(self.spectrum.fft_size)
    top_bin := min(int(top_hz / bin_hz), len(self.levels) - 2)
    measure_stack_background(self, bin_hz, top_bin)
    find_stack_peaks(self, bin_hz, lowest_hz, top_bin)

    // The score stays the best stack's, how sure it is a note
    freq, score_db = best_stack(self, lowest_hz, top_hz)
    freq = step_down_to_note(self.peaks[:], freq, score_db, lowest_hz, top_hz)
    self.harmonics = stack_harmonics(self.peaks[:], freq, top_hz)
    self.score_db = score_db
    return
}

// Each of the fundamental's first harmonics up to top_hz, the peak score_stack counts for it, 0 Hz for none
stack_harmonics :: proc(peaks: []StackPeak, fundamental, top_hz: f32) -> (harmonics: [HARMONICS_COUNT]StackPeak) {
    if fundamental <= 0 do return

    for &peak, index in harmonics {
        harmonic := index + 1
        target := f32(harmonic) * fundamental
        if target > top_hz do break

        peak, _ = matching_peak(peaks, target, harmonic_tolerance(harmonic))
    }
    return
}

// How far a harmonic's peak may be from it, see HARMONICS_TOLERANCE_CENTS
harmonic_tolerance :: proc(harmonic: int) -> f32 {
    return HARMONICS_TOLERANCE_CENTS + HARMONICS_STRETCH_CENTS * f32(harmonic)
}

// Every peak as each of a candidate's first harmonics, the stack that scores best: its fundamental, 0 for none,
// and its score. The one nearest the detection before's goes first: through a held note it's the best again,
// and the others are given up on as soon as they can't beat it, see score_stack. A strummed chord's took a
// quarter less time, and every pitch and score came out the same.
best_stack :: proc(self: ^HarmonicStack, lowest_hz, top_hz: f32) -> (freq, score_db: f32) {
    peaks := self.peaks[:]
    most_db: f32
    for peak in peaks do most_db = max(most_db, peak.over_db)

    if nearest := nearest_candidate(peaks, self.previous_hz, lowest_hz); nearest > 0 {
        score_db, freq = score_stack(peaks, nearest, top_hz)
    }

    for peak in peaks {
        for harmonic in 1 ..= HARMONICS_COUNT {
            candidate := peak.freq / f32(harmonic)
            if candidate < lowest_hz do break

            score, fundamental := score_stack(peaks, candidate, top_hz, beat = score_db, most_db = most_db)
            if score > score_db do freq, score_db = fundamental, score
        }
    }

    self.previous_hz = freq
    return
}

// The candidate nearest freq, one of the peaks over one of its first HARMONICS_COUNT harmonics, 0 for none
nearest_candidate :: proc(peaks: []StackPeak, freq, lowest_hz: f32) -> (nearest: f32) {
    if freq <= 0 do return

    closest := max(f32)
    for peak in peaks {
        harmonic := clamp(math.round(peak.freq / freq), 1, HARMONICS_COUNT)
        candidate := peak.freq / harmonic
        if candidate < lowest_hz do continue

        cents := abs(cents_deviation(candidate, freq))
        if cents < closest do nearest, closest = candidate, cents
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

// A third or a half of freq that's the note: its own harmonics, the ones freq doesn't have, add up to
// HARMONICS_OWN_PERCENT of the best stack's score
note_under :: proc(peaks: []StackPeak, freq, score_db, lowest_hz, top_hz: f32) -> (lower: f32, found: bool) {
    for divisor in HARMONICS_DIVISORS {
        candidate := freq / f32(divisor)
        if candidate < lowest_hz do continue

        own, _ := score_stack(peaks, candidate, top_hz, skip = divisor)
        if own < f32(HARMONICS_OWN_PERCENT) / 100 * score_db do continue

        _, lower = score_stack(peaks, candidate, top_hz)
        return lower, true
    }
    return 0, false
}

// The levels up to top_bin and the background around each, see HARMONICS_BACKGROUND_HZ
measure_stack_background :: proc(self: ^HarmonicStack, bin_hz: f32, top_bin: int) {
    span := len(self.around) / 2
    used := min(top_bin + span + 1, len(self.levels))

    // The first bin packs DC and Nyquist, see square_spectrum, it's under the highpass anyway
    self.levels[0] = -200
    for bin in 1 ..< used {
        self.levels[bin] = 10 * math.log10(max(real(self.spectrum.spectrum[bin]), 1e-20))
    }

    // The span held in at the ends, see select_nth
    background_at :: proc(levels, around: []f32, bin: int) -> f32 {
        start := clamp(bin - len(around) / 2, 0, len(levels) - len(around))
        copy(around, levels[start:])
        return select_nth(around, len(around) / 4) + HARMONICS_QUARTER_DB
    }

    levels := self.levels[:used]
    range_floor := slice.max(levels[1:top_bin]) - HARMONICS_RANGE_DB
    step := max(int(HARMONICS_BACKGROUND_STEP_HZ / bin_hz), 1)
    below_bin := 0
    below := max(background_at(levels, self.around, 0), range_floor)
    for below_bin < top_bin {
        above_bin := min(below_bin + step, top_bin)
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
        for values[left] < pivot do left += 1
        for values[right] > pivot do right -= 1

        if left <= right {
            values[left], values[right] = values[right], values[left]
            left += 1
            right -= 1
        }
    }
    return right, left
}

// The peaks HARMONICS_PEAK_DB over their background from just under lowest_hz to top_bin and clear of louder
// ones' sidelobes, the most prominent of them in each octave, low to high
find_stack_peaks :: proc(self: ^HarmonicStack, bin_hz, lowest_hz: f32, top_bin: int) {
    first := max(int(freq_at_cents(lowest_hz, -HARMONICS_TOLERANCE_CENTS) / bin_hz), 1)
    collect_stack_peaks(self, bin_hz, first, top_bin)

    // The transform is zero padded, a bin of the window is two of its
    drop_sidelobes(&self.peaks, 2 * bin_hz)
    keep_most_prominent(&self.peaks, lowest_hz)
}

// The local maxima from first to top_bin HARMONICS_PEAK_DB over their background, refined between the bins
collect_stack_peaks :: proc(self: ^HarmonicStack, bin_hz: f32, first, top_bin: int) {
    clear(&self.peaks)

    levels := self.levels
    for bin in first ..< top_bin {
        level := levels[bin]
        if level <= levels[bin - 1] || level < levels[bin + 1] do continue
        if level - self.background[bin] < HARMONICS_PEAK_DB do continue

        offset, peak_level := parabolic(levels[bin - 1], level, levels[bin + 1])
        peak := StackPeak {
            freq    = (f32(bin) + offset) * bin_hz,
            level   = peak_level,
            over_db = peak_level - self.background[bin],
        }
        append(&self.peaks, peak)
    }
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

    // The detector's low-pass is 7.5 octaves over A0, the peaks just under it count in the first
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

// A candidate's first harmonics up to top_hz, each the most prominent peak close enough to it, see
// HARMONICS_TOLERANCE_CENTS: their dB over the background summed, weighted down the stack, and the fundamental
// they agree on, each harmonic's peak over its number weighted by the peak's power times its number squared.
// That's how much each partial pulls the whole wave's period: the correlation's peak is where their slopes
// cancel, and a partial's slope there is its power times its frequency times how far off it is. So the Blend
// readout reads the same mix of a string's sharp partials either way, an electric guitar's and a bass's low
// strings within 0.2 cents of the whole wave, an acoustic's 1 to 3 flat, its partials past the stack's count
// pull the whole wave too. Weighted by the dB over the background they read 2 to 4 cents flat of it and a bass
// 3 sharp, by the power alone up to 6 flat. Without every skip-th harmonic, the ones a candidate skip times
// higher shares, for the candidate's own, see note_under.
//
// Given a score to beat and the most prominent peak's dB, it gives up with none once the harmonics still to come
// couldn't beat it, each as prominent as that peak.
score_stack :: proc(
    peaks: []StackPeak,
    candidate, top_hz: f32,
    skip := 0,
    beat: f32 = 0,
    most_db: f32 = 0,
) -> (
    score_db, fundamental: f32,
) {
    weight: f32 = 1
    weighted_freq, pulls: f32
    weights_left := (1 - math.pow(f32(HARMONICS_WEIGHT), HARMONICS_COUNT)) / (1 - HARMONICS_WEIGHT)
    for harmonic in 1 ..= HARMONICS_COUNT {
        if beat > 0 && score_db + weights_left * most_db <= beat do return 0, 0

        target := f32(harmonic) * candidate
        if target > top_hz do break

        shared := skip > 0 && harmonic % skip == 0
        if !shared {
            peak, counted_db := matching_peak(peaks, target, harmonic_tolerance(harmonic))
            score_db += weight * counted_db

            if peak.freq > 0 {
                pull := math.pow(10, peak.level / 10) * f32(harmonic * harmonic)
                weighted_freq += pull * peak.freq / f32(harmonic)
                pulls += pull
            }
        }
        weights_left -= weight
        weight *= HARMONICS_WEIGHT
    }

    if pulls > 0 do fundamental = weighted_freq / pulls
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
        if counted > counted_db do match, counted_db = peak, counted
    }
    return
}
