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
test_dft_window_size :: proc(t: ^testing.T) {
    testing.expect_value(t, dft_window_size(110.0, 48_000, 100), 7339)
    testing.expect_value(t, dft_window_size(440.0, 48_000, 100), 1835)
    testing.expect_value(t, dft_window_size(4186.0, 48_000, 100), 193)
}


@(test)
test_track_offset_and_speed :: proc(t: ^testing.T) {
    intervals := []f32{1, 2, 3}
    self := init_strobe_lock_in(110, intervals, .HARMONIC)
    defer destroy_strobe_lock_in(self)

    // A wide octave, a slower twelfth
    set_strobe_lock_in_tracks(self, intervals, {0, 30, 0}, {1, 1, 0.5})
    set_strobe_lock_in_freq(self, 110, 440, 0.01, 2, .HARMONIC)

    testing.expect(t, abs(self.bands[1].freq_hz - 220 * math.pow(f32(2), 30.0 / 1200)) < 0.001)
    testing.expect_value(t, self.bands[1].note.name, 'A')
    testing.expect_value(t, self.bands[1].note.octave, 3)
    testing.expect(t, abs(self.bands[2].speed - 0.01 * 3 * 0.5) < 1e-6)

    testing.expect(t, self.bands[2].in_range)

    // 8× of C8 is past what 48 kHz can hold
    set_strobe_lock_in_tracks(self, {1, 2, 8}, {0, 0, 0}, {1, 1, 1})
    set_strobe_lock_in_freq(self, 4186, 440, 0.01, 2, .HARMONIC)
    testing.expect(t, self.bands[1].in_range)
    testing.expect(t, !self.bands[2].in_range)

    // A missing speed leaves the track at its normal speed
    set_strobe_lock_in_tracks(self, intervals, {0, 0, 0}, {1, 1, 0})
    set_strobe_lock_in_speed(self, 0.01)
    testing.expect(t, abs(self.bands[2].speed - 0.01 * 3) < 1e-6)

    // Tracks added and removed on top
    set_strobe_lock_in_tracks(self, {1, 2, 3, 4, 5}, {0, 0, 0, 0, 0}, {1, 1, 1, 1, 1})
    set_strobe_lock_in_freq(self, 110, 440, 0.01, 2, .HARMONIC)
    testing.expect_value(t, len(self.bands), 5)
    testing.expect(t, abs(self.bands[4].freq_hz - 550) < 0.001)
    testing.expect(t, self.bands[4].dft.window_size > 0)

    set_strobe_lock_in_tracks(self, {1, 2, 0, 0, 0}, {0, 0, 0, 0, 0}, {1, 1, 1, 1, 1})
    testing.expect_value(t, len(self.bands), 2)
    testing.expect_value(t, self.bands[1].interval, 2)
}


