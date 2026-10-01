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


    Pitch detection based on NSDF (McLeod Pitch Method)

    https://www.researchgate.net/publication/230554927_A_smarter_way_to_find_pitch


------------------------------------------------------------------------------------------------- */


package core

import "base:runtime"
import "core:math"
import "core:mem"
import "core:testing"

import pffft "../external/odin-pffft"

NSDFConfig :: struct {
    pffft_setup:     rawptr,
    fft_size:        int,
    fft:             []complex64,
    autocorr:        []f32,
    nsdf:            []f32,
    samplerate:      int,
    padded_samples:  []f32,
    nsdf_peaks:     [dynamic]Vec2,
    chosen_peak_idx: int,
}


nsdf_init :: proc(fft_size: int, samplerate: int) -> (self: NSDFConfig = {}) {
    self.fft_size = fft_size
    self.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    // A real transform of fft_size samples has fft_size / 2 complex bins, see nsdf_process_samples
    self.fft = runtime.make_aligned([]complex64, fft_size / 2, 16)
    self.autocorr = runtime.make_aligned([]f32, fft_size, 16)
    self.nsdf = make([]f32, fft_size / 2)
    self.samplerate = samplerate
    self.padded_samples = runtime.make_aligned([]f32, fft_size, 16)
    return
}

nsdf_destroy :: proc(self: ^NSDFConfig) {
    pffft.destroy_setup(self.pffft_setup)
    delete(self.fft)
    delete(self.autocorr)
    delete(self.nsdf)
    delete(self.padded_samples)
    delete(self.nsdf_peaks)
}

nsdf_pitch_detect :: proc(self: ^NSDFConfig, samples: []f32) -> (f32, Vec2) {
    nsdf_process_samples(self, samples)
    nsdf_run_nsdf(self, samples)

    peak := nsdf_find_peak(self)

    estimated_freq: f32 = 0.0

    if peak.x > 0.0 {
        estimated_freq = f32(self.samplerate) / peak.x
    }

    // apply windowing?

    return estimated_freq, peak
}


// Generate the auto-correlation
//   Taking the FFT of the segment of interest, multiplying it by its complex conjugate,
//    then taking the inverse FFT will give us the cyclic auto-correlation.
nsdf_process_samples :: proc(self: ^NSDFConfig, samples: []f32) {
    assert(len(samples) <= self.fft_size / 2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(self.padded_samples)
    copy(self.padded_samples, samples)

    // FFT transform
    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(self.padded_samples),
        cast(^f32)raw_data(self.fft),
        nil,
        pffft.Direction.FORWARD,
    )

    // multiply FFT with conjugate, i.e. the power spectrum
    // - conjugation in the frequency domain is equivalent to reversal in the time domain
    // (the difference between cross-correlation and convolution is a time reversal on one of the inputs)
    //
    // pffft packs the two real bins, DC and Nyquist, into the first element as (DC, Nyquist),
    // each is squared on its own and they stay packed for the inverse transform
    dc_nyquist := self.fft[0]
    self.fft[0] = complex(real(dc_nyquist) * real(dc_nyquist), imag(dc_nyquist) * imag(dc_nyquist))
    for &bin in self.fft[1:] {
        bin = complex(real(bin) * real(bin) + imag(bin) * imag(bin), 0)
    }

    // inverse FFT to produce auto-correlation
    pffft.transform_ordered(
        self.pffft_setup,
        cast(^f32)raw_data(self.fft),
        raw_data(self.autocorr),
        nil,
        pffft.Direction.BACKWARD,
    )

    // scale by 1/N
    for i in 0 ..< len(self.autocorr) {
        self.autocorr[i] = self.autocorr[i] / f32(self.fft_size)
    }
}


