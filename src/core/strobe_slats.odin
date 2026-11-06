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

// How bright a strobe track's stripes are, from the samples themselves. Each track's reference is cut into
// spans, a period of the note, as many of the track's own as its partial, two of the note's for a fifth, so
// every partial of the note goes whole periods in one. The track's partial is measured over windows of spans,
// one closing at the end of every span, and the stripes are as bright as the measurements agree, see
// strobe_slat_level. Tried on the slat-strobe branch instead of the SNR fade, see STROBE_SNR_FADE.

// How long the slots of STROBE_SLATS_HALVES remember, in periods of the note, they fade to a third over this many
STROBE_SLATS_PERIODS :: #config(STROBE_SLATS_PERIODS, 4.0)

// How long the measurements are remembered, in periods of the note, they fade to a third over this many. As
// steady as one span's measurements were over 4, the windows overlap, see SLAT_WINDOW_OVERLAP.
STROBE_SLATS_MEMORY_PERIODS :: #config(STROBE_SLATS_MEMORY_PERIODS, 7.0)

// Each measurement is a Blackman window over this many spans. One span alone let a 2nd partial 7 cents off into
// the 1× track 40 dB under it, louder than a low string's fundamental can be, and it turned so slowly from span
// to span that it looked steady. Over three, the window's main lobe reaches a note's frequency each way and every
// other partial of the note falls in its nulls.
SLAT_WINDOW_SPANS :: 3

// The measurements overlap, as many as this share as much noise as one, see test_slat_window_overlap
SLAT_WINDOW_OVERLAP :: 1.737

// How hard the noise pulls the stripes toward gray
STROBE_SLATS_SHADE :: #config(STROBE_SLATS_SHADE, 1.0)

// What's left of the stripes after the pull is multiplied by this: full where the partial's phase is uncertain by
// 0.16 radians or less, its average about 16 dB over the noise in its band, and dark at STROBE_SLATS_NOISE_RAD,
// the SNR fade's range. At 4 the fade was 2.5 dB wide, a partial near the noise blinked.
STROBE_SLATS_GAIN :: #config(STROBE_SLATS_GAIN, 1.67)

// Under this the slots are gray, in digital silence they'd keep the last note as they fade, every slot alike
STROBE_SLATS_SILENCE_DBFS :: -80

// The noise from the slots' two halves, as first tried, instead of the scatter of the partial from one period
// of the note to the next. The halves count the noise at every frequency, sample by sample, and it doesn't
// average down: a fading 4× partial let go 1.7 s before the SNR fade did.
STROBE_SLATS_HALVES :: #config(STROBE_SLATS_HALVES, false)

// The stripes are dark where the partial's average is this uncertain, in radians of its phase: the average 2.5
// times the noise in its band, about 8 dB, where the SNR fade ends
STROBE_SLATS_NOISE_RAD :: #config(STROBE_SLATS_NOISE_RAD, 0.4)

// The stripes are lit by the slots' level eased toward each frame's over this long, see update_band_levels.
// Decided afresh every frame from a few periods, a note where the noise starts to gray it flips between full
// and gray. As long as the SNR fade's, 0.1 s lit them later for no calmer look.
STROBE_SLATS_LEVEL_S :: #config(STROBE_SLATS_LEVEL_S, 0.05)

// Tried on the slat-strobe branch: true fades the stripes by the SNR instead, as on main, and the readout, the
// note hold, the trace, the onsets and the frame rate go by it too, to compare side by side
STROBE_SNR_FADE :: #config(STROBE_SNR_FADE, false)

SLAT_BINS :: 64 // along a period of a track's reference

// The most of a track's own periods its bins span, an 8× track's in a period of the note
SLAT_MAX_PERIODS :: 8
SLAT_FOLD_BINS :: SLAT_BINS * SLAT_MAX_PERIODS

StrobeSlats :: struct {
    positive: [MAX_BANDS][SLAT_FOLD_BINS]f32, // the positive half of the samples in each bin, summed and fading
    negative: [MAX_BANDS][SLAT_FOLD_BINS]f32, // the negative half's, by size
    weight:   [MAX_BANDS][SLAT_FOLD_BINS]f32, // how many samples, fading alike
    freq_hz:  [MAX_BANDS]f32, // the reference each track's bins were filled at, another starts them over
    periods:  [MAX_BANDS]int, // the track's own periods its bins span, see slat_fold_periods
    clock:    i64, // the lock-in's sample clock after the samples so far, a gap starts every track over

    // Per track, the windows still open and the closed ones' measurements, see add_slat_measurement
    open:         [MAX_BANDS]SlatWindows,
    measurements: [MAX_BANDS]SlatMeasurements,
}

