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


// Single 2nd order IIR section, transposed direct form II
Biquad :: struct {
    enabled: bool,
    b0:      f64,
    b1:      f64,
    b2:      f64,
    a1:      f64,
    a2:      f64,
    z1:      f64,
    z2:      f64,
}


// 2nd order Butterworth high-pass, takes out DC and low frequency rumble. A cutoff of 0 passes the signal through.
init_highpass :: proc(cutoff_hz: f32, samplerate: f32) -> Biquad {
    return init_butterworth(cutoff_hz, samplerate, highpass = true)
}

// 2nd order Butterworth low-pass. A cutoff of 0 passes the signal through.
init_lowpass :: proc(cutoff_hz: f32, samplerate: f32) -> Biquad {
    return init_butterworth(cutoff_hz, samplerate, highpass = false)
}

// RBJ cookbook, Q = 1/√2. The two differ only in the numerator, 1 ± cos(omega).
init_butterworth :: proc(cutoff_hz: f32, samplerate: f32, highpass: bool) -> (bq: Biquad) {
    if cutoff_hz <= 0 || cutoff_hz >= samplerate / 2 do return

    omega := math.TAU * f64(cutoff_hz) / f64(samplerate)
    cos_omega := math.cos(omega)
    alpha := math.sin(omega) / math.SQRT_TWO // sin(omega) / (2Q), Q = 1/√2
    a0 := 1.0 + alpha
    numerator := 1.0 + cos_omega if highpass else 1.0 - cos_omega

    bq.enabled = true
    bq.b0 = numerator / 2.0 / a0
    bq.b1 = (-numerator if highpass else numerator) / a0
    bq.b2 = numerator / 2.0 / a0
    bq.a1 = -2.0 * cos_omega / a0
    bq.a2 = (1.0 - alpha) / a0
    return
}


// From rest, the samples before are gone
reset_biquad :: proc(bq: ^Biquad) {
    bq.z1, bq.z2 = 0, 0
}

biquad_process :: proc(bq: ^Biquad, input: []f32, output: []f32) {
    assert(len(output) >= len(input))

    if !bq.enabled {
        copy(output, input)
        return
    }

    for x_f32, i in input {
        x := f64(x_f32)
        y := bq.b0 * x + bq.z1
        bq.z1 = bq.b1 * x - bq.a1 * y + bq.z2
        bq.z2 = bq.b2 * x - bq.a2 * y
        output[i] = f32(y)
    }
}


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
