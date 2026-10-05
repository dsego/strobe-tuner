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

// The gamma window over gamma_size samples, smoothed with a box comb_samples long, a moving average. The
// box's nulls fall every samplerate / comb_samples from the bin, so a box of a note's period rejects every
// other partial of it however wide the gamma window's band. The window grows by the box.
gamma_comb_window :: proc(gamma_size: int, comb_samples: f32 = 0, allocator := context.temp_allocator) -> []f64 {
    taps := int(math.ceil(comb_samples)) if comb_samples > 0 else 1
    weights := make([]f64, gamma_size + taps - 1, allocator)
    for &weight, index in weights[:gamma_size] do weight = f64(gamma_window(f32(index), f32(gamma_size)))
    if comb_samples > 0 do comb_box(weights, gamma_size, comb_samples)

    return weights
}

// The first gamma_size weights convolved with the box, in place. The box is comb_samples long, its last
// tap takes the fraction. Scaled so the level stays the same over the longer window.
comb_box :: proc(weights: []f64, gamma_size: int, comb_samples: f32) {
    source := make([]f64, gamma_size, context.temp_allocator)
    copy(source, weights[:gamma_size])
    at :: proc(source: []f64, index: int) -> f64 {
        return source[index] if index >= 0 && index < len(source) else 0
    }

    taps := len(weights) - gamma_size + 1
    last_tap := f64(comb_samples) - f64(taps - 1)
    scale := f64(len(weights)) / (f64(gamma_size) * f64(comb_samples))

    // A running sum of the whole taps, source[index - taps + 2 ..= index]
    whole: f64
    for &weight, index in weights {
        oldest := index - taps + 1
        whole += at(source, index) - at(source, oldest)
        weight = (whole + last_tap * at(source, oldest)) * scale
    }
}

// How far back gamma_comb_window measures, in samples: the gamma window's mean age, the box adds half
// its length
gamma_comb_delay :: proc(gamma_size: int, comb_samples: f32 = 0) -> int {
    return int(GAMMA_WINDOW_DELAY * f32(gamma_size) + comb_samples / 2)
}

// Every sample the same weight
flat_window :: proc(size: int, allocator := context.temp_allocator) -> []f64 {
    weights := make([]f64, size, allocator)
    for &weight in weights do weight = 1

    return weights
}


SingleFreqDFT :: struct {
    window_size: int,
    norm_freq:   f32, // normalized frequency, eg 440Hz/ 48,000Hz
    twiddles:    []complex64, // precomputed windowed twiddles, one per sample of the window
    dft:         complex64, // stores the resulting DFT after calling run_single_dft
}


// Tune to norm_freq over the window's weights, one per sample, the twiddles are reallocated when the
// size changes.
set_dft_freq :: proc(self: ^SingleFreqDFT, norm_freq: f32, weights: []f64) {
    size := len(weights)

    if len(self.twiddles) != size {
        delete(self.twiddles)
        self.twiddles = make([]complex64, size)
    }

    self.window_size = size
    self.norm_freq = norm_freq

    // exp(-j*omega*i), rotated one step at a time. In f64, a long window runs to a couple hundred thousand
    // steps and the f32 rounding adds up.
    omega := math.TAU * f64(norm_freq)
    step := complex(math.cos(omega), -math.sin(omega))
    rotation := complex128(1)

    for weight, index in weights {
        self.twiddles[index] = complex64(complex(weight, 0) * rotation)
        rotation *= step
    }
}

destroy_dft :: proc(self: ^SingleFreqDFT) {
    delete(self.twiddles)
}

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
    set_dft_freq(&plain, freq / SAMPLERATE, gamma_comb_window(WINDOW))
    set_dft_freq(&comb, freq / SAMPLERATE, gamma_comb_window(WINDOW, SAMPLERATE / freq))

    // Half the window's mean, as without the comb. The plain window is off it, this wide its band takes in
    // some of the sine's negative frequency, which the comb nulls too.
    level := amp(&comb, freq)
    testing.expectf(t, abs(level - 0.21) < 0.002, "the level %v, without the comb %v", level, amp(&plain, freq))
    for partial in ([]f32{2, 3}) {
        leak := amp(&comb, partial * freq)
        testing.expectf(t, leak < 1e-3 * level, "partial %v leaks %v of %v, %v without the comb", partial, leak, level, amp(&plain, partial * freq))
    }
}

// The level of a Blackman window's bin for a sine offset_bins off it, in dB under a sine on it. A long
// window's: its spectrum is the sinc of the box and two pairs of shifted ones. The main lobe ends 3 bins out.
blackman_response_db :: proc(offset_bins: f32) -> f32 {
    sinc :: proc(x: f64) -> f64 {
        return 1 if x == 0 else math.sin(math.PI * x) / (math.PI * x)
    }

    x := f64(offset_bins)
    response := 0.42 * sinc(x) + 0.25 * (sinc(x - 1) + sinc(x + 1)) + 0.04 * (sinc(x - 2) + sinc(x + 2))
    return f32(20 * math.log10(max(abs(response) / 0.42, 1e-6)))
}

@(test)
test_blackman_response_db :: proc(t: ^testing.T) {
    testing.expect(t, blackman_response_db(0) == 0)
    testing.expectf(t, abs(blackman_response_db(1) + 4.5) < 0.1, "1 bin, got %v dB", blackman_response_db(1))
    testing.expectf(t, abs(blackman_response_db(-2) + 20.4) < 0.1, "2 bins, got %v dB", blackman_response_db(-2))
    testing.expectf(t, blackman_response_db(3) < -100, "the null 3 bins out, got %v dB", blackman_response_db(3))
}
