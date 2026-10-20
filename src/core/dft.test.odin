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


#+build !js
package core

import "core:math"
import "core:testing"


@(test)
test_comb_rejects_partials :: proc(t: ^testing.T) {
    WINDOW :: 800 // about 200 cents wide, the gamma window alone lets the next partials in
    freq: f32 = 110 // a period of 436.4 samples, the box's last tap takes the fraction

    amp :: proc(dft: ^SingleFreqDFT, freq: f32) -> f32 {
        samples := make([]f32, dft.window_size, context.temp_allocator)
        for &sample, index in samples do sample = math.sin(math.TAU * freq * f32(index) / DEFAULT_SAMPLE_RATE)

        return abs(run_single_dft(dft, samples))
    }

    plain, comb: SingleFreqDFT
    defer destroy_dft(&plain)
    defer destroy_dft(&comb)
    set_dft_freq(&plain, freq / DEFAULT_SAMPLE_RATE, gamma_comb_window(WINDOW))
    set_dft_freq(&comb, freq / DEFAULT_SAMPLE_RATE, gamma_comb_window(WINDOW, DEFAULT_SAMPLE_RATE / freq))

    // Half the window's mean, as without the comb. The plain window is off it, this wide its band takes in
    // some of the sine's negative frequency, which the comb nulls too.
    level := amp(&comb, freq)
    testing.expectf(t, abs(level - 0.21) < 0.002, "the level %v, without the comb %v", level, amp(&plain, freq))
    for partial in ([]f32{2, 3}) {
        leak := amp(&comb, partial * freq)
        testing.expectf(t, leak < 1e-3 * level, "partial %v leaks %v of %v, %v without the comb", partial, leak, level, amp(&plain, partial * freq))
    }
}

@(test)
test_blackman_response_db :: proc(t: ^testing.T) {
    testing.expect(t, blackman_response_db(0) == 0)
    testing.expectf(t, abs(blackman_response_db(1) + 4.5) < 0.1, "1 bin, got %v dB", blackman_response_db(1))
    testing.expectf(t, abs(blackman_response_db(-2) + 20.4) < 0.1, "2 bins, got %v dB", blackman_response_db(-2))
    testing.expectf(t, blackman_response_db(3) < -100, "the null 3 bins out, got %v dB", blackman_response_db(3))
}
