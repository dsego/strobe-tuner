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

    self := init_strobe_lock_in(123.47, {1, 2, 4}, .HARMONIC)
    defer destroy_strobe_lock_in(self)

    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)

    // Every track settled on the note and clean, the fundamental far under the 2nd harmonic, a bass string's
    levels_db := [?]f32{-60, -25, -90}
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db, band.envelope_snr_db = 30, 30
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
    self.bands[0].snr_db, self.bands[0].envelope_snr_db = 10, 12
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)

    // It doesn't take the readout back as it comes up again, only a pluck picks again
    self.bands[0].snr_db, self.bands[0].envelope_snr_db = 30, 30
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    self.bands[1].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    self.bands[1].onset = false

    // A fundamental under its noise gives way to the loudest partial over it
    self.bands[0].snr_db = 10
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 1)

    // After a retune the 2nd harmonic is readable first and takes the readout, the quieter fundamental still
    // under the pluck's noise. Once its track settles it takes over.
    self.available = 800
    self.bands[0].rate_time_s = 0
    track, ready = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)
    self.bands[0].snr_db = 17
    self.bands[0].rate_time_s = READOUT_SETTLE_S + 0.001
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    testing.expect(t, ready)

    // A twelfth isn't an octave, it never reads out however loud
    set_strobe_lock_in_tracks(self, {1, 3}, {0, 0}, {1, 1})
    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db, band.envelope_snr_db = 30, 30
        band.envelope = level(-30 if index == 0 else -10)
    }
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
}
