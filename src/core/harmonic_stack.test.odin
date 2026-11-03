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
import "core:math/rand"
import "core:testing"


// Notes from A0 to C8 by the HARMONICS method, at the input rates like test_pitch_at_input_rates. The note,
// not the cents: the strobe reads those, and A0's partials are closer together than the window can part.
@(test)
test_harmonics_notes :: proc(t: ^testing.T) {
    for sample_rate in ([]f32{16_000, 24_000, 44_100, 48_000, 64_000}) {
        for freq in ([]f32{27.5, 41.2, 110, 329.63, 1760, 4186.01}) {
            // A0 and E1 only have their harmonics over the highpass, a sine is one harmonic
            partials := 5 if freq < 100 else 1
            pitch := detect_test_note(freq, partials, sample_rate, .HARMONICS)
            note := freq_to_note(freq)
            testing.expectf(t, pitch.is_strong_pitch && pitch.detected_note.cents == note.cents, "%v Hz at %v Hz: %v", freq, sample_rate, pitch)
        }
    }

    // Up to C8 like the ruler, a sine over it is its own fundamental and no note, not a harmonic of one under it
    d8 := detect_test_note(4698.64, partials = 1, method = .HARMONICS)
    testing.expectf(t, d8.is_weak_pitch && !d8.is_tonal, "D8: %v", d8)
}

// A weak fundamental under a loud 2nd partial, like a low string, and none at all: the fundamental's note,
// not the octave up
@(test)
test_harmonics_fundamental :: proc(t: ^testing.T) {
    for fundamental in ([]f32{82.41, 110, 329.63}) {
        weak := detect_samples_with(fundamental, {0.1, 0.4, 0.2, 0.1}, 0)
        missing := detect_samples_with(fundamental, {0, 0.4, 0.2, 0.1, 0.1}, 0)

        note := freq_to_note(fundamental)
        testing.expectf(t, weak.is_strong_pitch && weak.detected_note.cents == note.cents, "%v Hz weak fundamental: %v", fundamental, weak)
        testing.expectf(t, missing.is_strong_pitch && missing.detected_note.cents == note.cents, "%v Hz no fundamental: %v", fundamental, missing)
    }
}

// Eight harmonics 20 dB over white noise: the whole wave is only about 4 dB over it, its clarity is low, and
// the stack stands out. The noise alone is no note.
@(test)
test_harmonics_in_noise :: proc(t: ^testing.T) {
    harmonics := []f32{0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01}

    stack := detect_samples_with(225, harmonics, 0.026)
    testing.expectf(t, stack.is_strong_pitch && note_name(stack.detected_note) == "A3", "the stack in noise: %v", stack)

    wave := detect_samples_with(225, harmonics, 0.026, .WAVE)
    testing.expectf(t, wave.clarity < PITCH_CLARITY_LOW, "the whole wave in noise: %v", wave)

    noise := detect_samples_with(225, {}, 0.026)
    testing.expectf(t, noise.is_weak_pitch, "the noise alone: %v", noise)
}

// The last detection of half a second of harmonics of the fundamental with these amplitudes, and white noise
// of this RMS, at 48 kHz
detect_samples_with :: proc(fundamental: f32, amplitudes: []f32, noise_rms: f64, method := PitchMethod.HARMONICS) -> PitchInfo {
    NOISE_SEED :: 1
    noise_state := rand.create(NOISE_SEED)
    noise := rand.default_random_generator(&noise_state)

    samples := make([]f32, int(DEFAULT_SAMPLE_RATE) / 2, context.temp_allocator)
    for &sample, index in samples {
        value := noise_rms * rand.norm_float64(noise)
        for amplitude, partial in amplitudes {
            phase := math.TAU * f64(partial + 1) * f64(fundamental) * f64(index) / DEFAULT_SAMPLE_RATE
            value += f64(amplitude) * math.sin(phase)
        }
        sample = f32(value)
    }
    return detect_test_samples(samples, method = method)
}
