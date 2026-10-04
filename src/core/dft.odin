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


// Gamma shaped (order 3), the weight of a 3-pole lock-in low-pass: it rises fast from the newest sample and
// falls off with age, so a tone is measured as of GAMMA_WINDOW_DELAY of the window back instead of half.
// The spread of the weights matches a Blackman window's (0.16 of the window, σ = √3 τ), for about as
// narrow a band, and the mean matches its 0.42 so the levels are the same.
GAMMA_WINDOW_TAU :: 0.0921 // of the window size
GAMMA_WINDOW_DELAY :: 3 * GAMMA_WINDOW_TAU // the mean age, of the window size

gamma_window :: proc(index: f32, size: f32) -> f32 {
    age := (size - 1.0 - index) / (GAMMA_WINDOW_TAU * size)
    return 0.42 / (2.0 * GAMMA_WINDOW_TAU) * age * age * math.exp(-age)
}

SingleFreqDFT :: struct {
    window_size:  int, // the comb's box included
    gamma_size:   int, // the gamma window before the comb's box widened it
    norm_freq:    f32, // normalized frequency, eg 440Hz/ 48,000Hz
    comb_samples: f32, // the comb's box, 0 for none
    twiddles:     []complex64, // precomputed windowed twiddles, one per sample of the window
    dft:          complex64, // stores the resulting DFT after calling run_single_dft
}


// Tune to norm_freq over window_size samples of the gamma window, the twiddles are reallocated when the
// size changes.
//
// With spread_cents the bins that far below and above are added in, which flattens the top of the peak
// ("phase average"): a slightly detuned note keeps its level and the in tune phase is the same. The sum of
// the three DFTs is the DFT with the sum of their twiddles, so it costs no more than one.
//
// comb_samples smooths the window with a box that long, a moving average. Its nulls fall every
// samplerate / comb_samples from the bin, so a box of a note's period rejects every other partial of it
// however wide the window's band. The window grows by the box.
set_dft_freq :: proc(
    self: ^SingleFreqDFT,
    norm_freq: f32,
    window_size: int,
    spread_cents: f32 = 0,
    comb_samples: f32 = 0,
) {
    taps := int(math.ceil(comb_samples)) if comb_samples > 0 else 1
    size := window_size + taps - 1
    if len(self.twiddles) != size {
        delete(self.twiddles)
        self.twiddles = make([]complex64, size)
    }
    self.window_size = size
    self.gamma_size = window_size
    self.norm_freq = norm_freq
    self.comb_samples = comb_samples

    weights := make([]f64, size, context.temp_allocator)
    for &weight, index in weights[:window_size] do weight = f64(gamma_window(f32(index), f32(window_size)))
    if comb_samples > 0 do comb(weights, window_size, comb_samples)

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

    for weight, index in weights {
        twiddle := rotation
        if spread_cents != 0 do twiddle *= 1 + below + above

        self.twiddles[index] = complex64(complex(weight, 0) * twiddle)

        rotation *= step
        below *= below_step
        above *= above_step
    }

    // The first window_size weights convolved with the box, in place. The box is comb_samples long, its
    // last tap takes the fraction. Scaled so the level stays the same over the longer window.
    comb :: proc(weights: []f64, window_size: int, comb_samples: f32) {
        source := make([]f64, window_size, context.temp_allocator)
        copy(source, weights[:window_size])
        at :: proc(source: []f64, index: int) -> f64 {
            return source[index] if index >= 0 && index < len(source) else 0
        }

        taps := len(weights) - window_size + 1
        last_tap := f64(comb_samples) - f64(taps - 1)
        scale := f64(len(weights)) / (f64(window_size) * f64(comb_samples))

        // A running sum of the whole taps, source[index - taps + 2 ..= index]
        whole: f64
        for &weight, index in weights {
            oldest := index - taps + 1
            whole += at(source, index) - at(source, oldest)
            weight = (whole + last_tap * at(source, oldest)) * scale
        }
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
    WINDOW :: 7339
    freq: f32 = 110

    samples := make([]f32, WINDOW)
    defer delete(samples)
    for &sample, index in samples do sample = math.sin(math.TAU * 111 * f32(index) / SAMPLERATE)

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

@(test)
test_comb_rejects_partials :: proc(t: ^testing.T) {
    WINDOW :: 800 // about 200 cents wide, the gamma window alone lets the next partials in
    freq: f32 = 110 // a period of 436.4 samples, the box's last tap takes the fraction

    amp :: proc(dft: ^SingleFreqDFT, freq: f32) -> f32 {
        samples := make([]f32, dft.window_size, context.temp_allocator)
        for &sample, index in samples do sample = math.sin(math.TAU * freq * f32(index) / SAMPLERATE)
        return abs(run_single_dft(dft, samples))
    }

    plain, comb: SingleFreqDFT
    defer destroy_dft(&plain)
    defer destroy_dft(&comb)
    set_dft_freq(&plain, freq / SAMPLERATE, WINDOW)
    set_dft_freq(&comb, freq / SAMPLERATE, WINDOW, comb_samples = SAMPLERATE / freq)

    // Half the window's mean, as without the comb. The plain window is off it, this wide its band takes in
    // some of the sine's negative frequency, which the comb nulls too.
    level := amp(&comb, freq)
    testing.expectf(t, abs(level - 0.21) < 0.002, "the level %v, without the comb %v", level, amp(&plain, freq))
    for partial in ([]f32{2, 3}) {
        leak := amp(&comb, partial * freq)
        testing.expectf(t, leak < 1e-3 * level, "partial %v leaks %v of %v, %v without the comb", partial, leak, level, amp(&plain, partial * freq))
    }
}
