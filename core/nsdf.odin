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

    http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf


------------------------------------------------------------------------------------------------- */


package core

import "core:math"
import "core:mem"

import pffft "../external/odin-pffft"

NSDFConfig :: struct {
    pffft_setup:     rawptr,
    fft_size:        int,
    fft:             []complex64,
    spectrum:        []f32,
    autocorr:        []f32,
    nsdf:            []f32,
    samplerate:      int,
    padded_samples:  []f32,
    autocorr_peaks:  [dynamic]int,
    nsdf_peaks:      [dynamic]Vec2,
    chosen_peak_idx: int,
}


nsdf_init :: proc(fft_size: int, samplerate: int) -> (self: NSDFConfig = {}) {
    self.fft_size = fft_size
    self.pffft_setup = pffft.new_setup(fft_size, pffft.Transform.REAL)
    self.fft = make([]complex64, fft_size)
    self.autocorr = make([]f32, fft_size)
    self.spectrum = make([]f32, fft_size)
    self.nsdf = make([]f32, fft_size / 2)
    self.samplerate = samplerate
    self.padded_samples = make([]f32, fft_size)
    return
}

nsdf_destroy :: proc(self: ^NSDFConfig) {
    pffft.destroy_setup(self.pffft_setup)
    delete(self.fft)
    delete(self.spectrum)
    delete(self.autocorr)
    delete(self.nsdf)
    delete(self.padded_samples)
    delete(self.autocorr_peaks)
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
@(private)
nsdf_process_samples :: proc(self: ^NSDFConfig, samples: []f32) {
    assert(len(samples) <= self.fft_size / 2)

    // pad samples with zeros to avoid cyclic convolution
    mem.zero_slice(self.padded_samples)
    mem.zero_slice(self.autocorr)
    copy(self.padded_samples, samples)

    // FFT transform
    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(self.padded_samples),
        raw_data(mem.slice_data_cast([]f32, self.fft)),
        nil,
        pffft.Direction.FORWARD,
    )

    // multiply FFT with conjugate
    // - conjugation in the frequency domain is equivalent to reversal in the time domain
    // (the difference between cross-correlation and convolution is a time reversal on one of the inputs)
    for i in 0 ..< len(self.fft) {
        self.fft[i] = self.fft[i] * conj(self.fft[i])
    }

    // inverse FFT to produce auto-correlation
    pffft.transform_ordered(
        self.pffft_setup,
        raw_data(mem.slice_data_cast([]f32, self.fft)),
        raw_data(self.autocorr),
        nil,
        pffft.Direction.BACKWARD,
    )

    // scale by 1/N
    for i in 0 ..< len(self.autocorr) {
        self.autocorr[i] = self.autocorr[i] / f32(self.fft_size)
    }
}


@(private)
nsdf_find_peak :: proc(self: ^NSDFConfig) -> Vec2 {
    // clear out peaks from the previous run
    clear(&self.nsdf_peaks)

    // TODO
    n := len(self.nsdf) - 256

    MIN_PEAK_VALUE := 0.5 * self.nsdf[0]

    max_peak := Vec2{0.0, 0.0}

    // enumerate all the candidate peaks
    i := 1
    for i < n {

        // go down the first slope
        for i < n && self.nsdf[i] > 0.0 do i += 1

        // skip all negative values
        for i < n && self.nsdf[i] <= 0.0 do i += 1

        lag := i
        min := lag

        // search for a local max peak in the positive area
        for i < n - 1 && self.nsdf[i] > 0.0 {
            if self.nsdf[i] > self.nsdf[lag] &&
               self.nsdf[i] > self.nsdf[i + 1] &&
               self.nsdf[i] > MIN_PEAK_VALUE {
                lag = i
            }
            i += 1
        }

        if lag > min {
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

    THRESHOLD: f32 = 0.95
    chosen_peak: Vec2 = {}
    self.chosen_peak_idx = -1

    // take the first key maximum above this threshold
    for p, idx in self.nsdf_peaks {
        if p.y >= THRESHOLD * max_peak.y {
            chosen_peak = p
            self.chosen_peak_idx = idx
            break
        }
    }

    return chosen_peak
}

// Normalized Square Difference Function (through autocorrelation)
// http://riogrande.cs.tcu.edu/1516Ribbit/resources/A_Smarter_Way_to_Find_Pitch.pdf
@(private)
nsdf_run_nsdf :: proc(self: ^NSDFConfig, samples: []f32) {
    n := len(samples)
    copy(self.nsdf, self.autocorr[:n])

    // left-hand summation for zero lag
    lhsum := 2.0 * self.nsdf[0]

    for i in 0 ..< n {
        if lhsum > 0.0 {
            self.nsdf[i] *= 2.0 / lhsum
            lhsum -= samples[i] * samples[i] + samples[n - i - 1] * samples[n - i - 1]
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
