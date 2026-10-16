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
    sample_rate:    f32, // a lag's frequency
    spectrum:       []f32, // the power spectrum over fft_size once autocorrelated, in pffft's own order
    ordered:        []complex64, // the spectrum in bin order, see nsdf_ordered_spectrum
    work:           []f32, // pffft's scratch
    autocorr:       []f32,
    values:         []f32, // the NSDF of each lag
    padded_samples: []f32,
    peaks:          [dynamic]Vec2, // lag and NSDF value of each key maximum
    chosen_peak:    int, // in peaks, -1 for none
}


init_nsdf :: proc(fft_size: int, sample_rate: f32) -> (self: NSDF) {
    self.fft_size = fft_size
    self.sample_rate = sample_rate
    self.pffft_setup = pffft.new_setup(i32(fft_size), pffft.Transform.REAL)

    // square_unordered_spectrum reads pffft's order with four floats to a SIMD vector, NEON's and SSE's
    assert(pffft.simd_size() == 4)

    // A real transform of fft_size samples has fft_size / 2 complex bins, see nsdf_autocorrelate
    self.spectrum = runtime.make_aligned([]f32, fft_size, 16)
    self.ordered = runtime.make_aligned([]complex64, fft_size / 2, 16)
    self.work = runtime.make_aligned([]f32, fft_size, 16)
    self.autocorr = runtime.make_aligned([]f32, fft_size, 16)
    self.values = make([]f32, fft_size / 2)
    self.padded_samples = runtime.make_aligned([]f32, fft_size, 16)
    return
}

destroy_nsdf :: proc(self: ^NSDF) {
    pffft.destroy_setup(self.pffft_setup)
    delete(self.spectrum)
    delete(self.ordered)
    delete(self.work)
    delete(self.autocorr)
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


// The cyclic autocorrelation of the zero padded samples: the FFT, times its conjugate, and back. The
// spectrum stays in pffft's own order, squaring each bin doesn't need them in order, and the inverse
// transform takes them back in that order.
nsdf_autocorrelate :: proc(self: ^NSDF, samples: []f32) {
    assert(len(samples) <= self.fft_size / 2)

    // Zero padded to twice the length, the cyclic correlation doesn't wrap around onto the samples
    copy(self.padded_samples, samples)
    mem.zero_slice(self.padded_samples[len(samples):])

    pffft.transform(
        self.pffft_setup,
        raw_data(self.padded_samples),
        raw_data(self.spectrum),
        raw_data(self.work),
        pffft.Direction.FORWARD,
    )

    // pffft doesn't scale the inverse transform, the spectrum is scaled instead
    square_unordered_spectrum(self.spectrum, 1 / f32(self.fft_size))

    pffft.transform(
        self.pffft_setup,
        raw_data(self.spectrum),
        raw_data(self.autocorr),
        raw_data(self.work),
        pffft.Direction.BACKWARD,
    )
}

// Times the conjugate and the scale, the power spectrum in place, in pffft's own order out of transform.
// Every 8 floats are 4 bins, their real parts then their imaginary parts. The first 8 hold the two real
// bins, DC in float 0 and Nyquist in float 4, each is squared on its own. As pffft_zconvolve_accumulate.
square_unordered_spectrum :: proc(spectrum: []f32, scale: f32) {
    dc, nyquist := spectrum[0], spectrum[4]
    for i := 0; i < len(spectrum); i += 8 {
        for j in i ..< i + 4 {
            spectrum[j] = scale * (spectrum[j] * spectrum[j] + spectrum[j + 4] * spectrum[j + 4])
            spectrum[j + 4] = 0
        }
    }
    spectrum[0] = scale * dc * dc
    spectrum[4] = scale * nyquist * nyquist
}

// The power spectrum of the last autocorrelation over fft_size in bin order, the first bin packs DC and
// Nyquist like square_spectrum's
nsdf_ordered_spectrum :: proc(self: ^NSDF) -> []complex64 {
    pffft.zreorder(self.pffft_setup, raw_data(self.spectrum), cast([^]f32)raw_data(self.ordered), pffft.Direction.FORWARD)
    return self.ordered
}

// Times the conjugate, the power spectrum in place. pffft packs the two real bins, DC and Nyquist, into the
// first element as (DC, Nyquist), each is squared on its own and they stay packed for an inverse transform.
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


@(test)
test_autocorrelation :: proc(t: ^testing.T) {
    FFT_SIZE :: 1024
    self := init_nsdf(FFT_SIZE, DEFAULT_SAMPLE_RATE)
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

    // In bin order it's the ordered transform squared, over the size
    expected := runtime.make_aligned([]complex64, FFT_SIZE / 2, 16)
    defer delete(expected)
    pffft.transform_ordered(self.pffft_setup, raw_data(self.padded_samples), cast([^]f32)raw_data(expected), nil, pffft.Direction.FORWARD)
    square_spectrum(expected)

    for bin, index in nsdf_ordered_spectrum(&self) {
        want := expected[index] / FFT_SIZE
        testing.expectf(t, abs(bin - want) < 1e-4 * abs(expected[0]) / FFT_SIZE, "bin %v: %v, expected %v", index, bin, want)
    }
}


// The period of the whole wave: exact harmonics don't move it, partials stretched sharp like a stiff
// string's pull it sharp of the fundamental, towards the loud ones
@(test)
test_nsdf_accuracy :: proc(t: ^testing.T) {
    // The pitch detection's at 48 kHz
    FFT_SIZE :: 8192
    SAMPLE_RATE :: DEFAULT_SAMPLE_RATE

    // Cents from the fundamental, harmonic h is at h * fundamental stretched by stretch_cents * (h² - 1)
    run :: proc(fundamental: f64, amplitudes: []f64, stretch_cents: f64) -> f32 {
        self := init_nsdf(FFT_SIZE, SAMPLE_RATE)
        defer destroy_nsdf(&self)

        samples: [FFT_SIZE / 2]f32
        for &sample, index in samples {
            for amplitude, partial in amplitudes {
                harmonic := f64(partial + 1)
                freq := harmonic * fundamental * math.pow(2, stretch_cents * (harmonic * harmonic - 1) / 1200)
                sample += f32(amplitude * math.sin(math.TAU * freq * f64(index) / SAMPLE_RATE + harmonic))
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