// The windows still open. The first closes at the end of the span the latest sample fell in, the others a span
// and two spans later.
SlatWindows :: struct {
    windows: [SLAT_WINDOW_SPANS]SlatWindow,
    turn:    f64, // where in the span the latest sample fell, a smaller one starts the next
}

// The samples so far times the window and a cosine and a sine of the track's own period
SlatWindow :: struct {
    cosine: f64,
    sine:   f64,
    weight: f64, // the window's weights added up
    spans:  f64, // how much of the window the samples covered, whole at SLAT_WINDOW_SPANS
}

// The measurements summed, each fading by the note's periods since, see add_slat_measurement
SlatMeasurements :: struct {
    cosine:         f32,
    sine:           f32,
    power:          f32, // each one's squared size
    weight:         f32,
    weight_squared: f32, // how many measurements the sums are worth, weight² ÷ this
}

// The Blackman window at place, 0 to 1 across it
slat_window :: proc(place: f64) -> f64 {
    return slat_window_at(math.cos(math.TAU * place))
}

// The Blackman window from the cosine of how far across it a sample is, a turn across the whole window. Its
// second cosine is the first one's double angle, 2 cos² - 1.
slat_window_at :: #force_inline proc(cosine: f64) -> f64 {
    return 0.34 - 0.5 * cosine + 0.16 * cosine * cosine
}

// A point on the unit circle at angle radians, turned sample by sample instead of a cosine and a sine of each
phasor :: #force_inline proc(angle: f64) -> complex128 {
    return complex(math.cos(angle), math.sin(angle))
}

// A window closed, its partial as a sine's peak and phase, into the sums. The older ones fade by the note's
// periods since the one before, a span, and turn by as far as the partial turned in it, turned radians the way
// the measurements go: off the track's frequency it goes round steadily, that's the drift and not noise. Turned
// back with a long memory a note 10 cents sharp grayed its 4× track.
add_slat_measurement :: proc(sums: ^SlatMeasurements, cosine, sine: f32, note_periods: f32, turned: f32 = 0) {
    keep := math.exp(-note_periods / STROBE_SLATS_MEMORY_PERIODS)
    turn_cosine, turn_sine := math.cos(turned), math.sin(turned)
    sums.cosine, sums.sine =
        (sums.cosine * turn_cosine - sums.sine * turn_sine) * keep + cosine,
        (sums.sine * turn_cosine + sums.cosine * turn_sine) * keep + sine
    sums.power = sums.power * keep + cosine * cosine + sine * sine
    sums.weight = sums.weight * keep + 1
    sums.weight_squared = sums.weight_squared * keep * keep + 1
}

// As many of the track's own periods as fit a whole number of the note's, its partial or three for a fifth.
// Every vernier track is on the note.
slat_fold_periods :: proc(band: PhaseBand, mode: StrobeMode) -> int {
    if mode != .HARMONIC do return 1

    for note_periods in 1 ..= 4 {
        periods := band.interval * f32(note_periods)
        if abs(periods - math.round(periods)) < 0.01 do return clamp(int(math.round(periods)), 1, SLAT_MAX_PERIODS)
    }
    return clamp(int(math.round(band.interval)), 1, SLAT_MAX_PERIODS)
}

