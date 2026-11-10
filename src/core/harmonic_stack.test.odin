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
import "core:slice"
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

// Eight harmonics 20 dB over white noise: the whole wave is only about 4 dB over it, its clarity 0.72 is a
// medium one and not a strong pitch, where the stack stands out. The noise alone is no note.
@(test)
test_harmonics_in_noise :: proc(t: ^testing.T) {
    harmonics := []f32{0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01, 0.01}

    stack := detect_samples_with(225, harmonics, 0.026)
    testing.expectf(t, stack.is_strong_pitch && note_name(stack.detected_note) == "A3", "the stack in noise: %v", stack)

    wave := detect_samples_with(225, harmonics, 0.026, .WAVE)
    wave_medium := wave.clarity < PITCH_CLARITY_HIGH && note_name(wave.detected_note) == "A3"
    testing.expectf(t, wave_medium, "the whole wave in noise: %v", wave)

    noise := detect_samples_with(225, {}, 0.026)
    testing.expectf(t, noise.is_weak_pitch, "the noise alone: %v", noise)
}

// A generated wave's digital silence lets everything stand out, a triangle's aliases 90 dB down made up a
// stack of their own, see HARMONICS_RANGE_DB. A square has only the odd harmonics, its octave down none of them.
@(test)
test_harmonics_generated_waves :: proc(t: ^testing.T) {
    FREQ :: 110

    triangle := make([]f32, int(DEFAULT_SAMPLE_RATE) / 2, context.temp_allocator)
    square := make([]f32, int(DEFAULT_SAMPLE_RATE) / 2, context.temp_allocator)
    for index in 0 ..< len(triangle) {
        cycle := math.mod(f64(FREQ) * f64(index) / DEFAULT_SAMPLE_RATE, 1)
        triangle[index] = f32(0.3 * (4 * abs(cycle - 0.5) - 1))
        square[index] = 0.3 if cycle < 0.5 else -0.3
    }

    for samples, name in ([2][]f32{triangle, square}) {
        pitch := detect_test_samples(samples, method = .HARMONICS)
        testing.expectf(t, pitch.is_strong_pitch && note_name(pitch.detected_note) == "A2", "%v: %v", name, pitch)
    }
}

// A stiff string's partials run sharp, the higher the more. The stack's fundamental reads the same mix of them as
// the whole wave's period, see score_stack, the Blend readout doesn't move with the method. By the power alone
// it read 3.8 cents flat of it.
@(test)
test_harmonics_blend_like_whole_wave :: proc(t: ^testing.T) {
    FUNDAMENTAL :: 110
    amplitudes := [?]f64{0.3, 0.2, 0.1, 0.08, 0.05, 0.03}

    samples := make([]f32, int(DEFAULT_SAMPLE_RATE) / 2, context.temp_allocator)
    for &sample, index in samples {
        value: f64
        for amplitude, partial in amplitudes {
            // Half a cent sharp times the harmonic squared, a 6th 18 cents
            harmonic := f64(partial + 1)
            freq := FUNDAMENTAL * harmonic * math.pow(2, 0.5 * harmonic * harmonic / 1200)
            value += amplitude * math.sin(math.TAU * freq * f64(index) / DEFAULT_SAMPLE_RATE)
        }
        sample = f32(value)
    }

    stack := detect_test_samples(samples, method = .HARMONICS)
    wave := detect_test_samples(samples, method = .WAVE)
    apart := cents_deviation(stack.detected_freq, wave.detected_freq)
    testing.expectf(t, abs(apart) < 0.5, "the stack %v Hz, the whole wave %v Hz, %v cents apart", stack.detected_freq, wave.detected_freq, apart)
}

