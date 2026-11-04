// Copyright (C) 2025  Davorin Šego

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


/* -------------------------------------------------------------------------------------------------

    Pitch detection based on the NSDF, the normalized square difference function (McLeod Pitch Method)

    https://www.researchgate.net/publication/230554927_A_smarter_way_to_find_pitch

------------------------------------------------------------------------------------------------- */


package core

import "base:intrinsics"
import "core:math"
import "core:mem"
import "core:simd"

import fft "../../external/extreme_fft"

// The buffers of the NSDF and the peaks it found last
NSDF :: struct {
    plan:           fft.Quad_Plan, // both transforms of nsdf_autocorrelate
    fft_size:       int,
    sample_rate:    f32, // a lag's frequency
    bins_re:        []f32, // the padded samples' bins, real parts, DC in the first
    bins_im:        []f32, // their imaginary parts, Nyquist in the first
    power:          []f32, // the power of all fft_size bins over fft_size, the upper half the lower mirrored
    autocorr:       []f32, // the autocorrelation of each lag
    autocorr_im:    []f32, // the second transform's imaginary parts, nothing but rounding
    values:         []f32, // the NSDF of each lag
    padded_samples: []f32,
    peaks:          [dynamic]Vec2, // lag and NSDF value of each key maximum
    ratio_peak:     int, // in peaks, the first close enough to the highest, -1 for none
    chosen_peak:    int, // in peaks, the ratio_peak or the followed pitch's held over it, -1 for none
}


init_nsdf :: proc(fft_size: int, sample_rate: f32) -> (self: NSDF) {
    self.fft_size = fft_size
    self.sample_rate = sample_rate
    self.plan = fft.create_quad_plan(fft_size)

    // A real transform of fft_size samples has fft_size / 2 bins, see nsdf_autocorrelate
    self.bins_re = make([]f32, fft_size / 2)
    self.bins_im = make([]f32, fft_size / 2)
    self.power = make([]f32, fft_size)
    self.autocorr = make([]f32, fft_size / 2)
    self.autocorr_im = make([]f32, fft_size / 2)
    self.values = make([]f32, fft_size / 2)
    self.padded_samples = make([]f32, fft_size)
    return
}

destroy_nsdf :: proc(self: ^NSDF) {
    fft.destroy_quad_plan(&self.plan)
    delete(self.bins_re)
    delete(self.bins_im)
    delete(self.power)
    delete(self.autocorr)
    delete(self.autocorr_im)
    delete(self.values)
    delete(self.padded_samples)
    delete(self.peaks)
}

// The frequency of the chosen peak, 0 for none, and the peak, its lag and NSDF value. Down to lowest_hz, a
// longer period is no note, see nsdf_key_maxima. followed_hz is the pitch the tuner follows, 0 for none, its
// period holds against a longer one, see nsdf_choose_peak.
run_nsdf :: proc(self: ^NSDF, samples: []f32, lowest_hz: f32, followed_hz: f32 = 0) -> (freq: f32, peak: Vec2) {
    // A whole window, find_peak looks at every lag
    assert(len(samples) == len(self.values))

    nsdf_autocorrelate(self, samples)
    nsdf_normalize(self, samples)
    highest := nsdf_key_maxima(self, self.sample_rate / lowest_hz)

    followed_lag: f32 = 0
    if followed_hz > 0 do followed_lag = self.sample_rate / followed_hz

    peak = nsdf_choose_peak(self, highest, followed_lag)
    if peak.x > 0 do freq = self.sample_rate / peak.x

    return
}