// The lock-in's new samples into every track's windows and bins, after run_phase_detection. A sample falls
// between two bins and they share it, like a dot of the scope's beam.
fill_strobe_slats :: proc(self: ^StrobeSlats, lock_in: ^StrobeLockIn) {
    new_samples := min(lock_in.available, lock_in.buffer_len)
    if new_samples <= 0 do return

    samples := lock_in.sample_buffer[lock_in.buffer_len - new_samples:lock_in.buffer_len]
    first := lock_in.sample_clock - i64(new_samples) // the absolute index of samples[0]

    // A stall, a reset or skipped samples, the bins' phases don't carry on
    if first != self.clock do self^ = {}
    self.clock = lock_in.sample_clock

    for band, index in lock_in.bands {
        if index >= MAX_BANDS do break

        positive, negative, weight := &self.positive[index], &self.negative[index], &self.weight[index]
        periods := slat_fold_periods(band, lock_in.mode)
        if self.freq_hz[index] != band.freq_hz || self.periods[index] != periods {
            positive^, negative^, weight^ = {}, {}, {}
            self.open[index], self.measurements[index] = {}, {}
            self.freq_hz[index] = band.freq_hz
            self.periods[index] = periods
        }
        if !band.in_range do continue

        // The bins faded by the note's periods over the new samples, once a frame
        when STROBE_SLATS_HALVES {
            bins := SLAT_BINS * periods
            elapsed_s := f32(new_samples) / lock_in.sample_rate
            keep := math.exp(-elapsed_s * lock_in.base_freq_hz / STROBE_SLATS_PERIODS)
            for bin in 0 ..< bins {
                positive[bin] *= keep
                negative[bin] *= keep
                weight[bin] *= keep
            }
        }

        // The span, in its own turns, of the first new sample and a sample's step. The note's periods in a span,
        // and how far the partial turns in one by the lock-in's phase advance over the new samples, as the stripes
        // move: a sine measured against a cosine and a sine of the track's own goes round the other way. Not the
        // drift, it follows over tenths of a second, a note stepping 55 cents grayed the stripes for a moment.
        step := f64(band.freq_hz) / f64(lock_in.sample_rate) / f64(periods)
        start := math.mod(f64(first) * step, 1)
        span_note_periods := f32(periods) * lock_in.base_freq_hz / band.freq_hz
        advance_per_sample := f64(band.phase_diff) / strobe_rescale(band.freq_hz) / f64(max(lock_in.available, 1))
        span_turned := -f32(advance_per_sample / step)
        open := &self.open[index]

        // The track's angle and the windows' turned sample by sample, see phasor, and set exactly again where a
        // span starts. The track's goes whole turns in a span, the windows' a third of one, each window a third
        // further along than the one opened after it.
        track_step := phasor(math.TAU * f64(periods) * step)
        window_step := phasor(math.TAU * step / SLAT_WINDOW_SPANS)
        window_offsets: [SLAT_WINDOW_SPANS]complex128
        for &window_offset, later in window_offsets {
            window_offset = phasor(math.TAU * f64(SLAT_WINDOW_SPANS - 1 - later) / SLAT_WINDOW_SPANS)
        }
        track_turn := phasor(math.TAU * f64(periods) * start)
        window_turn := phasor(math.TAU * start / SLAT_WINDOW_SPANS)

        for sample, offset in samples {
            turn := start + f64(offset) * step
            place := turn - math.floor(turn)

            // A span ends where the next starts over. The first window closes, measured if it was whole, not one
            // cut by a reset, and the next one opens.
            if place < open.turn {
                closing := open.windows[0]
                if closing.spans > SLAT_WINDOW_SPANS - 0.1 {
                    cosine := f32(2 * closing.cosine / closing.weight)
                    sine := f32(2 * closing.sine / closing.weight)
                    add_slat_measurement(&self.measurements[index], cosine, sine, span_note_periods, span_turned)
                }
                copy(open.windows[:], open.windows[1:])
                open.windows[SLAT_WINDOW_SPANS - 1] = {}

                track_turn = phasor(math.TAU * f64(periods) * place)
                window_turn = phasor(math.TAU * place / SLAT_WINDOW_SPANS)
            }
            open.turn = place

            // Into each open window at its own place, the first one's last span
            cosine, sine := f64(sample) * real(track_turn), f64(sample) * imag(track_turn)
            for &window, later in open.windows {
                window_weight := slat_window_at(real(window_turn * window_offsets[later]))
                window.cosine += window_weight * cosine
                window.sine += window_weight * sine
                window.weight += window_weight
                window.spans += step
            }
            track_turn *= track_step
            window_turn *= window_step

            when STROBE_SLATS_HALVES {
                position := place * f64(bins)
                lower := int(position) % bins
                upper := (lower + 1) % bins
                upper_share := f32(position - math.floor(position))
                rise, fall := max(sample, 0), max(-sample, 0)

                positive[lower] += (1 - upper_share) * rise
                positive[upper] += upper_share * rise
                negative[lower] += (1 - upper_share) * fall
                negative[upper] += upper_share * fall
                weight[lower] += 1 - upper_share
                weight[upper] += upper_share
            }
        }
    }
}