nsdf_find_peak :: proc(self: ^NSDFConfig) -> Vec2 {
    // clear out peaks from the previous run
    clear(&self.nsdf_peaks)

    // TODO
    end := len(self.nsdf) - 256

    min_peak_value := 0.5 * self.nsdf[0]

    max_peak := Vec2{0.0, 0.0}

    // enumerate all the candidate peaks
    i := 1
    for i < end {

        // go down the first slope
        for i < end && self.nsdf[i] > 0.0 do i += 1

        // skip all negative values
        for i < end && self.nsdf[i] <= 0.0 do i += 1

        lag := i
        start := lag

        // search for a local max peak in the positive area
        for i < end - 1 && self.nsdf[i] > 0.0 {
            if self.nsdf[i] > self.nsdf[lag] &&
               self.nsdf[i] > self.nsdf[i + 1] &&
               self.nsdf[i] > min_peak_value {
                lag = i
            }
            i += 1
        }

        if lag > start {
            peak_location, magnitude := parabolic(
                self.nsdf[lag - 1],
                self.nsdf[lag],
                self.nsdf[lag + 1],
            )

            improved_lag := f32(lag) + peak_location
            peak := Vec2{improved_lag, magnitude}
            append(&self.nsdf_peaks, peak)

            if magnitude >= max_peak.y {
                max_peak = peak
            }
        }


        i += 1
    }

    THRESHOLD :: 0.95
    chosen_peak: Vec2 = {}
    self.chosen_peak_idx = -1

    // take the first key maximum above this threshold
    for peak, idx in self.nsdf_peaks {
        if peak.y >= THRESHOLD * max_peak.y {
            chosen_peak = peak
            self.chosen_peak_idx = idx
            break
        }
    }

    return chosen_peak
}

// Normalized Square Difference Function (through autocorrelation)
// http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf
nsdf_run_nsdf :: proc(self: ^NSDFConfig, samples: []f32) {
    count := len(samples)
    copy(self.nsdf, self.autocorr[:count])

    // left-hand summation for zero lag
    lhsum := 2.0 * self.nsdf[0]

    for i in 0 ..< count {
        if lhsum > 0.0 {
            self.nsdf[i] *= 2.0 / lhsum
            lhsum -= samples[i] * samples[i] + samples[count - i - 1] * samples[count - i - 1]
        } else {
            self.nsdf[i] = 0.0
        }
    }
}

// Parabolic interpolation to find the more accurate peak location
// https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
parabolic :: proc(alpha: f32, beta: f32, gamma: f32) -> (f32, f32) {
    location := 0.5 * (alpha - gamma) / (alpha - 2.0 * beta + gamma)
    magnitude := beta - 0.25 * (alpha - gamma) * location
    return location, magnitude
}


@(test)
test_autocorrelation :: proc(t: ^testing.T) {
    FFT_SIZE :: 1024
    self := nsdf_init(FFT_SIZE, 48_000)
    defer nsdf_destroy(&self)

    // DC and a tone at the Nyquist frequency of the padded transform go through its packed first bin
    samples: [FFT_SIZE / 2]f32
    for &sample, i in samples {
        sample = 0.3 + 0.2 * math.sin(f32(i) * 0.37) + (0.1 if i % 2 == 0 else -0.1)
    }
    nsdf_process_samples(&self, samples[:])

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
        self := nsdf_init(FFT_SIZE, SAMPLERATE)
        defer nsdf_destroy(&self)
        samples: [FFT_SIZE / 2]f32
        for &sample, i in samples {
            for amplitude, partial in amplitudes {
                n := f64(partial + 1)
                freq := n * fundamental * math.pow(2, stretch_cents * (n * n - 1) / 1200)
                sample += f32(amplitude * math.sin(math.TAU * freq * f64(i) / SAMPLERATE + n))
            }
        }
        freq, _ := nsdf_pitch_detect(&self, samples[:])
        return cents_deviation(freq, f32(fundamental))
    }

    for fundamental in ([]f64{55, 110, 329.63, 1318.5}) {
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