// The NSDF through the autocorrelation, the left-hand sum of the squares runs down as the lag grows.
// The sum is kept in f64, in f32 thousands of subtractions drift it at the far lags. Past half the window
// it's only the energy outside the middle, a click in digital silence leaves it at the FFT's rounding,
// about a millionth of the whole, and rounding over rounding isn't bounded by 1.
nsdf_normalize :: proc(self: ^NSDF, samples: []f32) {
    count := len(samples)
    copy(self.values, self.autocorr[:count])

    squares := 2.0 * f64(self.values[0])
    least := 1e-5 * squares
    for lag in 0 ..< count {
        if squares > least {
            self.values[lag] *= f32(2.0 / squares)
            mirrored := samples[count - lag - 1]
            squares -= f64(samples[lag] * samples[lag]) + f64(mirrored * mirrored)
        } else {
            self.values[lag] = 0.0
        }
    }
}

// Lower maxima are no period, the NSDF of the zero lag is 1
NSDF_MIN_PEAK_VALUE :: 0.5

// The first of the key maxima this close to the highest is the period, not a multiple of it. A hum's cycles
// alternate a little, every other one matches better, its period's maximum read 0.85 to 0.91 two periods out
// and the detection dropped an octave. On a 40 s hum a pitch under 80 Hz on 534 detections at 0.95, 360 at
// 0.9 and 274 at 0.85. At 0.8 a guitar's Bb3 read an octave up and 8 recordings failed, at 0.85 to 0.95 none
// and the generated tones the same. E.g. -define:NSDF_CHOSEN_RATIO=n
NSDF_CHOSEN_RATIO :: #config(NSDF_CHOSEN_RATIO, 0.9)

// The pitch the tuner follows keeps its period against a longer one while its maximum is this close to the
// highest, see nsdf_choose_peak. A steady octave beats one that flips, even the wrong one: a missing
// fundamental is there in the sound. The hum's drops under 80 Hz went from 360 to 270 at 0.8, 254 at 0.7 and
// 250 at 0.6, most of the rest while no note was lit and nothing followed. The recordings and the generated
// tones read the same. E.g. -define:NSDF_HOLD_RATIO=n
NSDF_HOLD_RATIO :: #config(NSDF_HOLD_RATIO, 0.7)

// The key maxima into self.peaks, the highest between two zero crossings, refined between the lags. Returns
// the highest of them.
//
// Up to the longest period, in lags, and no further: a longer one is no note, and the far lags rest on few
// samples. Searched to the window's last 16th, under a song their maxima at 12 to 26 Hz reached 0.93 and a
// hum's own period fell short of NSDF_CHOSEN_RATIO of them. A0's period is under half the window at any rate.
// The end is two lags past it, the maximum at its lag is compared with the next one.
nsdf_key_maxima :: proc(self: ^NSDF, longest_period: f32) -> (highest_peak: Vec2) {
    clear(&self.peaks)
    end := min(int(math.ceil(longest_period)) + 2, len(self.values))

    lag := 1
    for lag < end {
        // Down the first slope, then past the negative values
        for lag < end && self.values[lag] > 0.0 do lag += 1
        for lag < end && self.values[lag] <= 0.0 do lag += 1

        // The highest local maximum while it's positive
        start := lag
        highest := lag
        for lag < end - 1 && self.values[lag] > 0.0 {
            value := self.values[lag]
            if value > self.values[highest] && value > self.values[lag + 1] && value > NSDF_MIN_PEAK_VALUE {
                highest = lag
            }
            lag += 1
        }

        if highest > start {
            offset, value := parabolic(self.values[highest - 1], self.values[highest], self.values[highest + 1])
            peak := Vec2{f32(highest) + offset, value}
            append(&self.peaks, peak)
            if value >= highest_peak.y do highest_peak = peak
        }
        lag += 1
    }
    return
}

