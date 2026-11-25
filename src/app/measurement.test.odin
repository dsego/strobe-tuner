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
package app

import "core:math"
import "core:testing"

import "../core"

// The two modes keep their own tracks: five added to the harmonic setup leave vernier at its own, every one on
// the fundamental, and switching back brings the five again
@(test)
test_vernier_keeps_its_own_tracks :: proc(t: ^testing.T) {
    config := config_defaults
    config.strobe_intervals = {1, 2, 4, 5, 6}

    measurement: Measurement
    measurement.strobe_lock_in = core.init_strobe_lock_in(110, config.strobe_intervals[:], .HARMONIC)
    defer core.destroy_strobe_lock_in(measurement.strobe_lock_in)

    config.strobe_mode = .VERNIER
    set_strobe_tracks(&measurement, &config)
    testing.expect_value(t, len(measurement.strobe_lock_in.bands), VERNIER_TRACKS)
    for band in measurement.strobe_lock_in.bands {
        testing.expect_value(t, band.interval, 1)
    }

    config.strobe_mode = .HARMONIC
    set_strobe_tracks(&measurement, &config)
    testing.expect_value(t, len(measurement.strobe_lock_in.bands), 5)
}

// A low B whose fundamental is too weak to hear rings on its 2× track, the readout's, and the track hears it
// whatever the note recognition makes of the rest. Once only another note plays, it doesn't.
@(test)
test_readout_track_hears :: proc(t: ^testing.T) {
    B0 := core.freq_at_cents(440, -4600)
    intervals := []f32{1, 2, 4}
    measurement: Measurement
    measurement.readout_track = {index = -1}
    measurement.strobe_lock_in = core.init_strobe_lock_in(B0, intervals, .HARMONIC)
    defer core.destroy_strobe_lock_in(measurement.strobe_lock_in)
    core.set_strobe_lock_in_freq(measurement.strobe_lock_in, B0, 440, STROBE_SPEED, 2, .HARMONIC)

    // 3 s of a sine at 60 frames a second, followed like the app's readout does
    clock := 0
    play :: proc(measurement: ^Measurement, freq: f32, clock: ^int) {
        frame: [core.DEFAULT_SAMPLE_RATE / 60]f32
        for _ in 0 ..< 3 * 60 {
            for &sample in frame {
                sample = 0.3 * math.sin(math.TAU * freq * f32(clock^) / core.DEFAULT_SAMPLE_RATE)
                clock^ += 1
            }
            core.audio_capture_write(measurement.strobe_lock_in, frame[:])
            core.run_phase_detection(measurement.strobe_lock_in)
            core.strobe_readout_track(measurement.strobe_lock_in, &measurement.readout_track, 1)
        }
    }

    play(&measurement, core.freq_at_cents(2 * B0, -3.5), &clock)
    testing.expect(t, readout_track_hears(&measurement), "the low B's 2× partial on its track")

    play(&measurement, core.freq_at_cents(440, -100), &clock)
    testing.expect(t, !readout_track_hears(&measurement), "only an A♭4")
}
