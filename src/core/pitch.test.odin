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


// The last detection of half a second of a note, a high note's partials go over Nyquist, a sine has one. By
// the WAVE method whatever -define:PITCH_HARMONICS says, the HARMONICS tests pass their own.
detect_test_note :: proc(
    fundamental: f32,
    partials := 5,
    sample_rate: f32 = DEFAULT_SAMPLE_RATE,
    method := PitchMethod.WAVE,
) -> PitchInfo {
    samples := make([]f32, int(sample_rate) / 2, context.temp_allocator)
    for &sample, i in samples {
        for partial in 1 ..= partials {
            phase := math.TAU * f64(partial) * f64(fundamental) * f64(i) / f64(sample_rate)
            sample += f32(0.01 * math.sin(phase))
        }
    }
    return detect_test_samples(samples, sample_rate, method)
}

// The last detection of the samples, a display frame at a time like the app, the high-pass settles from
// their start
detect_test_samples :: proc(samples: []f32, sample_rate: f32 = DEFAULT_SAMPLE_RATE, method := PitchMethod.WAVE) -> PitchInfo {
    detector := init_pitch_detector(sample_rate = sample_rate)
    defer destroy_pitch_detector(&detector)
    detector.method = method

    frame := int(sample_rate) / DETECTIONS_PER_SECOND
    info: PitchInfo
    for start := 0; start + frame <= len(samples); start += frame {
        audio_capture_write(&detector, samples[start:start + frame])
        info = run_pitch_detection(&detector, info)
    }
    return info
}

// With MAINS_HUM, hum with its harmonics doesn't name a note at either mains frequency, the notes either side
// of it do. Without it hum is a note like any other pitch.
@(test)
test_mains_hum :: proc(t: ^testing.T) {
    for mains_hz in MAINS_HZ {
        hum := detect_test_note(mains_hz)
        when MAINS_HUM {
            testing.expectf(t, !hum.is_clear_tone && !hum.is_tonal, "%v Hz hum: %v", mains_hz, hum)
        } else {
            testing.expectf(t, hum.is_clear_tone && hum.is_tonal, "%v Hz hum: %v", mains_hz, hum)
        }
    }
    for note_hz in ([]f32{49.0, 61.74}) {
        note := detect_test_note(note_hz)
        testing.expectf(t, note.is_clear_tone && note.is_tonal, "%v Hz note: %v", note_hz, note)
    }
}

// Up to C8 like the ruler, a higher pitch is no note
@(test)
test_highest_note :: proc(t: ^testing.T) {
    c8 := detect_test_note(4186.01, partials = 1)
    testing.expectf(t, c8.is_clear_tone && c8.is_tonal, "C8: %v", c8)

    d8 := detect_test_note(4698.64, partials = 1)
    testing.expectf(t, !d8.is_clear_tone && !d8.is_tonal, "D8: %v", d8)
}

// The input's own rate, no resampling: the piano's ends at 44.1 kHz and a headset's 16 kHz, a decimated
// 192 kHz comes in at 48. A headset's C8 has 4 to 6 samples a period, the lag between them is a guess some
// cents off. The note is still right, the strobe reads the cents.
@(test)
test_pitch_at_input_rates :: proc(t: ^testing.T) {
    for sample_rate in ([]f32{16_000, 24_000, 44_100, 48_000, 64_000}) {
        for freq in ([]f32{27.5, 110, 4186.01}) {
            // A0 with its harmonics like a low string's, a sine alone reads it too
            pitch := detect_test_note(freq, partials = 5 if freq < 100 else 1, sample_rate = sample_rate)
            cents := cents_deviation(pitch.detected_freq, freq)
            if sample_rate >= LOW_SAMPLE_RATE {
                testing.expectf(t, pitch.is_clear_tone && abs(cents) < 1, "%v Hz at %v Hz: %v cents, %v", freq, sample_rate, cents, pitch)
            } else {
                note := freq_to_note(freq)
                testing.expectf(t, pitch.is_tonal && pitch.detected_note.cents == note.cents, "%v Hz at %v Hz: %v", freq, sample_rate, pitch)
            }
        }
    }
}