// Every track's level from its slots after fill_strobe_slats, and how lit its stripes are, the level eased
// over the new samples. Dark all the way in the end, a dark strobe's glow is drawn again as it was.
update_band_levels :: proc(self: ^StrobeLockIn) {
    elapsed_s := f32(self.available) / self.sample_rate
    ease := 1 - math.exp(-elapsed_s / STROBE_SLATS_LEVEL_S)

    for &band, index in self.bands {
        if index >= MAX_BANDS do break

        band.slat_level = strobe_slat_level(&self.slats, index) if band.in_range else 0
        band.visibility += ease * (band.slat_level - band.visibility)
        if band.slat_level == 0 && band.visibility < 0.001 do band.visibility = 0
    }
}

// How bright one track's stripes are, 0 gray to 1 full: how sure the partial's average over the measurements
// is. Each window measures the partial, the note's other partials fall in its nulls. The measurements scatter
// around their average by the noise near the track's own frequency, and the average is as uncertain as that
// scatter over how many measurements it holds, in radians of its phase near enough. Gray at
// STROBE_SLATS_NOISE_RAD, as much of the way as STROBE_SLATS_GAIN allows. All gray before two measurements' worth
// came in and in silence. With STROBE_SLATS_HALVES the noise is the slots' two halves instead, see
// slat_halves_level.
strobe_slat_level :: proc(self: ^StrobeSlats, band_index: int) -> f32 {
    when STROBE_SLATS_HALVES {
        return slat_halves_level(self, band_index)
    } else {
        sums := self.measurements[band_index]
        count := sums.weight * sums.weight / sums.weight_squared if sums.weight_squared > 0 else 0
        if count < 2 * SLAT_WINDOW_OVERLAP do return 0

        cosine, sine := sums.cosine / sums.weight, sums.sine / sums.weight
        height := math.sqrt(cosine * cosine + sine * sine)
        if height <= 0 || 20 * math.log10(height) < STROBE_SLATS_SILENCE_DBFS do return 0

        // The measurements' scatter around their average. Neighbours share noise, the scatter is smaller than one
        // measurement's noise by SLAT_WINDOW_OVERLAP of count, and the average holds count / SLAT_WINDOW_OVERLAP
        // measurements' worth. With no overlap it's the scatter over count - 1.
        spread := max(sums.power / sums.weight - height * height, 0)
        uncertainty := math.sqrt(spread * SLAT_WINDOW_OVERLAP / (count - SLAT_WINDOW_OVERLAP)) / height
        return min(STROBE_SLATS_GAIN * max(1 - STROBE_SLATS_SHADE * uncertainty / STROBE_SLATS_NOISE_RAD, 0), 1)
    }
}

// The level from the slots' two halves. The track's own wave is its periods in the slots added up: the note's
// partials that aren't the track's multiples cancel, the 2× track keeps the 2×, 4×, 6×. Its partial alone is
// the wave times a cosine and a sine of one period added up, a DFT bin, how high it is the size of that. The
// stripes are pulled toward gray by the noise, what lands on both halves of a slot averaged over the track, as
// much as it weighs against the partial, then STROBE_SLATS_GAIN.
slat_halves_level :: proc(self: ^StrobeSlats, band_index: int) -> f32 {
    positive, negative, weight := &self.positive[band_index], &self.negative[band_index], &self.weight[band_index]
    periods := max(self.periods[band_index], 1)

    // Each half's average in a bin, the wave's periods averaged into one, and the noise over all of them
    wave: [SLAT_BINS]f32
    noise: f32 = 0
    filled := 0
    for bin in 0 ..< SLAT_BINS * periods {
        if weight[bin] <= 0 do continue

        rise := positive[bin] / weight[bin]
        fall := negative[bin] / weight[bin]
        wave[bin % SLAT_BINS] += (rise - fall) / f32(periods)
        noise += min(rise, fall)
        filled += 1
    }
    if filled > 0 do noise /= f32(filled)

    cosine_sum, sine_sum: f32
    for value, bin in wave {
        angle := math.TAU * f32(bin) / SLAT_BINS
        cosine_sum += value * math.cos(angle)
        sine_sum += value * math.sin(angle)
    }

    // A sine's peak, a cosine's square sums to half the bins
    height := 2 * math.sqrt(cosine_sum * cosine_sum + sine_sum * sine_sum) / SLAT_BINS
    if height <= 0 || 20 * math.log10(height) < STROBE_SLATS_SILENCE_DBFS do return 0

    return min(STROBE_SLATS_GAIN * max(1 - STROBE_SLATS_SHADE * noise / height, 0), 1)
}
