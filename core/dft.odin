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


package core

import "core:math"
import "core:testing"


SingleFreqDFT :: struct {
    window_size: int,
    norm_freq:   f32, // normalized frequency, eg 440Hz/ 48,000Hz
    twiddles:    []complex64, // precomputed windowed twiddles, one per sample of the window
    dft:         complex64, // stores the resulting DFT after calling run_single_dft
}


// Tune to norm_freq over window_size samples, the twiddles are reallocated when the size changes.
//
// With spread_cents the bins that far below and above are added in, which flattens the top of the peak
// ("phase average"): a slightly detuned note keeps its level and the in tune phase is the same. The sum of
// the three DFTs is the DFT with the sum of their twiddles, so it costs no more than one.
//
// low_latency takes the gamma window instead of the Blackman, see gamma_window.
set_dft_freq :: proc(
    self: ^SingleFreqDFT,
    norm_freq: f32,
    window_size: int,
    spread_cents: f32 = 0,
    low_latency := false,
) {
    if len(self.twiddles) != window_size {
        delete(self.twiddles)
        self.twiddles = make([]complex64, window_size)
    }
    self.window_size = window_size
    self.norm_freq = norm_freq

    // exp(-j*omega*i), rotated one step at a time. In f64, a long window runs to a couple hundred thousand
    // steps and the f32 rounding adds up.
    omega := math.TAU * f64(norm_freq)
    step := complex(math.cos(omega), -math.sin(omega))
    rotation := complex128(1)

    // The neighbouring bins relative to the centre one
    ratio := math.pow(2, f64(spread_cents) / 1200)
    below_step := complex(math.cos(omega / ratio - omega), -math.sin(omega / ratio - omega))
    above_step := complex(math.cos(omega * ratio - omega), -math.sin(omega * ratio - omega))
    below := complex128(1)
    above := complex128(1)

    for i in 0 ..< window_size {
        twiddle := rotation
        if spread_cents != 0 do twiddle *= 1 + below + above

        window_fn := gamma_window if low_latency else blackman_window
        window := f64(window_fn(f32(i), f32(window_size)))
        self.twiddles[i] = complex64(complex(window, 0) * twiddle)

        rotation *= step
        below *= below_step
        above *= above_step
    }
}

destroy_dft :: proc(self: ^SingleFreqDFT) {
    delete(self.twiddles)
}

// TODO: the cost is the window length times the display rate, e.g. an ~80k sample window for a bass low E
// at 120 FPS. Could run at a fixed rate below the display's, or decimate the input for the low notes.
run_single_dft :: proc(self: ^SingleFreqDFT, samples: []f32) -> complex64 {
    assert(len(samples) >= self.window_size)

    // The samples are real, two multiplies each instead of a full complex multiply
    re, im: f32
    for twiddle, i in self.twiddles {
        re += samples[i] * real(twiddle)
        im += samples[i] * imag(twiddle)
    }

    size := f32(self.window_size)
    self.dft = complex(re / size, im / size)
    return self.dft
}


@(test)
test_phase_average_matches_three_bins :: proc(t: ^testing.T) {
    SAMPLERATE :: 48_000
    WINDOW :: 7339
    freq: f32 = 110

    samples := make([]f32, WINDOW)
    defer delete(samples)
    for &sample, i in samples do sample = math.sin(math.TAU * 111 * f32(i) / SAMPLERATE)

    averaged: SingleFreqDFT
    defer destroy_dft(&averaged)
    set_dft_freq(&averaged, freq / SAMPLERATE, WINDOW, 5)

    // The three bins on their own
    sum: complex64
    for cents in ([]f32{-5, 0, 5}) {
        bin: SingleFreqDFT
        defer destroy_dft(&bin)
        set_dft_freq(&bin, cents_to_freq(cents, freq) / SAMPLERATE, WINDOW)
        sum += run_single_dft(&bin, samples)
    }

    got := run_single_dft(&averaged, samples)
    testing.expectf(t, abs(got - sum) < 1e-4 * abs(sum), "got %v, the three bins add up to %v", got, sum)
}
