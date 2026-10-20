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

import "core:testing"

@(test)
test_readout_track :: proc(t: ^testing.T) {
    self := init_strobe_lock_in(123.47, {1, 2, 4}, .HARMONIC)
    defer destroy_strobe_lock_in(self)

    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)

    // Every track settled on the note, the fundamental under the 2nd harmonic but not by much
    snrs := [?]f32{90, 95, 30}
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db = snrs[index]
    }
    track, ready := strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
    testing.expect(t, ready)

    // A faint partial's level wobbling isn't a pluck
    self.bands[2].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)
    self.bands[2].onset = false

    // The fundamental dies down under the 2nd harmonic still ringing, the readout goes on with that one
    self.bands[0].snr_db = 70
    track, ready = strobe_readout_track(self, track)
    testing.expect_value(t, track, 1)
    testing.expect(t, ready)

    // A pluck on the loudest track picks again, the fundamental back up
    self.bands[0].snr_db = 92
    self.bands[1].onset = true
    track, _ = strobe_readout_track(self, track)
    testing.expect_value(t, track, 0)

    // A twelfth isn't an octave, it never reads out however loud
    set_strobe_lock_in_tracks(self, {1, 3}, {0, 0}, {1, 1})
    set_strobe_lock_in_freq(self, 123.47, 440, 0.01, 2, .HARMONIC)
    for &band, index in self.bands {
        band.in_range = true
        band.rate_time_s = 1
        band.snr_db = 50 if index == 0 else 90
    }
    track, _ = strobe_readout_track(self, -1)
    testing.expect_value(t, track, 0)
}