// The first of the key maxima close to the highest one, the period and not a multiple of it. None is zero.
//
// A period longer than the followed one's, its lag followed_lag, is a drop: the followed period's maximum is
// kept while it's NSDF_HOLD_RATIO of the highest. A rise is taken as it is, a note an octave up repeats as well
// over two of its periods and a hold that way kept the octave below for as long as the note stayed lit.
nsdf_choose_peak :: proc(self: ^NSDF, highest_peak: Vec2, followed_lag: f32 = 0) -> Vec2 {
    self.ratio_peak = -1
    for peak, index in self.peaks {
        if peak.y >= NSDF_CHOSEN_RATIO * highest_peak.y {
            self.ratio_peak = index
            break
        }
    }
    self.chosen_peak = self.ratio_peak
    if self.chosen_peak < 0 do return {}

    chosen := self.peaks[self.chosen_peak]
    if followed_lag > 0 && lag_cents(chosen.x, followed_lag) > NOTE_HOLD_CENTS {
        for peak, index in self.peaks {
            near := abs(lag_cents(peak.x, followed_lag)) <= NOTE_HOLD_CENTS
            if near && peak.y >= NSDF_HOLD_RATIO * highest_peak.y {
                self.chosen_peak = index
                return peak
            }
        }
    }
    return chosen
}

// How many cents lower a period of lag samples is than one of reference samples
lag_cents :: proc(lag, reference: f32) -> f32 {
    return 1200 * math.log2(lag / reference)
}


// The cyclic autocorrelation of the zero padded samples: the FFT, the power of each bin, and back. The power
// spectrum of real samples is real and even, power[N - k] = power[k], and of such a sequence the inverse
// transform is the forward one over N, which the power already has. So both transforms are forward ones,
// the second's real parts the lags.
nsdf_autocorrelate :: proc(self: ^NSDF, samples: []f32) {
    assert(len(samples) <= self.fft_size / 2)
    n := self.fft_size
    half := n / 2

    // Zero padded to twice the length, the cyclic correlation doesn't wrap around onto the samples
    copy(self.padded_samples, samples)
    mem.zero_slice(self.padded_samples[len(samples):])

    fft.run_quad_arrays(&self.plan, self.padded_samples, self.bins_re, self.bins_im)

    // |X[k]|² / N, and the same from the top down. DC and Nyquist come in the first bin, both real. Four
    // bins at a time from 4, the mirrored ones turned around: as a loop over single bins the compiler
    // left it scalar for the writes going down, a fifth of the whole.
    scale := 1 / f32(n)
    re, im, power := self.bins_re, self.bins_im, self.power
    power[0] = scale * re[0] * re[0]
    power[half] = scale * im[0] * im[0]
    for k in 1 ..< 4 {
        power[k] = scale * (re[k] * re[k] + im[k] * im[k])
        power[n - k] = power[k]
    }
    scale4 := #simd[4]f32{scale, scale, scale, scale}
    for k := 4; k < half; k += 4 {
        r := intrinsics.unaligned_load(cast(^#simd[4]f32)&re[k])
        i := intrinsics.unaligned_load(cast(^#simd[4]f32)&im[k])
        p := scale4 * (r * r + i * i)
        intrinsics.unaligned_store(cast(^#simd[4]f32)&power[k], p)
        intrinsics.unaligned_store(cast(^#simd[4]f32)&power[n - k - 3], simd.swizzle(p, 3, 2, 1, 0))
    }

    // Lag 0 in the DC bin, the lags up to N/2 in the real parts after it
    fft.run_quad_arrays(&self.plan, power, self.autocorr, self.autocorr_im)
}

// Times the conjugate, the power spectrum in place. The transform packs the two real bins, DC and Nyquist,
// into the first element as (DC, Nyquist), each is squared on its own.
square_spectrum :: proc(spectrum: []complex64) {
    dc_nyquist := spectrum[0]
    spectrum[0] = complex(real(dc_nyquist) * real(dc_nyquist), imag(dc_nyquist) * imag(dc_nyquist))
    for &bin in spectrum[1:] {
        bin = complex(real(bin) * real(bin) + imag(bin) * imag(bin), 0)
    }
}

// Parabolic interpolation to find the more accurate peak location, its offset from the middle point and value
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc(before: f32, middle: f32, after: f32) -> (offset: f32, value: f32) {
    offset = 0.5 * (before - after) / (before - 2.0 * middle + after)
    value = middle - 0.25 * (before - after) * offset
    return
}
