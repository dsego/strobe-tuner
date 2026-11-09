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

// A lock-in on note_hz with these tracks, harmonic, see tune_test_lock_in
test_lock_in :: proc(note_hz: f32, intervals: []f32) -> ^StrobeLockIn {
    lock_in := init_strobe_lock_in(note_hz, intervals, .HARMONIC)
    tune_test_lock_in(lock_in, note_hz)
    return lock_in
}

// Retuned to note_hz as the app retunes it at A4 440, harmonic
tune_test_lock_in :: proc(lock_in: ^StrobeLockIn, note_hz: f32) {
    set_strobe_lock_in_freq(lock_in, note_hz, 440, 0.025, 2, .HARMONIC)
}

// The next frame of the samples through the lock-in as the app's loop runs it, played the samples so far. A loop:
// for end_s in play_frames(lock_in, samples, &played, FRAME), end_s where the frame ends.
play_frames :: proc(lock_in: ^StrobeLockIn, samples: []f32, played: ^int, frame: int) -> (end_s: f64, ok: bool) {
    if played^ + frame > len(samples) do return 0, false

    audio_capture_write(lock_in, samples[played^:played^ + frame])
    run_phase_detection(lock_in)
    played^ += frame
    return f64(played^) / f64(lock_in.sample_rate), true
}

// This long a silence for the tests to add to, see add_partials and add_noise
test_samples :: proc(seconds: f64) -> []f32 {
    return make([]f32, int(seconds * f64(DEFAULT_SAMPLE_RATE)), context.temp_allocator)
}

// A note added from from_s on, its nth partial amplitudes[n - 1] high, from phase radians of the fundamental and
// fading to a third every decay_s past 0. Where the fundamental's phase ends, for a note going on from there.
add_partials :: proc(
    samples: []f32,
    freq_hz: f64,
    amplitudes: []f64,
    from_s: f64 = 0,
    phase: f64 = 0,
    decay_s: f64 = 0,
) -> (
    end_phase: f64,
) {
    first := int(from_s * f64(DEFAULT_SAMPLE_RATE))
    for &sample, index in samples[first:] {
        time_s := f64(index) / f64(DEFAULT_SAMPLE_RATE)
        level := math.exp(-time_s / decay_s) if decay_s > 0 else 1
        angle := phase + math.TAU * freq_hz * time_s
        for amplitude, partial in amplitudes {
            sample += f32(level * amplitude * math.sin(f64(partial + 1) * angle))
        }
    }
    return phase + math.TAU * freq_hz * f64(len(samples) - first) / f64(DEFAULT_SAMPLE_RATE)
}

// White noise of this RMS added, uniform, the same every run from the seed. From sandbox/accuracy's seed it's
// that harness's noise.
add_noise :: proc(samples: []f32, rms: f32, seed: u32 = 1) {
    state := seed
    for &sample in samples {
        sample += rms * math.SQRT_THREE * test_noise(&state)
    }
}

ACCURACY_NOISE_SEED :: 0x9e3779b9 // sandbox/accuracy's


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
            run_phase_detection(pc)
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
        run_phase_detection(pc)
    }

    for _ in 0 ..< 2 * int(DEFAULT_SAMPLE_RATE) / FRAME {
        play(pc, chunk[:FRAME], freq, &clock)
    }
    play(pc, chunk[:], freq, &clock)
    testing.expect(t, pc.available > HITCH / 2)

    for _ in 0 ..< 3 {
        play(pc, chunk[:FRAME], freq, &clock)
    }
    for band, index in pc.bands {
        testing.expectf(t, abs(band.err_cents - 10) < 0.2, "track %v after the hitch, got %v cents", index, band.err_cents)
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
            if frame == 2 * frames_per_s {
                start = pc.bands[0].scaled_phase
            }

            for &sample in chunk {
                sample = f32(0.1 * math.sin(math.TAU * freq * f64(clock) / DEFAULT_SAMPLE_RATE))
                clock += 1
            }
            audio_capture_write(pc, chunk[:])
            run_phase_detection(pc)
        }
        return start - pc.bands[0].scaled_phase
    }

    // Up to the edge of the note. Further out the string is outside the band's window (DFT_RESOLUTION_CENTS a
    // bin) and its phase has nothing to follow.
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

// A string plucked again: while it still rings, four times the level it rang down to and its phase jumped, and half
// a second after a mute at the level it had. Each pluck is an onset, the readout's fit starts over, as is the first
// one, though the onsets wait for the slots' level, which a re-pluck's phase jump can drop for a few periods. A
// softer re-pluck, twice the level, or one 0.15 s after a mute isn't one, nor was it by the SNR: the level rises
// through the window while the envelope follows and doesn't reach ONSET_RATIO over it.
@(test)
test_onset_on_a_replucked_string :: proc(t: ^testing.T) {
    FRAME :: 800 // a 60th of a second
    A2 :: 110.0
    DECAY_S :: 1.5
    LEVEL :: 0.3
    HISS :: 1e-4 // the room's, over 70 dB under the string
    PLAYED_S :: 3
    FOUND_WITHIN_S :: 0.4

    // A pluck's level and phase from when it starts, the string rings down from it until the next one
    Pluck :: struct {
        at_s:  f64,
        level: f64,
        phase: f64,
    }

    // When the onsets came, the plucks and a mute before the last one if mute_s is past 0
    onsets_of :: proc(plucks: []Pluck, mute_s: f64) -> [dynamic]f64 {
        lock_in := test_lock_in(A2, {1, 2, 4})
        defer destroy_strobe_lock_in(lock_in)

        samples := test_samples(PLAYED_S)
        add_noise(samples, HISS)
        for pluck, index in plucks {
            rings_to_s := plucks[index + 1].at_s if index + 1 < len(plucks) else PLAYED_S
            if mute_s > pluck.at_s {
                rings_to_s = min(rings_to_s, mute_s)
            }

            ringing := samples[:int(rings_to_s * f64(DEFAULT_SAMPLE_RATE))]
            level := pluck.level
            add_partials(ringing, A2, {level, 0.5 * level, 0, 0.25 * level}, pluck.at_s, pluck.phase, DECAY_S)
        }

        onsets: [dynamic]f64
        played := 0
        for end_s in play_frames(lock_in, samples, &played, FRAME) {
            if lock_in.bands[0].onset {
                append(&onsets, end_s)
            }
        }
        return onsets
    }

    // Whether an onset came within FOUND_WITHIN_S of each pluck
    expect_onsets :: proc(t: ^testing.T, name: string, plucks: []Pluck, onsets: []f64) {
        for pluck in plucks {
            found := false
            for onset in onsets {
                if onset >= pluck.at_s && onset - pluck.at_s <= FOUND_WITHIN_S {
                    found = true
                }
            }
            testing.expectf(t, found, "%v: no onset for the pluck at %.2f s, onsets at %v", name, pluck.at_s, onsets)
        }
    }

    rung_down := LEVEL * math.exp(-1 / DECAY_S) // at 1 s
    soft := []Pluck{{0, LEVEL, 0}, {1, 4 * rung_down, 2}}
    soft_onsets := onsets_of(soft, -1)
    defer delete(soft_onsets)
    expect_onsets(t, "re-plucked while ringing", soft, soft_onsets[:])

    muted := []Pluck{{0, LEVEL, 0}, {1.5, rung_down, 2}}
    muted_onsets := onsets_of(muted, 1)
    defer delete(muted_onsets)
    expect_onsets(t, "re-plucked after a mute", muted, muted_onsets[:])
}
