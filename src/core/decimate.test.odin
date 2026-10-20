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
test_decimate :: proc(t: ^testing.T) {
    // The level of a sine at freq_hz through the decimator at input_rate, after the filters settled
    level :: proc(input_rate, freq_hz: f64) -> f64 {
        decimator, _ := init_decimator(f32(input_rate))
        samples := make([]f32, int(input_rate / 2), context.temp_allocator)
        for &sample, index in samples do sample = f32(math.sin(math.TAU * freq_hz * f64(index) / input_rate))

        // In chunks like the audio thread's, an odd size so the drop moves across them
        out := 0
        for start := 0; start < len(samples); start += 333 {
            chunk := samples[start:min(start + 333, len(samples))]
            count := decimate(&decimator, chunk)
            copy(samples[out:], chunk[:count])
            out += count
        }
        peak: f64
        for sample in samples[out / 2:out] do peak = max(peak, abs(f64(sample)))
        return peak
    }

    for rates in ([][2]f32{{48_000, 48_000}, {96_000, 48_000}, {88_200, 44_100}, {192_000, 48_000}, {176_400, 44_100}, {384_000, 48_000}}) {
        _, sample_rate := init_decimator(rates[0])
        testing.expectf(t, sample_rate == rates[1], "%v Hz comes out at %v Hz", rates[0], sample_rate)
    }

    // The audio as it was, up to C8's 4th harmonic at 96 kHz. Above the new Nyquist's lowest fold, nothing.
    for freq in ([]f64{100, 4186, 16_744}) {
        gain := level(96_000, freq)
        testing.expectf(t, abs(gain - 1) < 0.001, "%v Hz at %v", freq, gain)
    }
    for freq in ([]f64{29_000, 31_814, 40_000, 47_000}) {
        gain := level(96_000, freq)
        testing.expectf(t, gain < 1e-5, "%v Hz folds down at %v", freq, gain)
    }

    // Two halvings, 192 kHz: what would fold through either stage
    testing.expect(t, abs(level(192_000, 1000) - 1) < 0.001)
    for freq in ([]f64{30_000, 70_000, 90_000}) {
        gain := level(192_000, freq)
        testing.expectf(t, gain < 1e-5, "%v Hz folds down at %v", freq, gain)
    }
}