// A low saw's harmonics are close together and each stands about as far over its background, see
// HARMONICS_PEAKS_PER_OCTAVE: the 40 most prominent of all were any of them, and an A1 saw read C#5, its 10th,
// on some of the detections. Under HARMONICS_BASS_HZ the detector's window doesn't part them at all, B0 and E1
// had no stack. Every detection once the lower spectrum's window is full. A low square's odd harmonics are a
// stack of their own from each of them and it still reads its 7th now and then, see HARMONICS_DIVISORS.
@(test)
test_harmonics_low_saws :: proc(t: ^testing.T) {
    for fundamental in ([]f32{30.87, 41.2, 55}) {
        // Up to the detector's low-pass
        amplitudes := make([]f32, int(PITCH_LOWPASS_HZ / fundamental), context.temp_allocator)
        for &amplitude, index in amplitudes {
            amplitude = 0.1 / f32(index + 1)
        }
        samples := samples_with(fundamental, amplitudes, 0)

        detector := init_pitch_detector(sample_rate = DEFAULT_SAMPLE_RATE)
        defer destroy_pitch_detector(&detector)
        detector.method = .HARMONICS

        note := freq_to_note(fundamental)
        frame := int(DEFAULT_SAMPLE_RATE) / DETECTIONS_PER_SECOND
        pitch: PitchInfo
        for start := 0; start + frame <= len(samples); start += frame {
            audio_capture_write(&detector, samples[start:start + frame])
            pitch = run_pitch_detection(&detector, pitch)
            if start < len(detector.samples) do continue

            right := pitch.is_tonal && pitch.detected_note.cents == note.cents
            testing.expectf(t, right, "%v Hz at %v: %v", fundamental, start, pitch)
        }
    }
}

// The quarter of the bins around, as sorting them would have it
@(test)
test_select_nth :: proc(t: ^testing.T) {
    random_state := rand.create(1)
    random := rand.default_random_generator(&random_state)

    for size in ([]int{1, 2, 7, 65, 97}) {
        values := make([]f32, size, context.temp_allocator)
        for &value in values {
            value = f32(rand.float64(random) * 100)
        }

        // Ties too, a dB level of digital silence repeats
        if size > 2 {
            values[1] = values[0]
        }

        sorted := slice.clone(values, context.temp_allocator)
        slice.sort(sorted)
        for nth in 0 ..< size {
            selected := select_nth(slice.clone(values, context.temp_allocator), nth)
            testing.expectf(t, selected == sorted[nth], "%v values, %vth: %v, sorted %v", size, nth, selected, sorted[nth])
        }
    }
}

// The last detection of samples_with
detect_samples_with :: proc(fundamental: f32, amplitudes: []f32, noise_rms: f64, method := PitchMethod.HARMONICS) -> PitchInfo {
    return detect_test_samples(samples_with(fundamental, amplitudes, noise_rms), method = method)
}

// Half a second of harmonics of the fundamental with these amplitudes, and white noise of this RMS, at 48 kHz
samples_with :: proc(fundamental: f32, amplitudes: []f32, noise_rms: f64) -> []f32 {
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
    return samples
}

// With HARMONICS_PHASE_STEADY: a sine's peak lands where its frequency says from one detection to the next, 800
// samples on. Noise's bins wander, though not far: the two windows share 80% of their samples, 0.73 on average.
@(test)
test_phase_steadiness :: proc(t: ^testing.T) {
    when !HARMONICS_PHASE_STEADY do return

    WINDOW :: 4096
    HOP :: 800
    A4 :: 440.0

    // The two detections' bins of these samples, HOP apart
    detect_twice :: proc(transform: ^StackTransform, samples: []f32) {
        copy(transform.spectrum.samples, samples[:WINDOW])
        run_windowed_spectrum(&transform.spectrum, transform.bins)
        copy(transform.previous_bins, transform.bins)
        transform.has_previous = true

        copy(transform.spectrum.samples, samples[HOP:HOP + WINDOW])
        run_windowed_spectrum(&transform.spectrum, transform.bins)
    }

    sine := test_samples(f64(WINDOW + HOP) / f64(DEFAULT_SAMPLE_RATE))
    add_partials(sine, A4, {0.5})
    sine_transform := init_stack_transform(WINDOW, DEFAULT_SAMPLE_RATE)
    defer destroy_stack_transform(&sine_transform)
    detect_twice(&sine_transform, sine)
    bin := int(math.round(A4 / sine_transform.bin_hz))
    testing.expectf(t, phase_steadiness(&sine_transform, bin, A4, HOP) > 0.99, "A4's peak")

    noise := test_samples(f64(WINDOW + HOP) / f64(DEFAULT_SAMPLE_RATE))
    add_noise(noise, 0.1)
    noise_transform := init_stack_transform(WINDOW, DEFAULT_SAMPLE_RATE)
    defer destroy_stack_transform(&noise_transform)
    detect_twice(&noise_transform, noise)
    sum: f32 = 0
    for noise_bin in 100 ..< 1100 {
        sum += phase_steadiness(&noise_transform, noise_bin, f32(noise_bin) * noise_transform.bin_hz, HOP)
    }
    average := sum / 1000
    testing.expectf(t, average > 0.6 && average < 0.85, "noise's bins %.2f steady on average", average)
}
