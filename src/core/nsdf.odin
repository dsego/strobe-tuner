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

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

import pffft "../../external/odin-pffft"

// The buffers of the NSDF and the peaks it found last
NSDF :: struct {
    pffft_setup:    rawptr,
    fft_size:       int,
    spectrum:       []complex64, // the power spectrum once autocorrelated
    autocorr:       []f32,
    values:         []f32, // the NSDF of each lag
    samplerate:     int,
    padded_samples: []f32,
    peaks:          [dynamic]Vec2, // lag and NSDF value of each key maximum
    chosen_peak:    int, // in peaks, -1 for none
}


init_nsdf :: proc(fft_size: int, samplerate: int) -> (self: NSDF) {
    self.fft_size = fft_size
    self.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    // A real transform of fft_size samples has fft_size / 2 complex bins, see nsdf_autocorrelate
    self.spectrum = runtime.make_aligned([]complex64, fft_size / 2, 16)
    self.autocorr = runtime.make_aligned([]f32, fft_size, 16)
    self.values = make([]f32, fft_size / 2)
    self.samplerate = samplerate
    self.padded_samples = runtime.make_aligned([]f32, fft_size, 16)
    return
}

destroy_nsdf :: proc(self: ^NSDF) {
    pffft.destroy_setup(self.pffft_setup)
    delete(self.spectrum)
    delete(self.autocorr)
    delete(self.values)
    delete(self.padded_samples)
    delete(self.peaks)
}

// The frequency of the chosen peak, 0 for none, and the peak, its lag and NSDF value
run_nsdf :: proc(self: ^NSDF, samples: []f32) -> (freq: f32, peak: Vec2) {
    nsdf_autocorrelate(self, samples)
    normalize(self, samples)
    peak = find_peak(self)
    if peak.x > 0 do freq = f32(self.samplerate) / peak.x
    return

    // The NSDF through the autocorrelation, the left-hand sum of the squares runs down as the lag grows.
    // The sum is kept in f64, in f32 thousands of subtractions drift it at the far lags.
    normalize :: proc(self: ^NSDF, samples: []f32) {
        count := len(samples)
        copy(self.values, self.autocorr[:count])

        squares := 2.0 * f64(self.values[0])
        for lag in 0 ..< count {
            if squares > 0.0 {
                self.values[lag] *= f32(2.0 / squares)
                mirrored := samples[count - lag - 1]
                squares -= f64(samples[lag] * samples[lag]) + f64(mirrored * mirrored)
            } else {
                self.values[lag] = 0.0
            }
        }
    }

    // The key maxima, the highest between two zero crossings, and the first one close to the highest of them
    find_peak :: proc(self: ^NSDF) -> Vec2 {
        clear(&self.peaks)

        // The far lags rest on few samples, their peaks are left out
        IGNORED_LAGS :: 256
        // The first of the key maxima this close to the highest is the period, not a multiple of it
        CHOSEN_RATIO :: 0.95
        // Lower maxima are no period, the NSDF of the zero lag is 1
        MIN_PEAK_VALUE :: 0.5

        end := len(self.values) - IGNORED_LAGS
        max_peak: Vec2

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
                if value > self.values[highest] && value > self.values[lag + 1] && value > MIN_PEAK_VALUE {
                    highest = lag
                }
                lag += 1
            }

            if highest > start {
                offset, value := parabolic(self.values[highest - 1], self.values[highest], self.values[highest + 1])
                peak := Vec2{f32(highest) + offset, value}
                append(&self.peaks, peak)
                if value >= max_peak.y do max_peak = peak
            }
            lag += 1
        }

        self.chosen_peak = -1
        for peak, index in self.peaks {
            if peak.y >= CHOSEN_RATIO * max_peak.y {
                self.chosen_peak = index
                return peak
            }
        }
        return {}
    }
}