@(test)
test_phase_detection_lock_in :: proc(t: ^testing.T) {
    FRAME :: 400 // samples per display frame at 120 FPS
    target_hz: f32 = 261.63

    run :: proc(target_hz: f32, detune_cents: f32, sample_rate: f32) -> (err_cents: [2]f32, phase_diff: f32) {
        intervals := []f32{1, 2}
        pc := init_strobe_lock_in(target_hz, intervals, .HARMONIC, sample_rate)
        defer destroy_strobe_lock_in(pc)
        set_strobe_lock_in_freq(pc, target_hz, 440, 0.025, 2, .HARMONIC)

        freq := f64(freq_at_cents(target_hz, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        for _ in 0 ..< 2 * int(sample_rate) / FRAME {
            for &sample in chunk {
                phase := math.TAU * freq * f64(clock) / f64(sample_rate)
                sample = f32(0.1 * math.sin(phase) + 0.05 * math.sin(2 * phase))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])

            // A clear pitch like the pitch detection's, the noise floors don't learn the tone
            run_phase_detection(pc, is_tonal = true)
        }
        return {pc.bands[0].err_cents, pc.bands[1].err_cents}, pc.bands[0].phase_diff
    }

    // At the input's own rate, 44.1 kHz isn't resampled to 48
    for sample_rate in ([]f32{44_100, 48_000}) {
        // In tune: the strobe stands still
        err, diff := run(target_hz, 0, sample_rate)
        testing.expectf(t, abs(err[0]) < 0.05 && abs(err[1]) < 0.05, "in tune at %v Hz, got %v cents", sample_rate, err)
        testing.expectf(t, abs(diff) < 1e-4, "in tune at %v Hz, got phase advance %v", sample_rate, diff)

        // Sharp: both bands report the detuning, the strobe phase advances
        err, diff = run(target_hz, 3, sample_rate)
        testing.expectf(t, abs(err[0] - 3) < 0.1 && abs(err[1] - 3) < 0.1, "+3 cents at %v Hz, got %v cents", sample_rate, err)
        testing.expect(t, diff > 0)

        // Flat
        err, diff = run(target_hz, -7, sample_rate)
        testing.expectf(t, abs(err[0] + 7) < 0.1 && abs(err[1] + 7) < 0.1, "-7 cents at %v Hz, got %v cents", sample_rate, err)
        testing.expect(t, diff < 0)
    }
}

// A main loop hitch, a frame's samples more than the buffer holds past the window. The 4× track of a sharp E4
// is 7.6 Hz off, over the skipped samples the shortest way would lose it a turn.
@(test)
test_phase_over_a_hitch :: proc(t: ^testing.T) {
    FRAME :: 400
    HITCH :: 9600 // 200 ms
    e4: f32 = 329.63
    freq := f64(freq_at_cents(e4, 10))

    pc := init_strobe_lock_in(e4, {1, 4}, .HARMONIC)
    defer destroy_strobe_lock_in(pc)
    set_strobe_lock_in_freq(pc, e4, 440, 0.025, 2, .HARMONIC)

    chunk: [HITCH]f32
    clock := 0
    play :: proc(pc: ^StrobeLockIn, samples: []f32, freq: f64, clock: ^int) {
        for &sample in samples {
            phase := math.TAU * freq * f64(clock^) / DEFAULT_SAMPLE_RATE
            sample = f32(0.1 * math.sin(phase) + 0.05 * math.sin(4 * phase))
            clock^ += 1
        }
        audio_capture_write(pc, samples)
        run_phase_detection(pc, is_tonal = true)
    }

    for _ in 0 ..< 2 * int(DEFAULT_SAMPLE_RATE) / FRAME do play(pc, chunk[:FRAME], freq, &clock)
    play(pc, chunk[:], freq, &clock)
    testing.expect(t, pc.available > HITCH / 2)

    for _ in 0 ..< 3 do play(pc, chunk[:FRAME], freq, &clock)
    for band, index in pc.bands {
        testing.expectf(t, abs(band.err_cents - 10) < 0.2, "track %v after the hitch, got %v cents", index, band.err_cents)
    }
}


// A voice down a semitone and back up, the strobe retuned to each note a moment after it changes like the
// note target does. Each track hears the note as well when it comes back as before it left.
@(test)
test_note_away_and_back :: proc(t: ^testing.T) {
    FRAME :: 800
    RETUNE_AFTER :: 9 // frames, about what the note recognition takes to confirm a note
    a3, g_sharp3: f32 = 220, 207.65

    intervals := []f32{1, 2, 4}
    pc := init_strobe_lock_in(a3, intervals, .HARMONIC)
    defer destroy_strobe_lock_in(pc)
    set_strobe_lock_in_freq(pc, a3, 440, 0.025, 2, .HARMONIC)

    // The partials of a hum over a little noise, the background for the noise floors to learn first. The
    // voice slides from one note to the next over glide frames, not a clear pitch on the way.
    Voice :: struct {
        chunk: [FRAME]f32,
        phase: f64,
        freq:  f32,
        noise: u32,
    }
    play :: proc(pc: ^StrobeLockIn, voice: ^Voice, to: f32, frames: int, glide := 0, retune := -1) {
        from := voice.freq
        for frame in 0 ..< frames {
            voice.freq = to if frame >= glide else from + (to - from) * f32(frame) / f32(glide)
            for &sample in voice.chunk {
                voice.noise = voice.noise * 1664525 + 1013904223
                sample = 0.1 * (f32(voice.noise) / f32(max(u32)) - 0.5)
                voice.phase += math.TAU * f64(voice.freq) / DEFAULT_SAMPLE_RATE
                phase := voice.phase
                if voice.freq > 0 do sample += f32(0.1 * math.sin(phase) + 0.03 * math.sin(2 * phase) + 0.01 * math.sin(4 * phase))
            }
            if frame == retune do set_strobe_lock_in_freq(pc, to, 440, 0.025, 2, .HARMONIC)

            audio_capture_write(pc, voice.chunk[:])
            run_phase_detection(pc, is_tonal = voice.freq > 0 && frame >= glide)
        }
    }

    SECOND :: DEFAULT_SAMPLE_RATE / FRAME
    GLIDE :: SECOND / 2
    voice := Voice{noise = 1}
    play(pc, &voice, 0, 3 * SECOND)
    play(pc, &voice, a3, 2 * SECOND)
    before: [3]f32
    for band, index in pc.bands do before[index] = band.snr_db

    play(pc, &voice, g_sharp3, 2 * SECOND, GLIDE, GLIDE + RETUNE_AFTER)
    away: [3]f32
    for band, index in pc.bands do away[index] = band.snr_db

    play(pc, &voice, a3, 2 * SECOND, GLIDE, GLIDE + RETUNE_AFTER)
    for band, index in pc.bands {
        testing.expectf(
            t,
            band.snr_db > before[index] - 3,
            "%v× %.1f dB back on the note, %.1f before, %.1f a semitone down",
            band.interval,
            band.snr_db,
            before[index],
            away[index],
        )
    }
}

// How fast the wheel turns for a steady detuning, against what the lock-in phase should give:
// TAU * STROBE_REFERENCE_HZ * (2^(cents / 1200) - 1) * speed, in radians of the wheel per second.
@(test)
test_strobe_turn_rate :: proc(t: ^testing.T) {
    FRAME :: 800 // samples per display frame at 60 FPS
    BASE_SPEED :: 0.0125

    // Radians of the wheel per second, over the last of 3 seconds
    run :: proc(target_hz: f32, detune_cents: f32, speed_scale: f32) -> f32 {
        intervals := []f32{1}
        pc := init_strobe_lock_in(target_hz, intervals, .HARMONIC)
        defer destroy_strobe_lock_in(pc)
        set_strobe_lock_in_tracks(pc, intervals, {0}, {speed_scale})
        set_strobe_lock_in_freq(pc, target_hz, 440, BASE_SPEED, 2, .HARMONIC)

        freq := f64(freq_at_cents(target_hz, detune_cents))
        chunk: [FRAME]f32
        clock := 0
        frames_per_s := DEFAULT_SAMPLE_RATE / FRAME
        start: f32
        for frame in 0 ..< 3 * frames_per_s {
            if frame == 2 * frames_per_s do start = pc.bands[0].scaled_phase

            for &sample in chunk {
                sample = f32(0.1 * math.sin(math.TAU * freq * f64(clock) / DEFAULT_SAMPLE_RATE))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])
            run_phase_detection(pc, false)
        }
        return start - pc.bands[0].scaled_phase
    }

    // Up to the edge of the note. Further out the string is outside the band's window (100 cents a bin) and
    // its phase has nothing to follow.
    for target_hz in ([]f32{82.41, 329.63}) {
        for speed_scale in ([]f32{0.25, 1}) {
            for cents in ([]f32{1, 5, 10, 25, 50, -50}) {
                rate := run(target_hz, cents, speed_scale)
                drift_hz := freq_at_cents(STROBE_REFERENCE_HZ, cents) - STROBE_REFERENCE_HZ
                ideal := math.TAU * drift_hz * BASE_SPEED * speed_scale
                testing.expectf(
                    t,
                    abs(rate - ideal) < 0.02 * abs(ideal),
                    "%v Hz at %v cents and speed %v, got %v rad/s, expected %v",
                    target_hz,
                    cents,
                    speed_scale,
                    rate,
                    ideal,
                )
            }
        }
    }
}
