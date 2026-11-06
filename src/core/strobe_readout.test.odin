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
test_readout_track :: proc(t: ^testing.T) {
    level :: proc(db: f32) -> f32 {
        return math.pow(10, db / 20)
    }

    // The track's stripes this lit, 1 full, see update_band_levels
    light :: proc(band: ^PhaseBand, lit: f32) {
        band.slat_level, band.visibility = lit, lit
    }

    self := init_strobe_lock_in(123.47, {1, 2, 4}, .HARMONIC)
    defer destroy_strobe_lock_in(self)

    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)

    // Every track settled on the note and clean, the fundamental far under the 2nd harmonic, a bass string's
    levels_db := [?]f32{-60, -25, -90}
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        light(&band, 1)
        band.envelope = level(levels_db[index])
    }
    track, ready := strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
    testing.expect(t, ready)

    // A faint partial's level wobbling isn't a pluck
    self.bands[2].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    self.bands[2].onset = false

    // The fundamental dies down while the 2nd harmonic still rings, the readout goes on with that one
    light(&self.bands[0], 0.25)
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)

    // It doesn't take the readout back as it comes up again, only a pluck picks again
    light(&self.bands[0], 1)
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    self.bands[1].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    self.bands[1].onset = false

    // A fundamental under its noise gives way to the loudest partial over it
    light(&self.bands[0], 0.25)
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 1)

    // After a retune the 2nd harmonic is readable first and takes the readout, the quieter fundamental still
    // under the pluck's noise. Once its track settles it takes over.
    self.available = 800
    self.bands[0].rate_time_s = 0
    track, ready = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)
    light(&self.bands[0], 1)
    self.bands[0].rate_time_s = READOUT_SETTLE_S + 0.001
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    testing.expect(t, ready)

    // A twelfth isn't an octave, it never reads out however loud, not even with the fundamental under its noise
    set_strobe_lock_in_tracks(self, {1, 3}, {0, 0}, {1, 1})
    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        light(&band, 1)
        band.envelope = level(-30 if index == 0 else -10)
    }
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)

    light(&self.bands[0], 0.25)
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, -1)

    // The 2nd partial chosen reads out though the fundamental is louder, the loudest while it's under its noise
    set_strobe_lock_in_tracks(self, {1, 2, 4}, {0, 0, 0}, {1, 1, 1})
    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        light(&band, 1)
        band.envelope = level(-20 if index == 0 else -40)
    }
    track, _ = strobe_readout_track(self, -1, 2)
    testing.expect_value(t, track, 1)

    light(&self.bands[1], 0.25)
    track, _ = strobe_readout_track(self, -1, 2)
    testing.expect_value(t, track, 0)
}

// sandbox/accuracy's C8 in tune going 55 cents sharp, in noise 20 dB under it, and its loop: 2 s of the noise, 3 s
// of C8, then 2.5 s sharp. The strobe starts on 110 Hz and is retuned once the pitch detection lights the note,
// and it keeps the note while the pitch detection loses it. The step to sharp didn't gray its stripes for a moment.
@(test)
test_note_held_high_in_noise :: proc(t: ^testing.T) {
    FRAME :: 800 // a 60th of a second
    LEAD_IN_S :: 2
    BEFORE_S :: 3
    TONE_S :: 2.5
    TONE_RMS :: 0.1

    c8 := cents_to_note(39 * 100, 440)
    peak := math.SQRT_TWO * TONE_RMS
    samples := test_samples(LEAD_IN_S + BEFORE_S + TONE_S)
    in_tune := samples[:int((LEAD_IN_S + BEFORE_S) * f64(DEFAULT_SAMPLE_RATE))]
    phase := add_partials(in_tune, f64(c8.frequency), {peak}, from_s = LEAD_IN_S)
    add_partials(samples, f64(freq_at_cents(c8.frequency, 55)), {peak}, from_s = LEAD_IN_S + BEFORE_S, phase = phase)
    add_noise(samples, 0.1 * TONE_RMS, ACCURACY_NOISE_SEED)

    detector := init_pitch_detector(440)
    defer destroy_pitch_detector(&detector)
    note_target := init_note_target(110, 440)
    lock_in := test_lock_in(note_target.target_note.frequency, {1, 2, 4})
    defer destroy_strobe_lock_in(lock_in)

    wrong := 0
    for start := 0; start + FRAME <= len(samples); start += FRAME {
        frame := samples[start:start + FRAME]
        audio_capture_write(&detector, frame)
        audio_capture_write(lock_in, frame)
        pitch := run_pitch_detection(&detector, note_target.pitch)
        run_phase_detection(lock_in)
        if update_note_target(&note_target, pitch, strobe_shows_note(lock_in)) {
            tune_test_lock_in(lock_in, note_target.target_note.frequency)
        }

        // The last second, as sandbox/accuracy measures
        last_second := start + FRAME > len(samples) - int(DEFAULT_SAMPLE_RATE)
        if last_second && (!note_target.active || note_target.target_note.cents != c8.cents) do wrong += 1
    }
    testing.expectf(t, wrong == 0, "no note or the wrong one in %v frames of the last second", wrong)
}
