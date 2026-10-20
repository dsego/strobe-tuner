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
test_butterworth :: proc(t: ^testing.T) {
    samplerate: f32 = 48_000

    measure_gain :: proc(bq: Biquad, freq_hz: f32, samplerate: f32) -> f32 {
        bq := bq
        input := make([]f32, int(samplerate))
        output := make([]f32, int(samplerate))
        defer delete(input)
        defer delete(output)

        // The phase in f64, in f32 it's off by a radian a second in
        for &sample, i in input do sample = f32(math.sin(math.TAU * f64(freq_hz) * f64(i) / f64(samplerate)))

        biquad_process(&bq, input, output)

        // skip the transient, measure the peak of the second half
        peak: f32 = 0
        for sample in output[len(output) / 2:] do peak = max(peak, abs(sample))

        return peak
    }

    // -3dB at the cutoff, DC and rumble removed, passband untouched
    highpass := init_highpass(60, samplerate)
    testing.expect(t, abs(measure_gain(highpass, 60, samplerate) - math.SQRT_TWO / 2) < 0.01)
    testing.expect(t, measure_gain(highpass, 10, samplerate) < 0.03)
    testing.expect(t, abs(measure_gain(highpass, 440, samplerate) - 1.0) < 0.01)

    // The same at the other end, hiss above the cutoff goes
    lowpass := init_lowpass(5000, samplerate)
    testing.expect(t, abs(measure_gain(lowpass, 5000, samplerate) - math.SQRT_TWO / 2) < 0.01)
    testing.expect(t, measure_gain(lowpass, 20_000, samplerate) < 0.07)
    testing.expect(t, abs(measure_gain(lowpass, 440, samplerate) - 1.0) < 0.01)
}