// The cyclic autocorrelation of the zero padded samples: the FFT, times its conjugate, and back
nsdf_autocorrelate :: proc(self: ^NSDF, samples: []f32) {
    assert(len(samples) <= self.fft_size / 2)

    // Zero padded to twice the length, the cyclic correlation doesn't wrap around onto the samples
    mem.zero_slice(self.padded_samples)
    copy(self.padded_samples, samples)

    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(self.padded_samples),
        cast(^f32)raw_data(self.spectrum),
        nil,
        pffft.Direction.FORWARD,
    )

    // Times the conjugate, the power spectrum. pffft packs the two real bins, DC and Nyquist, into the first
    // element as (DC, Nyquist), each is squared on its own and they stay packed for the inverse transform.
    dc_nyquist := self.spectrum[0]
    self.spectrum[0] = complex(real(dc_nyquist) * real(dc_nyquist), imag(dc_nyquist) * imag(dc_nyquist))
    for &bin in self.spectrum[1:] {
        bin = complex(real(bin) * real(bin) + imag(bin) * imag(bin), 0)
    }

    pffft.transform_ordered(
        self.pffft_setup,
        cast(^f32)raw_data(self.spectrum),
        raw_data(self.autocorr),
        nil,
        pffft.Direction.BACKWARD,
    )

    // pffft doesn't scale the inverse transform
    for &value in self.autocorr do value /= f32(self.fft_size)
}

// Parabolic interpolation to find the more accurate peak location, its offset from the middle point and value
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc(before: f32, middle: f32, after: f32) -> (offset: f32, value: f32) {
    offset = 0.5 * (before - after) / (before - 2.0 * middle + after)
    value = middle - 0.25 * (before - after) * offset
    return
}


@(test)
test_autocorrelation :: proc(t: ^testing.T) {
    FFT_SIZE :: 1024
    self := init_nsdf(FFT_SIZE, 48_000)
    defer destroy_nsdf(&self)

    // DC and a tone at the Nyquist frequency of the padded transform go through its packed first bin
    samples: [FFT_SIZE / 2]f32
    for &sample, i in samples {
        sample = 0.3 + 0.2 * math.sin(f32(i) * 0.37) + (0.1 if i % 2 == 0 else -0.1)
    }
    nsdf_autocorrelate(&self, samples[:])

    for lag in 0 ..< len(samples) {
        expected: f32
        for i in 0 ..< len(samples) - lag do expected += samples[i] * samples[i + lag]
        testing.expectf(t, abs(self.autocorr[lag] - expected) < 1e-3, "lag %v: %v, expected %v", lag, self.autocorr[lag], expected)
    }
}


// The period of the whole wave: exact harmonics don't move it, partials stretched sharp like a stiff
// string's pull it sharp of the fundamental, towards the loud ones
@(test)
test_nsdf_accuracy :: proc(t: ^testing.T) {
    SAMPLERATE :: 48_000
    FFT_SIZE :: 8192 // the app's default

    // Cents from the fundamental, partial n is at n * fundamental stretched by stretch_cents * (n² - 1)
    run :: proc(fundamental: f64, amplitudes: []f64, stretch_cents: f64) -> f32 {
        self := init_nsdf(FFT_SIZE, SAMPLERATE)
        defer destroy_nsdf(&self)
        samples: [FFT_SIZE / 2]f32
        for &sample, i in samples {
            for amplitude, partial in amplitudes {
                n := f64(partial + 1)
                freq := n * fundamental * math.pow(2, stretch_cents * (n * n - 1) / 1200)
                sample += f32(amplitude * math.sin(math.TAU * freq * f64(i) / SAMPLERATE + n))
            }
        }
        freq, _ := run_nsdf(&self, samples[:])
        return cents_deviation(freq, f32(fundamental))
    }

    // A0 and a five string bass's low B have only 2.3 and 2.6 periods in the window
    for fundamental in ([]f64{27.5, 30.87, 55, 110, 329.63, 1318.5}) {
        pure := run(fundamental, {0.5}, 0)
        testing.expectf(t, abs(pure) < 0.05, "%v Hz sine, %v cents off", fundamental, pure)

        // A weak fundamental under a loud second partial, like a low string
        harmonic := run(fundamental, {0.1, 0.4, 0.2, 0.1}, 0)
        testing.expectf(t, abs(harmonic) < 0.2, "%v Hz harmonics, %v cents off", fundamental, harmonic)
    }

    // The partials 1.5, 4 and 7.5 cents sharp read about 3 cents sharp, where the strobe's first track
    // stands still on the fundamental
    stretched := run(110, {0.1, 0.4, 0.2, 0.1}, 0.5)
    testing.expectf(t, stretched > 1.5, "stretched partials, %v cents off", stretched)
}
