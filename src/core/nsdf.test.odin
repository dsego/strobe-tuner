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

import fft "../../external/extreme_fft"


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

    // The power of each bin over the size, the upper half the lower mirrored
    spectrum := make([]complex64, FFT_SIZE / 2)
    defer delete(spectrum)
    plan := fft.create_plan(FFT_SIZE)
    defer fft.destroy_plan(&plan)
    fft.run(&plan, self.padded_samples, spectrum)

    expected := make([]f32, FFT_SIZE)
    defer delete(expected)
    expected[0] = real(spectrum[0]) * real(spectrum[0]) / FFT_SIZE
    expected[FFT_SIZE / 2] = imag(spectrum[0]) * imag(spectrum[0]) / FFT_SIZE
    for k in 1 ..< FFT_SIZE / 2 {
        expected[k] = (real(spectrum[k]) * real(spectrum[k]) + imag(spectrum[k]) * imag(spectrum[k])) / FFT_SIZE
        expected[FFT_SIZE - k] = expected[k]
    }
    for power, k in self.power {
        testing.expectf(t, abs(power - expected[k]) < 1e-4 * expected[0], "bin %v: %v, expected %v", k, power, expected[k])
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
