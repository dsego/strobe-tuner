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
