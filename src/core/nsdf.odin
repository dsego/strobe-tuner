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
    chosen_peak:    int, // in peaks, -1 for none
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

// The frequency of the chosen peak, 0 for none, and the peak, its lag and NSDF value
run_nsdf :: proc(self: ^NSDF, samples: []f32) -> (freq: f32, peak: Vec2) {
    // A whole window, find_peak looks at every lag
    assert(len(samples) == len(self.values))

    nsdf_autocorrelate(self, samples)
    nsdf_normalize(self, samples)
    highest := nsdf_key_maxima(self)
    peak = nsdf_choose_peak(self, highest)
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

// The far lags rest on few samples, their peaks are left out. The last 16th, 256 lags of 4096.
NSDF_IGNORED_LAGS_FRACTION :: 16

// Lower maxima are no period, the NSDF of the zero lag is 1
NSDF_MIN_PEAK_VALUE :: 0.5

// The first of the key maxima this close to the highest is the period, not a multiple of it
NSDF_CHOSEN_RATIO :: 0.95

// The key maxima into self.peaks, the highest between two zero crossings, refined between the lags. Returns
// the highest of them.
nsdf_key_maxima :: proc(self: ^NSDF) -> (highest_peak: Vec2) {
    clear(&self.peaks)
    end := len(self.values) - len(self.values) / NSDF_IGNORED_LAGS_FRACTION

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
nsdf_choose_peak :: proc(self: ^NSDF, highest_peak: Vec2) -> Vec2 {
    self.chosen_peak = -1
    for peak, index in self.peaks {
        if peak.y >= NSDF_CHOSEN_RATIO * highest_peak.y {
            self.chosen_peak = index
            return peak
        }
    }
    return {}
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
