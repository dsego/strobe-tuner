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

// The most prominent peaks taken, a candidate is one of them as one of its first HARMONICS_COUNT harmonics
HARMONICS_MAX_PEAKS :: 40

// The harmonics a candidate counts, each this much of the one under it, a candidate an octave down has only
// every other one and its first ones are missing (Hermes' subharmonic summation). Each counts its whole dB, a
// sine is one harmonic and a note like any other.
HARMONICS_COUNT :: 10
HARMONICS_WEIGHT :: 0.84

// A peak is the harmonic this close to it, the more so the higher, a string's partials run sharp: a piano's
// low strings' 10th about 35 cents
HARMONICS_TOLERANCE_CENTS :: 30
HARMONICS_STRETCH_CENTS :: 3

// A low string's loud 3rd harmonic outscored its own stack at the attack, the fundamental and the 2nd still weak
// there: A1 read E3 and G2 read D4. A third or a half of the best is the note when its own harmonics, the ones the
// best doesn't have, add up to this percentage of the best's score. A note's own third or half finds only noise
// there. At 50 and 70 a few of the guitar's frames still read the 3rd or the 4th harmonic, the hum under a song
// lit the same at 30. E.g. -define:HARMONICS_OWN_PERCENT=n
HARMONICS_OWN_PERCENT :: #config(HARMONICS_OWN_PERCENT, 30)
HARMONICS_DIVISORS :: [2]int{3, 2}


HarmonicStack :: struct {
    spectrum:   WindowedSpectrum, // the detector's window under a Hann taper
    levels:     []f32, // dB of each bin
    background: []f32, // dB around each bin, see HARMONICS_BACKGROUND_HZ
    around:     []f32, // the bins around one, sorted for the quarter
    peaks:      [dynamic]StackPeak, // the most prominent ones, low to high
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

    // Every peak as each of a candidate's first harmonics, the stack that scores best
    for peak in self.peaks {
        for harmonic in 1 ..= HARMONICS_COUNT {
            candidate := peak.freq / f32(harmonic)
            if candidate < lowest_hz do break

            score, fundamental := score_stack(self.peaks[:], candidate, top_hz)
            if score > score_db do freq, score_db = fundamental, score
        }
    }

    // Down to a third or a half while that's the note, see HARMONICS_OWN_PERCENT. The score stays the best's,
    // how sure the stack is a note.
    for lowered := freq > 0; lowered; {
        lowered = false
        for divisor in HARMONICS_DIVISORS {
            lower := freq / f32(divisor)
            if lower < lowest_hz do continue

            own, _ := score_stack(self.peaks[:], lower, top_hz, skip = divisor)
            if own < f32(HARMONICS_OWN_PERCENT) / 100 * score_db do continue

            _, freq = score_stack(self.peaks[:], lower, top_hz)
            lowered = true
            break
        }
    }
    return
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

// The value at nth were the values sorted, they're left partly sorted (Hoare's selection). Sorting the 65 bins
// around each background point took four fifths of the HARMONICS method's time.
select_nth :: proc(values: []f32, nth: int) -> f32 {
    low, high := 0, len(values) - 1
    for low < high {
        pivot := values[(low + high) / 2]
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

        // Under the pivot up to right, over it from left, the pivot's own value between
        if nth <= right {
            high = right
        } else if nth >= left {
            low = left
        } else {
            break
        }
    }
    return values[nth]
}

// The peaks HARMONICS_PEAK_DB over their background from just under lowest_hz to top_bin and clear of louder
// ones' sidelobes, the most prominent HARMONICS_MAX_PEAKS of them, low to high
find_stack_peaks :: proc(self: ^HarmonicStack, bin_hz, lowest_hz: f32, top_bin: int) {
    clear(&self.peaks)

    first := max(int(freq_at_cents(lowest_hz, -HARMONICS_TOLERANCE_CENTS) / bin_hz), 1)
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

    // Loudest first, each kept unless one kept before leaks over it. The transform is zero padded, a bin of
    // the window is two of its.
    under_sidelobes :: proc(louder: []StackPeak, peak: StackPeak, window_bin_hz: f32) -> bool {
        for other in louder {
            bins := abs(peak.freq - other.freq) / window_bin_hz
            if bins < HARMONICS_MAIN_LOBE_BINS do return true

            sidelobe := other.level - 10 - 60 * math.log10(bins)
            if peak.level < sidelobe + HARMONICS_SIDELOBE_MARGIN_DB do return true
        }
        return false
    }

    slice.sort_by(self.peaks[:], proc(first, second: StackPeak) -> bool {return first.level > second.level})
    kept := 0
    for peak in self.peaks {
        if under_sidelobes(self.peaks[:kept], peak, 2 * bin_hz) do continue

        self.peaks[kept] = peak
        kept += 1
    }
    resize(&self.peaks, kept)

    if len(self.peaks) > HARMONICS_MAX_PEAKS {
        slice.sort_by(self.peaks[:], proc(first, second: StackPeak) -> bool {return first.over_db > second.over_db})
        resize(&self.peaks, HARMONICS_MAX_PEAKS)
    }
    slice.sort_by(self.peaks[:], proc(first, second: StackPeak) -> bool {return first.freq < second.freq})
}

// A candidate's first harmonics up to top_hz, each the most prominent peak close enough to it, see
// HARMONICS_TOLERANCE_CENTS: their dB over the background summed, weighted down the stack, and the fundamental
// they agree on, each harmonic's peak over its number weighted the same. Without every skip-th harmonic, the
// ones a candidate skip times higher shares, for the candidate's own, see run_harmonic_stack.
score_stack :: proc(peaks: []StackPeak, candidate, top_hz: f32, skip := 0) -> (score_db, fundamental: f32) {
    weight: f32 = 1
    weighted_freq: f32
    for harmonic in 1 ..= HARMONICS_COUNT {
        target := f32(harmonic) * candidate
        if target > top_hz do break

        if skip > 0 && harmonic % skip == 0 {
            weight *= HARMONICS_WEIGHT
            continue
        }

        tolerance := HARMONICS_TOLERANCE_CENTS + HARMONICS_STRETCH_CENTS * f32(harmonic)
        low := freq_at_cents(target, -tolerance)
        high := freq_at_cents(target, tolerance)

        best: StackPeak
        for peak in peaks {
            if peak.freq < low do continue
            if peak.freq > high do break
            if peak.over_db > best.over_db do best = peak
        }

        if best.over_db > 0 {
            counted := weight * best.over_db
            score_db += counted
            weighted_freq += counted * best.freq / f32(harmonic)
        }
        weight *= HARMONICS_WEIGHT
    }

    if score_db > 0 do fundamental = weighted_freq / score_db
    return
}
